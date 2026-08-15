import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Supported audio file extensions for the picker.
const List<String> kSupportedAudioExtensions = [
  'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac',
];

// Speed & pitch control bounds and step size.
const double kMinSpeed = 0.5;
const double kMaxSpeed = 2.0;
const double kSpeedStep = 0.05;
final int kSpeedDivisions = ((kMaxSpeed - kMinSpeed) / kSpeedStep).round(); // 30

// The standard Nightcore preset multiplier applied to both speed and pitch.
const double kNightcoreSpeed = 1.25;

// Tolerance used when comparing floating-point speed values, to safely
// detect "is the slider at exactly this preset/target" despite potential
// tiny floating-point drift from division-based slider steps.
const double kSpeedCompareTolerance = 0.001;

// Maximum time to wait for a track to load before treating it as failed.
const int kLoadTimeoutSeconds = 15;

// How often (max) the actual audio engine is updated while a slider is
// being dragged continuously. The UI thumb itself always tracks the drag
// instantly via ValueNotifier — this only throttles the underlying
// native setSpeed/setPitch/setVolume platform-channel calls, preventing
// call-spam and audible stutter during a fast, continuous drag.
const Duration kSliderThrottleDuration = Duration(milliseconds: 60);

// Maximum character length for a saved preset name, to keep it readable
// in the compact Presets sheet list regardless of user input.
const int kMaxPresetNameLength = 40;

// Volume multiplier applied directly to the audio engine (bypassing the
// user's chosen volumeNotifier value) while temporarily "ducking" for a
// transient, low-priority interruption (e.g. a brief notification sound
// from another app). Restored back to the user's actual chosen volume
// once the interruption ends.
const double kDuckVolumeMultiplier = 0.3;

// SharedPreferences key under which saved Speed & Pitch presets are stored.
const String _kPresetsPrefsKey = 'nightcore_speed_pitch_presets';

// SharedPreferences key under which the playback queue (track list) is
// persisted. Bumped with a version suffix (`_v1`) so that if the stored
// shape ever changes incompatibly, we can bump this key rather than
// needing a migration.
const String _kQueuePrefsKey = 'nightcore_queue_v1';

// Name of the subdirectory (inside the app's Documents directory) where
// picked audio files are copied for permanent, app-owned storage. See
// PlayerController's queue persistence doc comment for why this copy
// step is necessary.
const String _kAudioLibraryDirName = 'audio_library';

/// Strips the file extension from a file name for cleaner display.
/// Shared by the UI layer, the controller (error messages), and the
/// audio handler (notification title).
String stripExtension(String fileName) {
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot <= 0) return fileName;
  return fileName.substring(0, lastDot);
}

/// Returns true if [value] matches [target] within [kSpeedCompareTolerance].
/// Centralizes the floating-point-safe comparison used to detect "is the
/// current speed exactly at this preset/target value" (e.g. for the
/// Nightcore Mode indicator and the active-preset highlight), so the same
/// tolerance logic isn't duplicated across the controller and UI layers.
bool speedValuesMatch(double value, double target) =>
    (value - target).abs() < kSpeedCompareTolerance;

/// Severity level of a user-facing notification emitted via
/// [PlayerController.errors]. Lets the UI layer render genuine failures,
/// soft degradations, and plain guidance messages distinctly (e.g.
/// different SnackBar colors/icons) instead of treating everything the
/// same way.
enum NotificationSeverity { error, warning, info }

/// A single user-facing message paired with its [NotificationSeverity].
/// Emitted via [PlayerController.errors] for the UI layer to display,
/// typically as a SnackBar.
class AppNotification {
  final String message;
  final NotificationSeverity severity;

  const AppNotification(this.message, this.severity);
}

/// Repeat behavior applied when the currently-loaded track finishes
/// playing naturally. See [PlayerController]'s class doc comment
/// ("Repeat & Shuffle" section) for the exact semantics of each value.
enum RepeatMode { off, all, one }

/// A single entry in the playback queue. Wraps a [PlatformFile] with a
/// stable [id] (so it can be tracked across reordering/removal) and a
/// mutable error flag for load-failure feedback.
class QueueItem {
  final int id;
  final PlatformFile file;
  bool hasError;

  QueueItem({
    required this.id,
    required this.file,
    this.hasError = false,
  });
}

/// A saved Speed & Pitch preset. Since speed and pitch are always linked in
/// this app (both set to the same multiplier for the Nightcore-style tape
/// effect), a single [value] fully describes a preset.
class SpeedPitchPreset {
  final int id;
  final String name;
  final double value;

  SpeedPitchPreset({
    required this.id,
    required this.name,
    required this.value,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'value': value};

  factory SpeedPitchPreset.fromJson(Map<String, dynamic> json) => SpeedPitchPreset(
        id: json['id'] as int,
        name: json['name'] as String,
        value: (json['value'] as num).toDouble(),
      );
}

/// Thrown when a queue item's file path cannot be resolved (e.g., missing
/// path metadata from the file picker result). Kept distinct from
/// [FileSystemException] so [describeError] can surface an accurate,
/// specific message rather than the generic "file not found" wording used
/// for genuine OS-level file errors.
class InvalidFilePathException implements Exception {
  final String message;
  const InvalidFilePathException(this.message);

