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
// detect "is the slider at exactly the Nightcore preset" despite potential
// tiny floating-point drift from division-based slider steps.
const double kSpeedCompareTolerance = 0.001;

// Maximum time to wait for a track to load before treating it as failed.
const int kLoadTimeoutSeconds = 15;

// SharedPreferences key under which saved Speed & Pitch presets are stored.
const String _kPresetsPrefsKey = 'nightcore_speed_pitch_presets';

/// Strips the file extension from a file name for cleaner display.
/// Shared by both the UI layer and the controller (used when building
/// MediaItem metadata for the background playback notification).
String stripExtension(String fileName) {
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot <= 0) return fileName;
  return fileName.substring(0, lastDot);
}

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

/// Translates a raised exception into a short, user-friendly message.
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
/// the playback queue, speed/pitch/volume state, and saved presets.
/// Notifies listeners on every meaningful state change so the UI layer can
/// react via [ListenableBuilder] without any manual wiring.
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
    _loadPresets();
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
    final finalName = trimmed.isEmpty ? '${_speed.toStringAsFixed(2)}x' : trimmed;
    final preset = SpeedPitchPreset(id: _nextPresetId++, name: finalName, value: _speed);
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

  /// Applies a saved preset's value as the current speed & pitch.
  void applyPreset(SpeedPitchPreset preset) {
    setSpeed(preset.value);
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
      // Wrapping the local file in an AudioSource with a MediaItem tag lets
      // just_audio_background populate the system notification / lock
      // screen with a title and artist for this track automatically.
      final audioSource = AudioSource.uri(
        Uri.file(path),
        tag: MediaItem(
          id: target.id.toString(),
          title: stripExtension(target.file.name),
          artist: 'NightcorePlayer',
        ),
      );

      await player.setAudioSource(audioSource).timeout(
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

  Future<void> setSpeed(double newSpeed) async {
    _speed = newSpeed;
    notifyListeners();
    try {
      await _applySpeedAndPitch(newSpeed);
    } catch (e) {
      _emitError('Failed to change speed/pitch: ${describeError(e)}');
    }
  }

  void toggleNightcoreMode() {
    if (isNightcoreActive) {
      setSpeed(1.0);
    } else {
      setSpeed(kNightcoreSpeed);
    }
  }

  Future<void> setVolume(double newVolume) async {
    _volume = newVolume;
    notifyListeners();
    try {
      await player.setVolume(newVolume);
    } catch (e) {
      _emitError('Failed to change volume: ${describeError(e)}');
    }
  }

  void toggleMute() {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      setVolume(0.0);
    } else {
      setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1.0);
    }
  }
}