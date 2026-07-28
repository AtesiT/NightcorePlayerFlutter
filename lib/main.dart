import 'dart:async';
import 'dart:io';

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
/// Covers the most common failure modes: missing files, unsupported/corrupt
/// formats, timeouts, and generic platform errors.
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
/// the Player tab and the Queue tab. Also owns the picked-files queue state
/// and the audio player instance for now, since it's the shared ancestor
/// of both tabs. Will be extracted into a dedicated controller in Phase 15.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  final List<PlatformFile> _queue = [];
  final AudioPlayer _player = AudioPlayer();
  int? _currentIndex;
  bool _isLoading = false;

  // Indices of queue items that failed to load. Cleared for an index as
  // soon as the user retries and that retry succeeds.
  final Set<int> _loadErrorIndices = {};

  double _speed = 1.0;
  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;

  bool get _isNightcoreActive =>
      (_speed - kNightcoreSpeed).abs() < kSpeedCompareTolerance;

  @override
  void dispose() {
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

      setState(() {
        _queue.addAll(result.files);
      });

      if (wasQueueEmpty) {
        await _loadTrack(0);
      }
    } catch (e) {
      _showError('Failed to open file picker: ${describeError(e)}');
    }
  }

  /// Loads the track at [index] into the audio engine. On failure, the
  /// selection rolls back to whatever was previously loaded (or null),
  /// the failed index is flagged in the queue UI, and the track remains
  /// in the queue for the user to retry or ignore.
  Future<void> _loadTrack(int index) async {
    if (index < 0 || index >= _queue.length) return;

    final file = _queue[index];
    final path = file.path;
    final previousIndex = _currentIndex;

    if (path == null) {
      _handleLoadFailure(
        index: index,
        previousIndex: previousIndex,
        fileName: file.name,
        message: 'Could not resolve a valid file path.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _currentIndex = index;
      _loadErrorIndices.remove(index);
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
      // Re-apply speed & pitch, since some platforms reset them on load.
      await _player.setSpeed(_speed);
      await _player.setPitch(_speed);
    } catch (e) {
      _handleLoadFailure(
        index: index,
        previousIndex: previousIndex,
        fileName: file.name,
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

  /// Marks [index] as failed, reverts the active selection to whatever was
  /// loaded before the attempt, and surfaces a descriptive error message.
  void _handleLoadFailure({
    required int index,
    required int? previousIndex,
    required String fileName,
    required String message,
  }) {
    if (!mounted) return;
    setState(() {
      _loadErrorIndices.add(index);
      _currentIndex = previousIndex;
      _isLoading = false;
    });
    _showError('Couldn\'t load "${stripExtension(fileName)}": $message');
  }

  Future<void> _togglePlayPause() async {
    if (_currentIndex == null) return;
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
    if (_currentIndex == null) return;
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
    final currentFile = _currentIndex != null ? _queue[_currentIndex!] : null;

    final tabs = [
      PlayerScreen(
        currentTrackName: currentFile?.name,
        isLoading: _isLoading,
        player: _player,
        speed: _speed,
        isNightcoreActive: _isNightcoreActive,
        volume: _volume,
        onPlayPause: _togglePlayPause,
        onStop: _stopPlayback,
        onSpeedChanged: _setSpeed,
        onToggleNightcore: _toggleNightcoreMode,
        onVolumeChanged: _setVolume,
        onToggleMute: _toggleMute,
      ),
      QueueScreen(
        queue: _queue,
        currentIndex: _currentIndex,
        isLoading: _isLoading,
        errorIndices: _loadErrorIndices,
        onAddPressed: _pickAudioFiles,
        onTrackTapped: _loadTrack,
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
                              formatDuration(displayPosition),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              formatDuration(duration),
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

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: widget.onStop,
                icon: const Icon(Icons.stop_rounded),
                color: AppColors.textSecondary,
                iconSize: 26,
              ),
              const Icon(Icons.skip_previous_rounded, color: AppColors.surfaceLight, size: 36),
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
              const Icon(Icons.skip_next_rounded, color: AppColors.surfaceLight, size: 36),
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

class QueueScreen extends StatelessWidget {
  final List<PlatformFile> queue;
  final int? currentIndex;
  final bool isLoading;
  final Set<int> errorIndices;
  final VoidCallback onAddPressed;
  final ValueChanged<int> onTrackTapped;

  const QueueScreen({
    super.key,
    required this.queue,
    required this.currentIndex,
    required this.isLoading,
    required this.errorIndices,
    required this.onAddPressed,
    required this.onTrackTapped,
  });

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = (bytes == 0) ? 0 : (bytes.bitLength - 1) ~/ 10;
    if (i >= suffixes.length) i = suffixes.length - 1;
    final size = bytes / (1 << (i * 10));
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
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
                Text(
                  '${queue.length} track${queue.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          Expanded(
            child: queue.isEmpty
                ? const _EmptyQueueState()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: queue.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final file = queue[index];
                      final isActive = index == currentIndex;
                      final isActiveLoading = isActive && isLoading;
                      final hasError = errorIndices.contains(index);

                      return ListTile(
                        onTap: () => onTrackTapped(index),
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
                              : Icon(
                                  hasError
                                      ? Icons.error_outline
                                      : (isActive ? Icons.graphic_eq : Icons.music_note),
                                  color: hasError
                                      ? AppColors.accentRed
                                      : (isActive ? Colors.black : AppColors.textSecondary),
                                  size: 20,
                                ),
                        ),
                        title: Text(
                          stripExtension(file.name),
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
                              : _formatFileSize(file.size),
                          style: TextStyle(
                            color: hasError ? AppColors.accentRed : AppColors.textSecondary,
                            fontSize: 12,
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