  @override
  String toString() => message;
}

/// Translates a raised exception into a short, user-friendly message.
String describeError(Object error) {
  if (error is InvalidFilePathException) {
    return error.message;
  }

  if (error is TimeoutException) {
    return 'Loading timed out. The file may be corrupted, too large, or inaccessible.';
  }

  if (error is MissingPluginException) {
    return 'This feature isn\'t available on the current build/platform.';
  }

  if (error is PlayerException) {
    final msg = (error.message ?? '').toLowerCase();
    if (msg.contains('source error') ||
        msg.contains('unsupported') ||
        msg.contains('decoder')) {
      return 'Unsupported or corrupted audio format.';
    }
    if (msg.contains('no such file') ||
        msg.contains('enoent') ||
        msg.contains('not found')) {
      return 'File not found. It may have been moved or deleted.';
    }
    return 'Playback error (code ${error.code}): ${error.message ?? 'Unknown error'}';
  }

  if (error is PlatformException) {
    return 'Platform error: ${error.message ?? error.code}';
  }

  if (error is FileSystemException) {
    return 'File not found. It may have been moved or deleted.';
  }

  return 'Unexpected error: $error';
}

/// Central controller for the NightcorePlayer app. Owns the audio engine,
/// the playback queue, speed/pitch/volume state, and saved presets.
///
/// Most state changes (queue edits, track loading, presets) are surfaced
/// via this class's own [ChangeNotifier] / [notifyListeners]. Speed and
/// volume are a deliberate exception: they're exposed as their own
/// [ValueNotifier]s (see [speedNotifier] / [volumeNotifier]) so that
/// high-frequency slider drags only trigger narrowly-scoped UI rebuilds,
/// not a rebuild of the entire screen on every tick.
///
/// Playback errors — and gentle guidance messages for edge-case user
/// actions, e.g. tapping Play with an empty queue — are surfaced through
/// the [errors] broadcast stream rather than directly showing UI, keeping
/// this class fully independent of BuildContext/widgets. Each emitted
/// [AppNotification] carries a [NotificationSeverity] so the UI can
/// render genuine errors, soft warnings, and plain guidance distinctly.
///
/// ## Queue persistence
/// Picked files are copied into an app-owned permanent directory
/// (`ApplicationDocumentsDirectory/audio_library`) rather than referenced
/// directly at their picker-provided path — on iOS in particular, the
/// path returned by the file picker isn't guaranteed to remain valid
/// across app restarts. The queue's metadata (id, name, path, size) is
/// then persisted to `shared_preferences` and restored on next launch. If
/// a previously-queued file is missing at restore time (e.g. deleted
/// externally, or the initial copy never completed), it's kept in the
/// queue but flagged via [QueueItem.hasError], reusing the same
/// error-display UI as a live load failure.
///
/// Deliberately out of scope for this pass: the currently-loaded track
/// and playback position are NOT restored on restart — only the queue's
/// contents are. Resuming "where you left off" would be a reasonable
/// follow-up enhancement.
///
/// ## Audio session / interruption handling
/// On construction, an [AudioSession] is configured with the standard
/// music-playback category so the OS treats this app as an exclusive
/// audio player (won't mix with other apps, correctly triggers
/// interruption/ducking events). Two situations are then handled
/// automatically, with no UI involvement needed:
///  - A "hard" interruption (incoming call, another app taking audio
///    focus) pauses playback, remembering whether we were actually
///    playing so playback can resume automatically once the interruption
///    ends — but only if it actually ends (a permanent focus loss, e.g.
///    the user deliberately starts another music app, correctly does NOT
///    auto-resume).
///  - A "soft" interruption (e.g. a brief notification chime) just ducks
///    the engine volume down temporarily rather than stopping playback.
///  - Headphones/Bluetooth disconnecting immediately pauses playback, so
///    audio doesn't suddenly blast from the device's built-in speaker.
///
/// ## Repeat & Shuffle
/// [repeatMode] cycles through Off → All → One via [cycleRepeatMode] (or
/// can be set directly via [setRepeatMode], used when OS-level transport
/// controls request a specific mode). It governs what happens when a
/// track finishes naturally:
///  - Off: stop after the last track in the current traversal order.
///  - All: loop back to the start (first queue track in sequential mode,
///    or a freshly reshuffled order in shuffle mode) once the end is
///    reached.
///  - One: replay the exact same track indefinitely, taking priority
///    over shuffle entirely.
///
/// [isShuffleEnabled] (toggled via [toggleShuffle]) replaces the normal
/// sequential next/previous traversal with a randomly-shuffled order of
/// the queue. Whenever the shuffle order is (re)generated, the
/// currently-loaded track is deliberately kept at the current cursor
/// position, so toggling shuffle on mid-playback never itself skips or
/// repeats the current track. The order is regenerated whenever the
/// queue's membership changes (tracks added/removed) while shuffle is
/// active; purely reordering the queue's manual sequence has no effect
/// on the shuffle order, since shuffle deliberately ignores manual
/// ordering. Manually selecting a track from the Queue screen while
/// shuffle is active correctly re-syncs the shuffle cursor to that
/// track's position, so subsequent Next/Previous taps stay consistent.
class PlayerController extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();

  final List<QueueItem> _queue = [];
  List<QueueItem> get queue => List.unmodifiable(_queue);

  // Incrementing counter used to assign a stable, unique id to every
  // picked file, independent of its position in the list.
  int _nextId = 0;

  int? _currentTrackId;
  int? get currentTrackId => _currentTrackId;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  // Guards against re-entrant auto-advance calls if the completed state
  // fires more than once in quick succession.
  bool _isHandlingCompletion = false;

  // Guards against opening multiple concurrent file picker dialogs if the
  // user rapidly double-taps "Add Tracks".
  bool _isPickerOpen = false;

