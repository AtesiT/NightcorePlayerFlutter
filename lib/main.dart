import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  runApp(const NightcorePlayerApp());
}

// Spotify-inspired color palette, defined as constants for easy reuse.
class AppColors {
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF282828);
  static const surfaceLight = Color(0xFF3E3E3E);
  static const accentGreen = Color(0xFF1DB954);
  static const accentRed = Color(0xFFE57373);
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
}

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

// Tolerance used when comparing floating-point speed values.
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

/// Strips the file extension from a file name for cleaner display.
String stripExtension(String fileName) {
  final lastDot = fileName.lastIndexOf('.');
  if (lastDot <= 0) return fileName;
  return fileName.substring(0, lastDot);
}

/// Formats a [Duration] as "m:ss". Returns "--:--" if [duration] is null.
String formatDuration(Duration? duration) {
  if (duration == null) return '--:--';
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Formats a speed multiplier as "1.25x".
String formatSpeed(double speed) => '${speed.toStringAsFixed(2)}x';

/// Formats a 0.0–1.0 volume level as a percentage string, e.g. "100%".
String formatVolumePercent(double volume) => '${(volume * 100).round()}%';

/// Translates a raised exception into a short, user-friendly message.
String describeError(Object error) {
  if (error is TimeoutException) {
    return 'Loading timed out. The file may be corrupted, too large, or inaccessible.';
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

/// Root widget of the NightcorePlayerFlutter application.
class NightcorePlayerApp extends StatelessWidget {
  const NightcorePlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NightcorePlayer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accentGreen,
          secondary: AppColors.accentGreen,
          surface: AppColors.surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          elevation: 0,
          foregroundColor: AppColors.textPrimary,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: AppColors.accentGreen,
          inactiveTrackColor: AppColors.surfaceLight,
          thumbColor: AppColors.textPrimary,
          overlayColor: AppColors.accentGreen.withValues(alpha: 0.2),
          trackHeight: 3,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.accentGreen,
          unselectedItemColor: AppColors.textSecondary,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: const RootShell(),
    );
  }
}

/// The root shell hosting the bottom navigation bar and switching between
/// the Player tab and the Queue tab. Also owns the queue state and the
/// audio player instance for now, since it's the shared ancestor of both
/// tabs. Will be extracted into a dedicated controller in Phase 15.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  final List<QueueItem> _queue = [];
  final AudioPlayer _player = AudioPlayer();

  // Incrementing counter used to assign a stable, unique id to every
  // picked file, independent of its position in the list.
  int _nextId = 0;

  // Id of the currently loaded track, or null if none.
  int? _currentTrackId;

  bool _isLoading = false;

  // Guards against re-entrant auto-advance calls if the completed state
  // fires more than once in quick succession.
  bool _isHandlingCompletion = false;

  double _speed = 1.0;
  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;

  StreamSubscription<PlayerState>? _playerStateSubscription;

  bool get _isNightcoreActive =>
      (_speed - kNightcoreSpeed).abs() < kSpeedCompareTolerance;

  /// The currently loaded queue item, or null if none / it was removed.
  QueueItem? get _currentItem {
    if (_currentTrackId == null) return null;
    for (final item in _queue) {
      if (item.id == _currentTrackId) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Listen for track completion to drive auto-advance to the next track.
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _handleTrackCompleted();
      }
    });
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  /// Opens the native file picker allowing multi-selection of audio files,
  /// appends the results to the queue, and auto-loads the first file if
  /// the queue was previously empty.
  Future<void> _pickAudioFiles() async {
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

      setState(() {
        _queue.addAll(newItems);
      });

      if (wasQueueEmpty && newItems.isNotEmpty) {
        // Initial load stays paused — the user hasn't explicitly asked to
        // play yet, they've just picked files.
        await _loadTrackById(newItems.first.id, autoPlay: false);
      }
    } catch (e) {
      _showError('Failed to open file picker: ${describeError(e)}');
    }
  }

  /// Loads the queue item identified by [id] into the audio engine.
  /// If [autoPlay] is true, playback starts automatically once loaded.
  Future<void> _loadTrackById(int id, {bool autoPlay = false}) async {
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

    setState(() {
      _isLoading = true;
      _currentTrackId = id;
      target!.hasError = false;
    });

    try {
      await _player.setFilePath(path).timeout(
        const Duration(seconds: kLoadTimeoutSeconds),
        onTimeout: () {
          throw TimeoutException(
            'Loading timed out after ${kLoadTimeoutSeconds}s',
          );
        },
      );
      await _player.setSpeed(_speed);
      await _player.setPitch(_speed);

      if (autoPlay) {
        await _player.play();
      }
    } catch (e) {
      _handleLoadFailure(
        target: target,
        previousTrackId: previousTrackId,
        message: describeError(e),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Marks [target] as failed, reverts the active selection to whatever
  /// was loaded before the attempt, and surfaces a descriptive error.
  void _handleLoadFailure({
    required QueueItem target,
    required int? previousTrackId,
    required String message,
  }) {
    if (!mounted) return;
    setState(() {
      target.hasError = true;
      _currentTrackId = previousTrackId;
      _isLoading = false;
    });
    _showError('Couldn\'t load "${stripExtension(target.file.name)}": $message');
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
      await _loadTrackById(nextItem.id, autoPlay: true);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  /// Skips to the next track in the current visual queue order, wrapping
  /// around to the first track if currently on the last one. Preserves
  /// whatever play/pause state was active before the skip.
  Future<void> _skipToNext() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = _player.playing;
    final nextIndex = (currentIndex + 1) % _queue.length;
    await _loadTrackById(_queue[nextIndex].id, autoPlay: wasPlaying);
  }

  /// Skips to the previous track in the current visual queue order,
  /// wrapping around to the last track if currently on the first one.
  /// Preserves whatever play/pause state was active before the skip.
  Future<void> _skipToPrevious() async {
    if (_queue.isEmpty || _currentTrackId == null) return;
    final currentIndex = _queue.indexWhere((item) => item.id == _currentTrackId);
    if (currentIndex == -1) return;

    final wasPlaying = _player.playing;
    final previousIndex = (currentIndex - 1 + _queue.length) % _queue.length;
    await _loadTrackById(_queue[previousIndex].id, autoPlay: wasPlaying);
  }

  /// Removes the queue item with [id]. If it was the currently loaded
  /// track, playback is stopped and the "current track" is cleared.
  Future<void> _removeTrack(int id) async {
    final wasCurrent = _currentTrackId == id;

    setState(() {
      _queue.removeWhere((item) => item.id == id);
    });

    if (wasCurrent) {
      setState(() {
        _currentTrackId = null;
      });
      try {
        await _player.pause();
        await _player.seek(Duration.zero);
      } catch (_) {
        // Nothing meaningful to do if this fails during teardown.
      }
    }
  }

  /// Reorders the queue. Since the current track is tracked by id rather
  /// than index, no extra bookkeeping is needed here.
  void _reorderQueue(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, item);
    });
  }

  /// Clears the entire queue and stops playback.
  Future<void> _clearQueue() async {
    setState(() {
      _queue.clear();
      _currentTrackId = null;
    });
    try {
      await _player.pause();
      await _player.seek(Duration.zero);
    } catch (_) {
      // Nothing meaningful to do if this fails during teardown.
    }
  }

  Future<void> _togglePlayPause() async {
    if (_currentTrackId == null) return;
    try {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (e) {
      _showError('Playback error: ${describeError(e)}');
    }
  }

  Future<void> _stopPlayback() async {
    if (_currentTrackId == null) return;
    try {
      await _player.pause();
      await _player.seek(Duration.zero);
    } catch (e) {
      _showError('Playback error: ${describeError(e)}');
    }
  }

  Future<void> _setSpeed(double newSpeed) async {
    setState(() {
      _speed = newSpeed;
    });
    try {
      await _player.setSpeed(newSpeed);
      await _player.setPitch(newSpeed);
    } catch (e) {
      _showError('Failed to change speed/pitch: ${describeError(e)}');
    }
  }

  void _toggleNightcoreMode() {
    if (_isNightcoreActive) {
      _setSpeed(1.0);
    } else {
      _setSpeed(kNightcoreSpeed);
    }
  }

  Future<void> _setVolume(double newVolume) async {
    setState(() {
      _volume = newVolume;
    });
    try {
      await _player.setVolume(newVolume);
    } catch (e) {
      _showError('Failed to change volume: ${describeError(e)}');
    }
  }

  void _toggleMute() {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      _setVolume(0.0);
    } else {
      _setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1.0);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = _currentItem;

    final tabs = [
      PlayerScreen(
        currentTrackName: currentItem?.file.name,
        isLoading: _isLoading,
        player: _player,
        speed: _speed,
        isNightcoreActive: _isNightcoreActive,
        volume: _volume,
        onPlayPause: _togglePlayPause,
        onStop: _stopPlayback,
        onSkipNext: _skipToNext,
        onSkipPrevious: _skipToPrevious,
        onSpeedChanged: _setSpeed,
        onToggleNightcore: _toggleNightcoreMode,
        onVolumeChanged: _setVolume,
        onToggleMute: _toggleMute,
      ),
      QueueScreen(
        queue: _queue,
        currentTrackId: _currentTrackId,
        isLoading: _isLoading,
        player: _player,
        onAddPressed: _pickAudioFiles,
        // Manual queue selection always forces playback to start, per the
        // agreed "seamless replace" behavior.
        onTrackTapped: (id) => _loadTrackById(id, autoPlay: true),
        onTrackRemoved: _removeTrack,
        onReorder: _reorderQueue,
        onClearAll: _clearQueue,
      ),
    ];

    return Scaffold(
      body: SafeArea(child: tabs[_selectedIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTabTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.play_circle_outline),
            activeIcon: Icon(Icons.play_circle_fill),
            label: 'Player',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.queue_music_outlined),
            activeIcon: Icon(Icons.queue_music),
            label: 'Queue',
          ),
        ],
      ),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final String? currentTrackName;
  final bool isLoading;
  final AudioPlayer player;
  final double speed;
  final bool isNightcoreActive;
  final double volume;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final VoidCallback onSkipNext;
  final VoidCallback onSkipPrevious;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onToggleNightcore;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;

  const PlayerScreen({
    super.key,
    this.currentTrackName,
    this.isLoading = false,
    required this.player,
    required this.speed,
    required this.isNightcoreActive,
    required this.volume,
    required this.onPlayPause,
    required this.onStop,
    required this.onSkipNext,
    required this.onSkipPrevious,
    required this.onSpeedChanged,
    required this.onToggleNightcore,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _isDragging = false;
  Duration? _dragPosition;
  bool _wasPlayingBeforeDrag = false;

  void _onSeekStart(double value) {
    _wasPlayingBeforeDrag = widget.player.playing;
    setState(() {
      _isDragging = true;
      _dragPosition = Duration(milliseconds: value.round());
    });
    if (_wasPlayingBeforeDrag) {
      widget.player.pause();
    }
  }

  void _onSeekChanged(double value) {
    setState(() {
      _dragPosition = Duration(milliseconds: value.round());
    });
  }

  Future<void> _onSeekEnd(double value) async {
    final seekTarget = Duration(milliseconds: value.round());
    try {
      await widget.player.seek(seekTarget);
      if (_wasPlayingBeforeDrag) {
        await widget.player.play();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Seek failed: ${describeError(e)}')),
        );
      }
    }
    if (mounted) {
      setState(() {
        _isDragging = false;
        _dragPosition = null;
      });
    }
  }

  IconData _volumeIcon(double volume) {
    if (volume <= 0.0) return Icons.volume_off_rounded;
    if (volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = widget.currentTrackName != null;
    final displayName = hasTrack ? stripExtension(widget.currentTrackName!) : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),

          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Center(
              child: widget.isLoading
                  ? const CircularProgressIndicator(color: AppColors.accentGreen)
                  : const Icon(
                      Icons.music_note_rounded,
                      size: 90,
                      color: AppColors.textSecondary,
                    ),
            ),
          ),

          const Spacer(flex: 1),

          Text(
            displayName ?? 'No track loaded',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),

          StreamBuilder<PlayerState>(
            stream: widget.player.playerStateStream,
            builder: (context, snapshot) {
              final state = snapshot.data;
              final playing = state?.playing ?? false;
              final processingState = state?.processingState;

              String statusText;
              if (!hasTrack) {
                statusText = 'Pick a file to get started';
              } else if (widget.isLoading) {
                statusText = 'Loading...';
              } else if (processingState == ProcessingState.completed) {
                statusText = 'Finished';
              } else if (playing) {
                statusText = 'Now playing';
              } else {
                statusText = 'Paused';
              }

              return Text(
                statusText,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              );
            },
          ),

          const SizedBox(height: 16),

          StreamBuilder<Duration?>(
            stream: widget.player.durationStream,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data;
              final maxMs = (duration?.inMilliseconds ?? 0).toDouble();
              final sliderEnabled = hasTrack && maxMs > 0;

              return StreamBuilder<Duration>(
                stream: widget.player.positionStream,
                builder: (context, positionSnapshot) {
                  final livePosition = positionSnapshot.data ?? Duration.zero;
                  final displayPosition =
                      _isDragging && _dragPosition != null ? _dragPosition! : livePosition;

                  final clampedMs = displayPosition.inMilliseconds
                      .clamp(0, maxMs > 0 ? maxMs.toInt() : 0)
                      .toDouble();

                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value: sliderEnabled ? clampedMs : 0.0,
                          max: sliderEnabled ? maxMs : 1.0,
                          onChanged: sliderEnabled ? _onSeekChanged : null,
                          onChangeStart: sliderEnabled ? _onSeekStart : null,
                          onChangeEnd: sliderEnabled ? _onSeekEnd : null,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              hasTrack ? formatDuration(displayPosition) : '0:00',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              hasTrack ? formatDuration(duration) : '--:--',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),

          const SizedBox(height: 6),

          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      widget.isNightcoreActive ? '⚡ Nightcore Mode' : 'Speed & Pitch',
                      key: ValueKey(widget.isNightcoreActive),
                      style: TextStyle(
                        color: widget.isNightcoreActive
                            ? AppColors.accentGreen
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight:
                            widget.isNightcoreActive ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    formatSpeed(widget.speed),
                    style: const TextStyle(
                      color: AppColors.accentGreen,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: widget.speed,
                  min: kMinSpeed,
                  max: kMaxSpeed,
                  divisions: kSpeedDivisions,
                  onChanged: widget.onSpeedChanged,
                ),
              ),
              const SizedBox(height: 4),
              _NightcoreToggleChip(
                isActive: widget.isNightcoreActive,
                onTap: widget.onToggleNightcore,
              ),
            ],
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              GestureDetector(
                onTap: widget.onToggleMute,
                child: Icon(
                  _volumeIcon(widget.volume),
                  color: AppColors.textSecondary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  ),
                  child: Slider(
                    value: widget.volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: widget.onVolumeChanged,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 38,
                child: Text(
                  formatVolumePercent(widget.volume),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Playback controls row — skip previous/next are now fully
          // functional, wrapping around the queue's current visual order.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: widget.onStop,
                icon: const Icon(Icons.stop_rounded),
                color: AppColors.textSecondary,
                iconSize: 26,
              ),
              GestureDetector(
                onTap: widget.onSkipPrevious,
                child: const Icon(
                  Icons.skip_previous_rounded,
                  color: AppColors.textPrimary,
                  size: 36,
                ),
              ),
              StreamBuilder<PlayerState>(
                stream: widget.player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return GestureDetector(
                    onTap: widget.onPlayPause,
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: const BoxDecoration(
                        color: AppColors.accentGreen,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.black,
                        size: 34,
                      ),
                    ),
                  );
                },
              ),
              GestureDetector(
                onTap: widget.onSkipNext,
                child: const Icon(
                  Icons.skip_next_rounded,
                  color: AppColors.textPrimary,
                  size: 36,
                ),
              ),
              // Repeat — decorative placeholder, not part of current roadmap scope.
              const Icon(Icons.repeat, color: AppColors.surfaceLight, size: 24),
            ],
          ),

          const Spacer(flex: 2),
        ],
      ),
    );
  }
}

