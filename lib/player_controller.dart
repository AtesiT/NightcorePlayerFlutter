import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
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

// SharedPreferences key under which saved Speed & Pitch presets are stored.
const String _kPresetsPrefsKey = 'nightcore_speed_pitch_presets';

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
/// Playback errors are surfaced through the [errors] broadcast stream
/// rather than directly showing UI, keeping this class fully independent
/// of BuildContext/widgets.
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

  // Saved Speed & Pitch presets, persisted via shared_preferences.
  List<SpeedPitchPreset> _presets = [];
  List<SpeedPitchPreset> get presets => List.unmodifiable(_presets);
  int _nextPresetId = 0;
  bool _presetsLoaded = false;
  bool get presetsLoaded => _presetsLoaded;

  StreamSubscription<PlayerState>? _playerStateSubscription;

  final StreamController<String> _errorController = StreamController<String>.broadcast();

  /// Broadcast stream of user-facing error messages. The UI layer should
  /// listen to this and display each message (e.g., via a SnackBar).
  Stream<String> get errors => _errorController.stream;

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
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _speedThrottleTimer?.cancel();
    _volumeThrottleTimer?.cancel();
    speedNotifier.dispose();
    volumeNotifier.dispose();
    player.dispose();
    _errorController.close();
    super.dispose();
  }

  void _emitError(String message) {
    if (!_errorController.isClosed) {
      _errorController.add(message);
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
  Future<void> savePreset(String name) async {
    final trimmed = name.trim();
    final finalName = trimmed.isEmpty ? '${speed.toStringAsFixed(2)}x' : trimmed;
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

  Future<void> pickAudioFiles() async {
    try {
      final wasQueueEmpty = _queue.isEmpty;

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: kSupportedAudioExtensions,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      final newItems = result.files
          .map((f) => QueueItem(id: _nextId++, file: f))
          .toList();

      _queue.addAll(newItems);
      notifyListeners();

      if (wasQueueEmpty && newItems.isNotEmpty) {
        await loadTrackById(newItems.first.id, autoPlay: false);
      }
    } catch (e) {
      _emitError('Failed to open file picker: ${describeError(e)}');
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

  Future<void> _handleTrackCompleted() async {
    if (_isHandlingCompletion) return;
    if (_currentTrackId == null) return;

    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    if (currentIndex >= _queue.length - 1) return;

    _isHandlingCompletion = true;
    try {
      final nextItem = _queue[currentIndex + 1];
      await loadTrackById(nextItem.id, autoPlay: true);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  Future<void> skipToNext() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = player.playing;
    final nextIndex = (currentIndex + 1) % _queue.length;
    await loadTrackById(_queue[nextIndex].id, autoPlay: wasPlaying);
  }

  Future<void> skipToPrevious() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = player.playing;
    final previousIndex = (currentIndex - 1 + _queue.length) % _queue.length;
    await loadTrackById(_queue[previousIndex].id, autoPlay: wasPlaying);
  }

  Future<void> removeTrack(int id) async {
    final wasCurrent = _currentTrackId == id;

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
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
    notifyListeners();
  }

  Future<void> clearQueue() async {
    _queue.clear();
    _currentTrackId = null;
    notifyListeners();
    try {
      await player.pause();
      await player.seek(Duration.zero);
    } catch (_) {
      // Nothing meaningful to do if this fails during teardown.
    }
  }

  /// Starts/resumes playback of the currently loaded track, if any.
  Future<void> play() async {
    if (_currentTrackId == null) return;
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

  Future<void> stopPlayback() async {
    if (_currentTrackId == null) return;
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
/// transport controls (play, pause, skip next/previous, seek, stop) route
/// directly into [PlayerController]'s own queue-aware logic.
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
  /// available controls) to the system notification and lock screen.
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
}