  /// Isolated from this class's own ChangeNotifier on purpose — see the
  /// class doc comment. Widgets displaying/editing speed should use a
  /// [ValueListenableBuilder] on this notifier rather than listening to
  /// [PlayerController] itself.
  final ValueNotifier<double> speedNotifier = ValueNotifier<double>(1.0);
  double get speed => speedNotifier.value;

  /// Isolated from this class's own ChangeNotifier for the same reason as
  /// [speedNotifier].
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(1.0);
  double get volume => volumeNotifier.value;
  double _volumeBeforeMute = 1.0;

  // Throttling state for the native setSpeed/setPitch engine calls.
  Timer? _speedThrottleTimer;
  double? _pendingSpeedValue;

  // Throttling state for the native setVolume engine call.
  Timer? _volumeThrottleTimer;
  double? _pendingVolumeValue;

  // Only used to avoid spamming the same warning repeatedly. Note: we no
  // longer permanently disable pitch after a failure — every speed change
  // still attempts setPitch(), so if the underlying native build gets
  // fixed (e.g. after a proper clean rebuild), pitch shifting resumes
  // working automatically without needing any other code changes.
  bool _pitchWarningShown = false;

  // Ensures the notification-permission request/warning only ever fires
  // once per app session, regardless of how many times
  // ensureNotificationPermission() is called.
  bool _notificationPermissionRequested = false;

  // Saved Speed & Pitch presets, persisted via shared_preferences.
  List<SpeedPitchPreset> _presets = [];
  List<SpeedPitchPreset> get presets => List.unmodifiable(_presets);
  int _nextPresetId = 0;
  bool _presetsLoaded = false;
  bool get presetsLoaded => _presetsLoaded;

  // Whether the persisted queue has finished its initial restore attempt
  // (successful or not). Exposed for parity with [presetsLoaded]; not
  // currently consumed by the UI, but available for a future loading
  // indicator if queue restoration ever becomes slow enough to matter.
  bool _queueLoaded = false;
  bool get queueLoaded => _queueLoaded;

  // Cached handle to the app's permanent audio storage directory, so we
  // only resolve/create it once per app session.
  Directory? _audioLibraryDir;

  // --- Audio session / interruption handling state ---
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  // Whether playback was actually active right when a "hard" interruption
  // (call, another app) began, so we know whether to auto-resume once it
  // ends. Deliberately NOT the same as "is a track loaded" — we should
  // never resume a track that was already paused before the interruption.
  bool _wasPlayingBeforeInterruption = false;
  // Whether we're currently in a "ducked" (temporarily quieted) state due
  // to a soft interruption, so we know whether to restore volume on end.
  bool _isDucking = false;

  // --- Repeat & Shuffle state ---
  RepeatMode _repeatMode = RepeatMode.off;
  RepeatMode get repeatMode => _repeatMode;

  bool _isShuffleEnabled = false;
  bool get isShuffleEnabled => _isShuffleEnabled;

  // Shuffled traversal order (a permutation of queue item ids) used for
  // Next/Previous/auto-advance while shuffle is active, plus a cursor
  // pointing at the currently-loaded track's position within it. See the
  // class doc comment ("Repeat & Shuffle") for how/when this is
  // regenerated and kept in sync.
  List<int> _shuffleOrder = [];
  int _shuffleCursor = -1;
  final math.Random _shuffleRandom = math.Random();

  StreamSubscription<PlayerState>? _playerStateSubscription;

  final StreamController<AppNotification> _errorController =
      StreamController<AppNotification>.broadcast();

  /// Broadcast stream of user-facing notifications — genuine playback
  /// errors, soft warnings about degraded (but non-blocking) features,
  /// and gentle guidance for edge-case actions (e.g. an empty queue).
  /// Each carries a [NotificationSeverity] so the UI layer can render it
  /// distinctly (e.g. a differently colored/iconed SnackBar) rather than
  /// treating every message identically.
  Stream<AppNotification> get errors => _errorController.stream;

  bool get isNightcoreActive => speedValuesMatch(speed, kNightcoreSpeed);

  /// The currently loaded queue item, or null if none / it was removed.
  QueueItem? get currentItem {
    if (_currentTrackId == null) return null;
    for (final item in _queue) {
      if (item.id == _currentTrackId) return item;
    }
    return null;
  }

