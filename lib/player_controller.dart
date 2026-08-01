import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

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
// detect "is the slider at exactly the Nightcore preset" despite potential
// tiny floating-point drift from division-based slider steps.
const double kSpeedCompareTolerance = 0.001;

// Maximum time to wait for a track to load before treating it as failed.
const int kLoadTimeoutSeconds = 15;

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

/// Translates a raised exception into a short, user-friendly message.
/// Covers the most common failure modes: missing files, unsupported/corrupt
/// formats, timeouts, missing platform implementations, and generic errors.
String describeError(Object error) {
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
/// the playback queue, and all speed/pitch/volume state. Notifies listeners
/// on every meaningful state change so the UI layer can react via
/// [ListenableBuilder] without any manual wiring.
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

  double _speed = 1.0;
  double get speed => _speed;

  double _volume = 1.0;
  double get volume => _volume;
  double _volumeBeforeMute = 1.0;

  // Tracks whether independent pitch-shifting is actually supported by the
  // current platform/build. Set to false permanently for the session if a
  // MissingPluginException is ever caught, preventing repeated failed calls.
  bool _pitchSupported = true;
  bool _pitchWarningShown = false;

  StreamSubscription<PlayerState>? _playerStateSubscription;

  final StreamController<String> _errorController = StreamController<String>.broadcast();

  /// Broadcast stream of user-facing error messages. The UI layer should
  /// listen to this and display each message (e.g., via a SnackBar).
  Stream<String> get errors => _errorController.stream;

  bool get isNightcoreActive =>
      (_speed - kNightcoreSpeed).abs() < kSpeedCompareTolerance;

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
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    player.dispose();
    _errorController.close();
    super.dispose();
  }

  void _emitError(String message) {
    if (!_errorController.isClosed) {
      _errorController.add(message);
    }
  }

  /// Opens the native file picker allowing multi-selection of audio files,
  /// appends the results to the queue, and auto-loads the first file if
  /// the queue was previously empty.
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
        // Initial load stays paused — the user hasn't explicitly asked to
        // play yet, they've just picked files.
        await loadTrackById(newItems.first.id, autoPlay: false);
      }
    } catch (e) {
      _emitError('Failed to open file picker: ${describeError(e)}');
    }
  }

  /// Loads the queue item identified by [id] into the audio engine.
  /// If [autoPlay] is true, playback starts automatically once loaded.
  Future<void> loadTrackById(int id, {bool autoPlay = false}) async {
    QueueItem? target;
    for (final item in _queue) {
      if (item.id == id) {
        target = item;
        break;
      }
    }
    if (target == null) return;

    final path = target.file.path;
    final previousTrackId = _currentTrackId;

    if (path == null) {
      _handleLoadFailure(
        target: target,
        previousTrackId: previousTrackId,
        message: 'Could not resolve a valid file path.',
      );
      return;
    }

    _isLoading = true;
    _currentTrackId = id;
    target.hasError = false;
    notifyListeners();

    try {
      await player.setFilePath(path).timeout(
        const Duration(seconds: kLoadTimeoutSeconds),
        onTimeout: () {
          throw TimeoutException(
            'Loading timed out after ${kLoadTimeoutSeconds}s',
          );
        },
      );
      await _applySpeedAndPitch(_speed);

      if (autoPlay) {
        await player.play();
      }
    } catch (e) {
      _handleLoadFailure(
        target: target,
        previousTrackId: previousTrackId,
        message: describeError(e),
      );
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Marks [target] as failed, reverts the active selection to whatever
  /// was loaded before the attempt, and surfaces a descriptive error.
  void _handleLoadFailure({
    required QueueItem target,
    required int? previousTrackId,
    required String message,
  }) {
    target.hasError = true;
    _currentTrackId = previousTrackId;
    _isLoading = false;
    notifyListeners();
    _emitError('Couldn\'t load "${target.file.name}": $message');
  }

  /// Called whenever the engine reports the current track has finished
  /// playing naturally. Advances to the next track in the current visual
  /// queue order, if one exists. If the finished track was the last one
  /// in the queue, playback simply stops (no looping back to the start).
  Future<void> _handleTrackCompleted() async {
    if (_isHandlingCompletion) return;
    if (_currentTrackId == null) return;

    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    // Last track in the queue — nothing to advance to, playback stops.
    if (currentIndex >= _queue.length - 1) return;

    _isHandlingCompletion = true;
    try {
      final nextItem = _queue[currentIndex + 1];
      await loadTrackById(nextItem.id, autoPlay: true);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  /// Skips to the next track in the current visual queue order, wrapping
  /// around to the first track if currently on the last one. Preserves
  /// whatever play/pause state was active before the skip.
  Future<void> skipToNext() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = player.playing;
    final nextIndex = (currentIndex + 1) % _queue.length;
    await loadTrackById(_queue[nextIndex].id, autoPlay: wasPlaying);
  }

  /// Skips to the previous track in the current visual queue order,
  /// wrapping around to the last track if currently on the first one.
  /// Preserves whatever play/pause state was active before the skip.
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = player.playing;
    final previousIndex = (currentIndex - 1 + _queue.length) % _queue.length;
    await loadTrackById(_queue[previousIndex].id, autoPlay: wasPlaying);
  }

  /// Removes the queue item with [id]. If it was the currently loaded
  /// track, playback is stopped and the "current track" is cleared.
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

  /// Reorders the queue. Since the current track is tracked by id rather
  /// than index, no extra bookkeeping is needed here.
  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);
    notifyListeners();
  }

  /// Clears the entire queue and stops playback.
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

  Future<void> togglePlayPause() async {
    if (_currentTrackId == null) return;
    try {
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (e) {
      _emitError('Playback error: ${describeError(e)}');
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

  /// Applies [value] as the playback speed, and — if supported — also as
  /// the pitch multiplier, to reproduce the linked Nightcore-style effect.
  /// If the platform/build doesn't support setPitch (throws
  /// MissingPluginException), pitch adjustments are disabled for the rest
  /// of the session and a one-time warning is emitted, while speed changes
  /// continue to work normally.
  Future<void> _applySpeedAndPitch(double value) async {
    await player.setSpeed(value);

    if (!_pitchSupported) return;

    try {
      await player.setPitch(value);
    } on MissingPluginException {
      _pitchSupported = false;
      if (!_pitchWarningShown) {
        _pitchWarningShown = true;
        _emitError(
          'Pitch shifting isn\'t available on this build/platform. '
          'Speed will still change tempo, but pitch will stay constant.',
        );
      }
    }
  }

  /// Updates the combined speed & pitch multiplier both in local state and
  /// on the engine. Both are set to the same value to emulate natural
  /// tape-speed pitch shifting (the classic Nightcore effect).
  Future<void> setSpeed(double newSpeed) async {
    _speed = newSpeed;
    notifyListeners();
    try {
      await _applySpeedAndPitch(newSpeed);
    } catch (e) {
      _emitError('Failed to change speed/pitch: ${describeError(e)}');
    }
  }

  /// Toggles between the Nightcore preset (1.25x) and normal speed (1.0x).
  void toggleNightcoreMode() {
    if (isNightcoreActive) {
      setSpeed(1.0);
    } else {
      setSpeed(kNightcoreSpeed);
    }
  }

  /// Updates the volume both in local state and on the engine.
  Future<void> setVolume(double newVolume) async {
    _volume = newVolume;
    notifyListeners();
    try {
      await player.setVolume(newVolume);
    } catch (e) {
      _emitError('Failed to change volume: ${describeError(e)}');
    }
  }

  /// Toggles mute: if currently audible, remembers the volume and sets it
  /// to 0. If currently muted, restores the remembered volume.
  void toggleMute() {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      setVolume(0.0);
    } else {
      setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1.0);
    }
  }
}