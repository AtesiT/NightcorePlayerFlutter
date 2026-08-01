import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'player_controller.dart';

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

/// Strips the file extension from a file name for cleaner display.
/// E.g. "song.mp3" -> "song". If there's no extension, returns as-is.
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
/// the Player tab and the Queue tab. Owns the [PlayerController] instance
/// (the single source of truth for all playback/queue state) and forwards
/// its error stream to SnackBars.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;
  late final PlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PlayerController();
    _controller.errors.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // Rebuilds whenever the controller calls notifyListeners(), which
        // covers queue changes, speed/volume/nightcore changes, loading
        // state, and current-track changes. Real-time playback position is
        // still handled separately via StreamBuilder inside PlayerScreen to
        // avoid rebuilding the whole tree on every ~200ms position tick.
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final tabs = [
              PlayerScreen(controller: _controller),
              QueueScreen(controller: _controller),
            ];
            return tabs[_selectedIndex];
          },
        ),
      ),
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
  final PlayerController controller;

  const PlayerScreen({super.key, required this.controller});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Local drag state for the seek slider — purely a UI concern, not part
  // of the shared controller state.
  bool _isDragging = false;
  Duration? _dragPosition;
  bool _wasPlayingBeforeDrag = false;

  AudioPlayer get _player => widget.controller.player;

  void _onSeekStart(double value) {
    _wasPlayingBeforeDrag = _player.playing;
    setState(() {
      _isDragging = true;
      _dragPosition = Duration(milliseconds: value.round());
    });
    if (_wasPlayingBeforeDrag) {
      _player.pause();
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
      await _player.seek(seekTarget);
      if (_wasPlayingBeforeDrag) {
        await _player.play();
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
    final controller = widget.controller;
    final currentTrackName = controller.currentItem?.file.name;
    final hasTrack = currentTrackName != null;
    final displayName = hasTrack ? stripExtension(currentTrackName) : null;

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
              child: controller.isLoading
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
            stream: _player.playerStateStream,
            builder: (context, snapshot) {
              final state = snapshot.data;
              final playing = state?.playing ?? false;
              final processingState = state?.processingState;

              String statusText;
              if (!hasTrack) {
                statusText = 'Pick a file to get started';
              } else if (controller.isLoading) {
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
            stream: _player.durationStream,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data;
              final maxMs = (duration?.inMilliseconds ?? 0).toDouble();
              final sliderEnabled = hasTrack && maxMs > 0;

              return StreamBuilder<Duration>(
                stream: _player.positionStream,
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
                      controller.isNightcoreActive ? '⚡ Nightcore Mode' : 'Speed & Pitch',
                      key: ValueKey(controller.isNightcoreActive),
                      style: TextStyle(
                        color: controller.isNightcoreActive
                            ? AppColors.accentGreen
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: controller.isNightcoreActive
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    formatSpeed(controller.speed),
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
                  value: controller.speed,
                  min: kMinSpeed,
                  max: kMaxSpeed,
                  divisions: kSpeedDivisions,
                  onChanged: controller.setSpeed,
                ),
              ),
              const SizedBox(height: 4),
              _NightcoreToggleChip(
                isActive: controller.isNightcoreActive,
                onTap: controller.toggleNightcoreMode,
              ),
            ],
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              GestureDetector(
                onTap: controller.toggleMute,
                child: Icon(
                  _volumeIcon(controller.volume),
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
                    value: controller.volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: controller.setVolume,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 38,
                child: Text(
                  formatVolumePercent(controller.volume),
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
                onPressed: controller.stopPlayback,
                icon: const Icon(Icons.stop_rounded),
                color: AppColors.textSecondary,
                iconSize: 26,
              ),
              GestureDetector(
                onTap: controller.skipToPrevious,
                child: const Icon(
                  Icons.skip_previous_rounded,
                  color: AppColors.textPrimary,
                  size: 36,
                ),
              ),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return GestureDetector(
                    onTap: controller.togglePlayPause,
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
                onTap: controller.skipToNext,
                child: const Icon(
                  Icons.skip_next_rounded,
                  color: AppColors.textPrimary,
                  size: 36,
                ),
              ),
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
  final PlayerController controller;

  const QueueScreen({super.key, required this.controller});

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
      controller.clearQueue();
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = controller.queue;

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
                    onReorder: controller.reorderQueue,
                    itemBuilder: (context, index) {
                      final item = queue[index];
                      final isActive = item.id == controller.currentTrackId;
                      final isActiveLoading = isActive && controller.isLoading;
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
                          onDismissed: (_) => controller.removeTrack(item.id),
                          child: ListTile(
                            onTap: () => controller.loadTrackById(item.id, autoPlay: true),
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
                                              stream: controller.player.playerStateStream,
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
        onPressed: controller.pickAudioFiles,
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