  PlayerController() {
    // Listen for track completion to drive auto-advance to the next track.
    _playerStateSubscription = player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _handleTrackCompleted();
      }
    });
    _loadPresets();
    _loadQueue();
    unawaited(_initAudioSession());
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _speedThrottleTimer?.cancel();
    _volumeThrottleTimer?.cancel();
    speedNotifier.dispose();
    volumeNotifier.dispose();
    player.dispose();
    _errorController.close();
    super.dispose();
  }

  void _emitError(String message, {NotificationSeverity severity = NotificationSeverity.error}) {
    if (!_errorController.isClosed) {
      _errorController.add(AppNotification(message, severity));
    }
  }

  /// Configures the OS audio session as a standard exclusive music
  /// player, and starts listening for interruptions (calls, other apps,
  /// headphone removal). See the class doc comment for the exact
  /// behavior. Failure here is non-fatal — core playback still works
  /// without it, it just won't gracefully react to these OS-level events.
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      _interruptionSubscription =
          session.interruptionEventStream.listen(_handleAudioInterruption);
      _becomingNoisySubscription =
          session.becomingNoisyEventStream.listen((_) => _handleBecomingNoisy());
    } catch (e) {
      _emitError(
        'Could not configure audio session: ${describeError(e)}',
        severity: NotificationSeverity.warning,
      );
    }
  }

  /// Reacts to an OS-level audio interruption. See the class doc comment
  /// for the distinction between "hard" (pause) and "soft" (duck)
  /// interruptions.
  void _handleAudioInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          _isDucking = true;
          player.setVolume(volume * kDuckVolumeMultiplier);
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = player.playing;
          if (player.playing) {
            player.pause();
          }
          break;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          if (_isDucking) {
            _isDucking = false;
            player.setVolume(volume);
          }
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (_wasPlayingBeforeInterruption && _currentTrackId != null) {
            player.play();
          }
          _wasPlayingBeforeInterruption = false;
          break;
      }
    }
  }

  /// Reacts to the "becoming noisy" system event (headphones or Bluetooth
  /// disconnected mid-playback) by pausing immediately, matching standard
  /// platform convention so audio doesn't suddenly play out loud.
  void _handleBecomingNoisy() {
    if (player.playing) {
      player.pause();
    }
  }

  /// Returns true if a track is currently loaded and safe to act on.
  /// Otherwise emits a friendly, context-appropriate guidance message
  /// (distinguishing "queue is completely empty" from "queue has tracks
  /// but none is selected") and returns false.
  ///
  /// Centralizes this check so Play, Stop, Skip Next, and Skip Previous
  /// all give the same clear feedback instead of silently doing nothing
  /// when tapped with no track loaded.
  bool _ensureTrackAvailable() {
    if (_currentTrackId != null) return true;

    if (_queue.isEmpty) {
      _emitError(
        'Your queue is empty. Tap "Add Tracks" to get started.',
        severity: NotificationSeverity.info,
      );
    } else {
      _emitError(
        'Select a track from the queue to start playing.',
        severity: NotificationSeverity.info,
      );
    }
    return false;
  }

  /// Requests the Android 13+ `POST_NOTIFICATIONS` runtime permission,
  /// needed for the background-playback system notification (and
  /// therefore the lock-screen transport controls) to actually be visible
  /// to the user.
  ///
  /// This is a no-op on iOS and on web: iOS's lock-screen "Now Playing"
  /// controls don't depend on local notification permission, and this
  /// permission concept doesn't apply to web at all.
  ///
  /// IMPORTANT: this permission must also be declared in
  /// AndroidManifest.xml
  /// (`<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>`)
  /// for the system permission dialog to appear at all — without that
  /// manifest entry, `request()` will simply return `denied` silently,
  /// and this method will surface the "denied" warning below even though
  /// the user was never actually asked.
  Future<void> ensureNotificationPermission() async {
    if (_notificationPermissionRequested) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    _notificationPermissionRequested = true;
    try {
      final currentStatus = await Permission.notification.status;
      if (currentStatus.isGranted) return;

      final result = await Permission.notification.request();
      if (!result.isGranted) {
        _emitError(
          'Notification permission was denied. Background playback still '
          'works, but lock-screen controls may not be visible. You can '
          'enable this later in system settings.',
          severity: NotificationSeverity.warning,
        );
      }
    } catch (e) {
      // Non-fatal: absence of this permission never blocks core playback,
      // so a failure here is worth surfacing but not worth retrying.
      _emitError(
        'Could not request notification permission: ${describeError(e)}',
        severity: NotificationSeverity.warning,
      );
    }
  }

  Future<void> _loadPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPresetsPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _presets = decoded
            .map((e) => SpeedPitchPreset.fromJson(e as Map<String, dynamic>))
            .toList();
        if (_presets.isNotEmpty) {
          _nextPresetId = _presets.map((p) => p.id).reduce(math.max) + 1;
        }
      }
    } catch (e) {
      _emitError('Failed to load saved presets: ${describeError(e)}');
    } finally {
      _presetsLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _persistPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_presets.map((p) => p.toJson()).toList());
      await prefs.setString(_kPresetsPrefsKey, raw);
    } catch (e) {
      _emitError('Failed to save presets: ${describeError(e)}');
    }
  }

  /// Saves the current speed/pitch value as a new named preset. If [name]
  /// is blank, falls back to a default name based on the numeric value.
  /// Names longer than [kMaxPresetNameLength] are truncated — the UI's
  /// TextField already enforces this limit at input time, but this guard
  /// keeps the invariant true regardless of caller.
  Future<void> savePreset(String name) async {
    var finalName = name.trim();
    if (finalName.length > kMaxPresetNameLength) {
      finalName = finalName.substring(0, kMaxPresetNameLength);
    }
    if (finalName.isEmpty) {
      finalName = '${speed.toStringAsFixed(2)}x';
    }

    final preset = SpeedPitchPreset(id: _nextPresetId++, name: finalName, value: speed);
    _presets.add(preset);
    notifyListeners();
    await _persistPresets();
  }

  /// Deletes the preset identified by [id].
  Future<void> deletePreset(int id) async {
    _presets.removeWhere((p) => p.id == id);
    notifyListeners();
    await _persistPresets();
  }

  /// Applies a saved preset's value as the current speed & pitch. Uses
  /// [immediate] speed application since this is a discrete, one-shot
  /// action (not a continuous drag), so there's no risk of call-spam and
  /// snappy feedback matters more than throttling.
  void applyPreset(SpeedPitchPreset preset) {
    setSpeed(preset.value, immediate: true);
  }

  /// Cycles [repeatMode] through Off → All → One → Off. Used by the
  /// transport controls' repeat button (a discrete tap, not a drag).
  void cycleRepeatMode() {
    switch (_repeatMode) {
      case RepeatMode.off:
        setRepeatMode(RepeatMode.all);
        break;
      case RepeatMode.all:
        setRepeatMode(RepeatMode.one);
        break;
      case RepeatMode.one:
        setRepeatMode(RepeatMode.off);
        break;
    }
  }

  /// Sets [repeatMode] directly to [mode]. Exposed separately from
  /// [cycleRepeatMode] so OS-level transport controls (which request a
  /// specific target mode, not "the next one") can set it precisely.
  void setRepeatMode(RepeatMode mode) {
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    notifyListeners();
  }

  /// Toggles shuffle traversal on/off. See the class doc comment
  /// ("Repeat & Shuffle") for exactly how the shuffle order is built and
  /// maintained.
  void toggleShuffle() {
    _isShuffleEnabled = !_isShuffleEnabled;
    if (_isShuffleEnabled) {
      _regenerateShuffleOrder(keepCurrentId: _currentTrackId);
    } else {
      _shuffleOrder = [];
      _shuffleCursor = -1;
    }
    notifyListeners();
  }

  /// Rebuilds [_shuffleOrder] as a fresh random permutation of the
  /// current queue's ids. If [keepCurrentId] is provided and still
  /// present in the queue, it's moved to the front of the new order and
  /// [_shuffleCursor] is set to point at it (so the currently-loaded
  /// track isn't itself skipped/repeated by the regeneration). Otherwise
  /// the cursor starts at the beginning of the fresh order.
  void _regenerateShuffleOrder({int? keepCurrentId}) {
    final ids = _queue.map((item) => item.id).toList();
    ids.shuffle(_shuffleRandom);
    if (keepCurrentId != null && ids.remove(keepCurrentId)) {
      ids.insert(0, keepCurrentId);
    }
    _shuffleOrder = ids;
    _shuffleCursor = ids.isEmpty ? -1 : 0;
  }

  /// Returns (creating if necessary) the app-owned permanent directory
  /// used to store copies of picked audio files. Cached after first
  /// resolution for the lifetime of this controller.
  Future<Directory> _getAudioLibraryDir() async {
    final cached = _audioLibraryDir;
    if (cached != null) return cached;

    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/$_kAudioLibraryDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _audioLibraryDir = dir;
    return dir;
  }

  /// Copies the picked file at [sourcePath] into the app's permanent
  /// audio library directory, naming it by [id] (plus the original
  /// extension) to guarantee uniqueness regardless of the original file
  /// name. Returns the resulting [File].
  Future<File> _copyFileToLibrary(String sourcePath, String originalName, int id) async {
    final libraryDir = await _getAudioLibraryDir();
    final lastDot = originalName.lastIndexOf('.');
    final extension = lastDot > 0 ? originalName.substring(lastDot) : '';
    final destPath = '${libraryDir.path}/$id$extension';
    return File(sourcePath).copy(destPath);
  }

  /// Deletes a previously-copied library file at [path], if it actually
  /// lives inside our app-owned audio library directory. This guard
  /// prevents accidentally deleting an original user file in the rare
  /// fallback case where copying failed and the queue item is still
  /// pointing directly at the picker-provided path (see
  /// [_copyFileToLibrary] call sites). Failures are non-fatal — cleanup
  /// is best-effort.
  Future<void> _deleteStoredFile(String? path) async {
    if (path == null) return;
    try {
      final libraryDir = await _getAudioLibraryDir();
      if (!path.startsWith(libraryDir.path)) return;

      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup; a stray orphaned file is not worth
      // surfacing as a user-facing error.
    }
  }

  Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_queue
          .map((item) => {
                'id': item.id,
                'name': item.file.name,
                'path': item.file.path,
                'size': item.file.size,
              })
          .toList());
      await prefs.setString(_kQueuePrefsKey, raw);
    } catch (e) {
      _emitError('Failed to save queue: ${describeError(e)}');
    }
  }

  /// Restores the previously-persisted queue on startup. Each entry's
  /// file is checked for existence at restore time; if missing, the item
  /// is still added to the queue (so the user can see it was there and
  /// remove it) but flagged via [QueueItem.hasError], reusing the same
  /// "Failed to load — tap to retry" UI as a live load failure.
  Future<void> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kQueuePrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final restored = <QueueItem>[];

        for (final entry in decoded) {
          final map = entry as Map<String, dynamic>;
          final id = map['id'] as int;
          final name = map['name'] as String;
          final path = map['path'] as String?;
          final size = (map['size'] as num?)?.toInt() ?? 0;
          final fileExists = path != null && File(path).existsSync();

          restored.add(QueueItem(
            id: id,
            file: PlatformFile(name: name, path: path, size: size),
            hasError: !fileExists,
          ));
        }

        _queue
          ..clear()
          ..addAll(restored);

        if (_queue.isNotEmpty) {
          _nextId = _queue.map((item) => item.id).reduce(math.max) + 1;
        }
      }
    } catch (e) {
      _emitError('Failed to restore saved queue: ${describeError(e)}');
    } finally {
      _queueLoaded = true;
      notifyListeners();
    }
  }

  /// Opens the system file picker to add one or more audio files to the
  /// queue. Guarded against being invoked again while a picker dialog is
  /// already open (e.g. from a rapid double-tap on "Add Tracks"), which
  /// would otherwise risk spawning overlapping native dialogs.
  ///
  /// Each picked file is copied into the app's permanent audio library
  /// directory (see [_copyFileToLibrary]) so the queue can be safely
  /// persisted and survive app restarts. If copying a particular file
  /// fails, that file falls back to being referenced at its original
  /// picker-provided path for the current session, with a warning that
  /// it may not survive a restart.
  Future<void> pickAudioFiles() async {
    if (_isPickerOpen) return;
    _isPickerOpen = true;

    try {
      final wasQueueEmpty = _queue.isEmpty;

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: kSupportedAudioExtensions,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      final newItems = <QueueItem>[];

      for (final pickedFile in result.files) {
        final assignedId = _nextId++;
        final sourcePath = pickedFile.path;

        if (sourcePath == null) {
          newItems.add(QueueItem(id: assignedId, file: pickedFile, hasError: true));
          _emitError('Couldn\'t import "${pickedFile.name}": missing file path.');
          continue;
        }

        try {
          final storedFile = await _copyFileToLibrary(sourcePath, pickedFile.name, assignedId);
          final storedPlatformFile = PlatformFile(
            name: pickedFile.name,
            path: storedFile.path,
            size: await storedFile.length(),
          );
          newItems.add(QueueItem(id: assignedId, file: storedPlatformFile));
        } catch (e) {
          // Fallback: keep the original picker path so at least this
          // session can play it, but warn that it may not persist.
          newItems.add(QueueItem(id: assignedId, file: pickedFile));
          _emitError(
            'Couldn\'t copy "${pickedFile.name}" into app storage — it may '
            'not be available after restarting the app. (${describeError(e)})',
            severity: NotificationSeverity.warning,
          );
        }
      }

      _queue.addAll(newItems);
      if (_isShuffleEnabled) {
        _regenerateShuffleOrder(keepCurrentId: _currentTrackId);
      }
      notifyListeners();
      unawaited(_persistQueue());

      if (wasQueueEmpty && newItems.isNotEmpty) {
        await loadTrackById(newItems.first.id, autoPlay: false);
      }
    } catch (e) {
      _emitError('Failed to open file picker: ${describeError(e)}');
    } finally {
      _isPickerOpen = false;
    }
  }

  /// Loads the queue item identified by [id] into the audio engine.
  ///
  /// Both failure modes — an unresolved file path and any error thrown
  /// during actual loading/decoding — funnel through a single try/catch/
  /// finally so the "mark as errored, restore previous track, notify"
  /// logic exists in exactly one place, with exactly one UI notification
  /// per attempt.
  Future<void> loadTrackById(int id, {bool autoPlay = false}) async {
    QueueItem? target;
    for (final item in _queue) {
      if (item.id == id) {
        target = item;
        break;
      }
    }
    if (target == null) return;

    final loadedItem = target;
    final previousTrackId = _currentTrackId;

    _isLoading = true;
    _currentTrackId = id;
    loadedItem.hasError = false;

    // Keep the shuffle cursor in sync regardless of how this track came
    // to be loaded (Next/Previous, auto-advance, OS controls, or a
    // manual tap on a queue item), so subsequent Next/Previous taps
    // continue correctly from this track's actual position in the order.
    if (_isShuffleEnabled) {
      final shuffleIndex = _shuffleOrder.indexOf(id);
      if (shuffleIndex != -1) {
        _shuffleCursor = shuffleIndex;
      }
    }

    notifyListeners();

    try {
      final path = loadedItem.file.path;
      if (path == null) {
        throw const InvalidFilePathException('Could not resolve a valid file path.');
      }

      await player.setAudioSource(AudioSource.uri(Uri.file(path))).timeout(
        const Duration(seconds: kLoadTimeoutSeconds),
        onTimeout: () {
          throw TimeoutException(
            'Loading timed out after ${kLoadTimeoutSeconds}s',
          );
        },
      );
      await _applySpeedAndPitch(speed);

      if (autoPlay) {
        await player.play();
      }
    } catch (e) {
      loadedItem.hasError = true;
      _currentTrackId = previousTrackId;
      _emitError('Couldn\'t load "${loadedItem.file.name}": ${describeError(e)}');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Reacts to the current track finishing playback naturally, driving
  /// auto-advance according to [repeatMode] and [isShuffleEnabled]. See
  /// the class doc comment ("Repeat & Shuffle") for the full behavior
  /// matrix.
  Future<void> _handleTrackCompleted() async {
    if (_isHandlingCompletion) return;
    if (_currentTrackId == null) return;

    _isHandlingCompletion = true;
    try {
      if (_repeatMode == RepeatMode.one) {
        await player.seek(Duration.zero);
        await player.play();
        return;
      }

      if (_isShuffleEnabled && _shuffleOrder.isNotEmpty) {
        final atEnd = _shuffleCursor >= _shuffleOrder.length - 1;
        if (atEnd) {
          if (_repeatMode == RepeatMode.all) {
            _regenerateShuffleOrder();
            if (_shuffleOrder.isNotEmpty) {
              await loadTrackById(_shuffleOrder[_shuffleCursor], autoPlay: true);
            }
          }
          // RepeatMode.off and shuffle order exhausted: stop here.
          return;
        }
        _shuffleCursor++;
        await loadTrackById(_shuffleOrder[_shuffleCursor], autoPlay: true);
        return;
      }

      final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
      if (currentIndex == -1) return;

      if (currentIndex < _queue.length - 1) {
        await loadTrackById(_queue[currentIndex + 1].id, autoPlay: true);
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        await loadTrackById(_queue.first.id, autoPlay: true);
      }
      // RepeatMode.off and already on the last track: stop here.
    } finally {
      _isHandlingCompletion = false;
    }
  }

  Future<void> skipToNext() async {
    if (!_ensureTrackAvailable()) return;
    final wasPlaying = player.playing;

    if (_isShuffleEnabled && _shuffleOrder.isNotEmpty) {
      _shuffleCursor = (_shuffleCursor + 1) % _shuffleOrder.length;
      await loadTrackById(_shuffleOrder[_shuffleCursor], autoPlay: wasPlaying);
      return;
    }

    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final nextIndex = (currentIndex + 1) % _queue.length;
    await loadTrackById(_queue[nextIndex].id, autoPlay: wasPlaying);
  }

  Future<void> skipToPrevious() async {
    if (!_ensureTrackAvailable()) return;
    final wasPlaying = player.playing;

    if (_isShuffleEnabled && _shuffleOrder.isNotEmpty) {
      _shuffleCursor = (_shuffleCursor - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      await loadTrackById(_shuffleOrder[_shuffleCursor], autoPlay: wasPlaying);
      return;
    }

    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final previousIndex = (currentIndex - 1 + _queue.length) % _queue.length;
    await loadTrackById(_queue[previousIndex].id, autoPlay: wasPlaying);
  }

  Future<void> removeTrack(int id) async {
    final wasCurrent = _currentTrackId == id;

    QueueItem? removedItem;
    for (final item in _queue) {
      if (item.id == id) {
        removedItem = item;
        break;
      }
    }

    _queue.removeWhere((item) => item.id == id);

    if (wasCurrent) {
      _currentTrackId = null;
      try {
        await player.pause();
        await player.seek(Duration.zero);
      } catch (_) {
        // Nothing meaningful to do if this fails during teardown.
      }
    }

    if (_isShuffleEnabled) {
      _regenerateShuffleOrder(keepCurrentId: _currentTrackId);
    }

    notifyListeners();
    unawaited(_persistQueue());

    if (removedItem != null) {
      unawaited(_deleteStoredFile(removedItem.file.path));
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
    // Deliberately NOT regenerating the shuffle order here: shuffle
    // traversal intentionally ignores the queue's manual ordering, so a
    // pure reorder (no membership change) has no effect on it.
    notifyListeners();
    unawaited(_persistQueue());
  }

  Future<void> clearQueue() async {
    final removedItems = List<QueueItem>.from(_queue);

    _queue.clear();
    _currentTrackId = null;
    _shuffleOrder = [];
    _shuffleCursor = -1;
    notifyListeners();
    try {
      await player.pause();
      await player.seek(Duration.zero);
    } catch (_) {
      // Nothing meaningful to do if this fails during teardown.
    }
    unawaited(_persistQueue());

    for (final item in removedItems) {
      unawaited(_deleteStoredFile(item.file.path));
    }
  }

  /// Starts/resumes playback of the currently loaded track. If nothing is
  /// loaded, emits a friendly guidance message instead of silently
  /// doing nothing (see [_ensureTrackAvailable]).
  Future<void> play() async {
    if (!_ensureTrackAvailable()) return;
    try {
      await player.play();
    } catch (e) {
      _emitError('Playback error: ${describeError(e)}');
    }
  }

  /// Pauses playback of the currently loaded track, if any.
  Future<void> pause() async {
    if (_currentTrackId == null) return;
    try {
      await player.pause();
    } catch (e) {
      _emitError('Playback error: ${describeError(e)}');
    }
  }

  Future<void> togglePlayPause() async {
    if (player.playing) {
      await pause();
    } else {
      await play();
    }
  }

  /// Stops playback and resets position to the start. If nothing is
  /// loaded, emits a friendly guidance message (see
  /// [_ensureTrackAvailable]).
  Future<void> stopPlayback() async {
    if (!_ensureTrackAvailable()) return;
    try {
      await player.pause();
      await player.seek(Duration.zero);
    } catch (e) {
      _emitError('Playback error: ${describeError(e)}');
    }
  }

  /// Applies [value] as the playback speed AND the pitch multiplier,
  /// reproducing the natural "tape/vinyl speed" Nightcore effect where
  /// speeding up playback raises pitch by the same factor.
  ///
  /// setPitch() is retried on every call rather than being permanently
  /// disabled after a failure — this makes pitch shifting self-healing:
  /// if the underlying native build gets fixed (e.g. after a proper clean
  /// iOS rebuild), it will simply start working on the next attempt.
  Future<void> _applySpeedAndPitch(double value) async {
    await player.setSpeed(value);

    try {
      await player.setPitch(value);
    } on MissingPluginException {
      if (!_pitchWarningShown) {
        _pitchWarningShown = true;
        _emitError(
          'Pitch shifting isn\'t available on this build yet. On iOS, try a full '
          'clean rebuild (pod reinstall + fresh "flutter run") to enable it. '
          'Speed will still change tempo in the meantime.',
          severity: NotificationSeverity.warning,
        );
      }
    }
  }

  Future<void> _commitSpeed(double value) async {
    try {
      await _applySpeedAndPitch(value);
    } catch (e) {
      _emitError('Failed to change speed/pitch: ${describeError(e)}');
    }
  }

  /// Updates the playback speed (and, in lockstep, the pitch).
  ///
  /// The on-screen slider value updates instantly via [speedNotifier]
  /// regardless of [immediate] — dragging always feels perfectly smooth.
  /// What's throttled is the actual native `setSpeed`/`setPitch` platform
  /// channel calls: while [immediate] is false (the default, used by the
  /// Slider's onChanged), at most one engine update is sent every
  /// [kSliderThrottleDuration], always carrying the latest dragged value.
  ///
  /// Pass [immediate] = true for discrete, one-shot changes (Nightcore
  /// toggle, preset selection) where there's no risk of call-spamming and
  /// snappy feedback matters more than throttling.
  Future<void> setSpeed(double newSpeed, {bool immediate = false}) async {
    speedNotifier.value = newSpeed;

    if (immediate) {
      _speedThrottleTimer?.cancel();
      _speedThrottleTimer = null;
      _pendingSpeedValue = null;
      await _commitSpeed(newSpeed);
      return;
    }

    _pendingSpeedValue = newSpeed;
    _speedThrottleTimer ??= Timer(kSliderThrottleDuration, () {
      _speedThrottleTimer = null;
      final valueToApply = _pendingSpeedValue;
      _pendingSpeedValue = null;
      if (valueToApply != null) {
        _commitSpeed(valueToApply);
      }
    });
  }

  /// Toggles between 1.0x (normal) and the Nightcore preset speed. Uses
  /// [immediate] application since this is a discrete tap, not a drag.
  void toggleNightcoreMode() {
    if (isNightcoreActive) {
      setSpeed(1.0, immediate: true);
    } else {
      setSpeed(kNightcoreSpeed, immediate: true);
    }
  }

  Future<void> _commitVolume(double value) async {
    try {
      await player.setVolume(value);
    } catch (e) {
      _emitError('Failed to change volume: ${describeError(e)}');
    }
  }

  /// Updates the playback volume. Same instant-UI / throttled-engine-call
  /// rationale as [setSpeed] — see its doc comment for details.
  ///
  /// Note: if called while a "duck" interruption is active (see the
  /// class doc comment), this intentionally sets the engine to the exact
  /// requested value, effectively ending the temporary duck early — this
  /// is a rare edge case (the user manually dragging the volume slider
  /// during a brief system sound) and not worth special-casing further.
  Future<void> setVolume(double newVolume, {bool immediate = false}) async {
    volumeNotifier.value = newVolume;

    if (immediate) {
      _volumeThrottleTimer?.cancel();
      _volumeThrottleTimer = null;
      _pendingVolumeValue = null;
      await _commitVolume(newVolume);
      return;
    }

    _pendingVolumeValue = newVolume;
    _volumeThrottleTimer ??= Timer(kSliderThrottleDuration, () {
      _volumeThrottleTimer = null;
      final valueToApply = _pendingVolumeValue;
      _pendingVolumeValue = null;
      if (valueToApply != null) {
        _commitVolume(valueToApply);
      }
    });
  }

  /// Mutes/unmutes. Uses [immediate] application since this is a discrete
  /// tap, not a drag.
  void toggleMute() {
    if (volume > 0) {
      _volumeBeforeMute = volume;
      setVolume(0.0, immediate: true);
    } else {
      setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1.0, immediate: true);
    }
  }
}

/// Bridges this app's manually-managed playback queue with the OS-level
/// `audio_service` framework, so that system notification / lock-screen
/// transport controls (play, pause, skip next/previous, seek, stop,
/// repeat, shuffle) route directly into [PlayerController]'s own
/// queue-aware logic.
///
/// This replaces relying on just_audio's built-in `ConcatenatingAudioSource`
/// skip handling, which doesn't apply here since tracks are loaded one at a
/// time via `setAudioSource()` rather than as a single gapless playlist.
///
/// This handler is instantiated exactly once, via `AudioService.init()` in
/// `main()`, and is intended to live for the entire process lifetime —
/// matching the standard `audio_service` pattern where the handler backs a
/// long-running background service rather than a disposable UI widget.
/// It therefore intentionally does not expose a dispose()/teardown method:
/// there is no well-defined point in normal app usage where "stop
/// listening to the player, but keep the process running" would be
/// correct, and real cleanup happens when the OS reclaims the process.
class NightcoreAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlayerController _controller;

  NightcoreAudioHandler(this._controller) {
    _controller.addListener(_syncMediaItem);
    _controller.addListener(_syncPlaybackState);
    _controller.player.durationStream.listen((_) => _syncMediaItem());
    _controller.player.playerStateStream.listen((_) => _syncPlaybackState());
    _controller.player.positionStream.listen((_) => _syncPlaybackState());

    _syncMediaItem();
    _syncPlaybackState();
  }

  /// Pushes the current track's title/duration to the system notification
  /// and lock screen whenever the loaded track or its duration changes.
  void _syncMediaItem() {
    final item = _controller.currentItem;
    if (item == null) {
      mediaItem.add(null);
      return;
    }
    mediaItem.add(MediaItem(
      id: item.id.toString(),
      title: stripExtension(item.file.name),
      artist: 'NightcorePlayer',
      duration: _controller.player.duration,
    ));
  }

  /// Pushes the current playback status (playing/paused, position, speed,
  /// repeat/shuffle mode, available controls) to the system notification
  /// and lock screen.
  void _syncPlaybackState() {
    final player = _controller.player;
    final playing = player.playing;

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: _mapProcessingState(player.processingState),
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      repeatMode: _mapRepeatMode(_controller.repeatMode),
      shuffleMode: _mapShuffleMode(_controller.isShuffleEnabled),
    ));
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  AudioServiceRepeatMode _mapRepeatMode(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return AudioServiceRepeatMode.none;
      case RepeatMode.all:
        return AudioServiceRepeatMode.all;
      case RepeatMode.one:
        return AudioServiceRepeatMode.one;
    }
  }

  AudioServiceShuffleMode _mapShuffleMode(bool enabled) =>
      enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none;

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> stop() async {
    await _controller.stopPlayback();
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  @override
  Future<void> seek(Duration position) => _controller.player.seek(position);

  @override
  Future<void> skipToNext() => _controller.skipToNext();

  @override
  Future<void> skipToPrevious() => _controller.skipToPrevious();

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final RepeatMode mode;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        mode = RepeatMode.one;
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        mode = RepeatMode.all;
        break;
      case AudioServiceRepeatMode.none:
        mode = RepeatMode.off;
        break;
    }
    _controller.setRepeatMode(mode);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    if (enabled != _controller.isShuffleEnabled) {
      _controller.toggleShuffle();
    }
  }
}