/// A pill-shaped toggle chip for quickly enabling/disabling Nightcore Mode.
class _NightcoreToggleChip extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _NightcoreToggleChip({
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.accentGreen : Colors.transparent,
          border: Border.all(color: AppColors.accentGreen, width: 1.5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bolt_rounded,
              size: 18,
              color: isActive ? Colors.black : AppColors.accentGreen,
            ),
            const SizedBox(width: 6),
            Text(
              'Nightcore',
              style: TextStyle(
                color: isActive ? Colors.black : AppColors.accentGreen,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small animated 3-bar equalizer visual, shown next to the active track
/// while it's actively playing. Purely decorative/lightweight.
class _EqualizerBars extends StatefulWidget {
  final Color color;

  const _EqualizerBars({required this.color});

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = _controller.value * 2 * math.pi + (i * 2.1);
            final heightFactor = 0.3 + 0.7 * (0.5 + 0.5 * math.sin(phase));
            return Container(
              width: 3,
              height: 14 * heightFactor,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

class QueueScreen extends StatelessWidget {
  final List<QueueItem> queue;
  final int? currentTrackId;
  final bool isLoading;
  final AudioPlayer player;
  final VoidCallback onAddPressed;
  final ValueChanged<int> onTrackTapped;
  final ValueChanged<int> onTrackRemoved;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onClearAll;

  const QueueScreen({
    super.key,
    required this.queue,
    required this.currentTrackId,
    required this.isLoading,
    required this.player,
    required this.onAddPressed,
    required this.onTrackTapped,
    required this.onTrackRemoved,
    required this.onReorder,
    required this.onClearAll,
  });

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = (bytes == 0) ? 0 : (bytes.bitLength - 1) ~/ 10;
    if (i >= suffixes.length) i = suffixes.length - 1;
    final size = bytes / (1 << (i * 10));
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear queue?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will remove all tracks from the queue and stop playback.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear All', style: TextStyle(color: AppColors.accentRed)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      onClearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Queue',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Row(
                  children: [
                    Text(
                      '${queue.length} track${queue.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    if (queue.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => _confirmClearAll(context),
                        child: const Text(
                          'Clear All',
                          style: TextStyle(
                            color: AppColors.accentRed,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: queue.isEmpty
                ? const _EmptyQueueState()
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: queue.length,
                    onReorder: onReorder,
                    itemBuilder: (context, index) {
                      final item = queue[index];
                      final isActive = item.id == currentTrackId;
                      final isActiveLoading = isActive && isLoading;
                      final hasError = item.hasError;

                      return Padding(
                        key: ValueKey(item.id),
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Dismissible(
                          key: ValueKey('dismiss_${item.id}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            decoration: BoxDecoration(
                              color: AppColors.accentRed,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.delete_outline, color: Colors.white),
                          ),
                          onDismissed: (_) => onTrackRemoved(item.id),
                          child: ListTile(
                            onTap: () => onTrackTapped(item.id),
                            selected: isActive && !hasError,
                            selectedTileColor: AppColors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: hasError
                                  ? const BorderSide(color: AppColors.accentRed, width: 1)
                                  : BorderSide.none,
                            ),
                            leading: CircleAvatar(
                              backgroundColor: hasError
                                  ? AppColors.accentRed.withValues(alpha: 0.15)
                                  : (isActive ? AppColors.accentGreen : AppColors.surface),
                              child: isActiveLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : hasError
                                      ? const Icon(
                                          Icons.error_outline,
                                          color: AppColors.accentRed,
                                          size: 20,
                                        )
                                      : isActive
                                          ? StreamBuilder<PlayerState>(
                                              stream: player.playerStateStream,
                                              builder: (context, snapshot) {
                                                final playing = snapshot.data?.playing ?? false;
                                                return playing
                                                    ? const _EqualizerBars(color: Colors.black)
                                                    : const Icon(
                                                        Icons.graphic_eq,
                                                        color: Colors.black,
                                                        size: 20,
                                                      );
                                              },
                                            )
                                          : const Icon(
                                              Icons.music_note,
                                              color: AppColors.textSecondary,
                                              size: 20,
                                            ),
                            ),
                            title: Text(
                              stripExtension(item.file.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: hasError
                                    ? AppColors.accentRed
                                    : (isActive ? AppColors.accentGreen : AppColors.textPrimary),
                                fontSize: 14,
                                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              hasError
                                  ? 'Failed to load — tap to retry'
                                  : _formatFileSize(item.file.size),
                              style: TextStyle(
                                color: hasError ? AppColors.accentRed : AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            trailing: ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(
                                  Icons.drag_handle,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onAddPressed,
        backgroundColor: AppColors.accentGreen,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Add Tracks'),
      ),
    );
  }
}

/// Empty-state placeholder shown when the queue has no tracks yet.
class _EmptyQueueState extends StatelessWidget {
  const _EmptyQueueState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.queue_music_outlined, size: 56, color: AppColors.textSecondary),
          SizedBox(height: 12),
          Text(
            'No tracks in queue yet',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
          ),
          SizedBox(height: 4),
          Text(
            'Tap "Add Tracks" to pick audio files',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}