import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'player_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Create the shared PlayerController first — the AudioHandler below
  // wraps its existing AudioPlayer instance and queue logic directly,
  // rather than owning a separate one.
  final controller = PlayerController();

  // Registers our custom AudioHandler with the system's audio_service
  // framework. This routes system notification / lock-screen transport
  // controls (play, pause, skip, seek, stop) directly into our own
  // queue-aware PlayerController methods.
  await AudioService.init(
    builder: () => NightcoreAudioHandler(controller),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.nightcoreplayerflutter.audio',
      androidNotificationChannelName: 'NightcorePlayer Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(NightcorePlayerApp(controller: controller));
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

/// Shared transition used for track-change animations (album art, title):
/// a gentle fade combined with a small upward slide.
Widget _trackChangeTransition(Widget child, Animation<double> animation) {
  final offsetAnim = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(animation);
  return FadeTransition(
    opacity: animation,
    child: SlideTransition(position: offsetAnim, child: child),
  );
}

/// Opens a modal bottom sheet for viewing, applying, saving, and deleting
/// Speed & Pitch presets.
Future<void> _openPresetsSheet(BuildContext context, PlayerController controller) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => _PresetsSheet(controller: controller),
  );
}

/// Root widget of the NightcorePlayerFlutter application.
class NightcorePlayerApp extends StatelessWidget {
  final PlayerController controller;

  const NightcorePlayerApp({super.key, required this.controller});

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
      home: RootShell(controller: controller),
    );
  }
}

/// The root shell hosting the bottom navigation bar and switching between
/// the Player tab and the Queue tab. Receives the shared [PlayerController]
/// instance created in main() (so it can also be wired into the
/// NightcoreAudioHandler before the widget tree exists).
///
/// Note: this ListenableBuilder only listens to PlayerController's own
/// ChangeNotifier (queue/track/preset changes) — speed and volume changes
/// are intentionally excluded (see PlayerController's doc comment), so
/// dragging those sliders never triggers a rebuild here.
class RootShell extends StatefulWidget {
  final PlayerController controller;

  const RootShell({super.key, required this.controller});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;
  late final PlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
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
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final tabs = [
              PlayerScreen(controller: _controller),
              QueueScreen(controller: _controller),
            ];
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: KeyedSubtree(
                key: ValueKey(_selectedIndex),
                child: tabs[_selectedIndex],
              ),
            );
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
  bool _isDragging = false;
  Duration? _dragPosition;
  bool _wasPlayingBeforeDrag = false;

  AudioPlayer get _player => widget.controller.player;

  void _onSeekStart(double valueMs) {
    _wasPlayingBeforeDrag = _player.playing;
    setState(() {
      _isDragging = true;
      _dragPosition = Duration(milliseconds: valueMs.round());
    });
    if (_wasPlayingBeforeDrag) {
      _player.pause();
    }
  }

  void _onSeekChanged(double valueMs) {
    setState(() {
      _dragPosition = Duration(milliseconds: valueMs.round());
    });
  }

  Future<void> _onSeekEnd(double valueMs) async {
    final seekTarget = Duration(milliseconds: valueMs.round());
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
    final trackKey = ValueKey(controller.currentTrackId ?? -1);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: _trackChangeTransition,
            child: Container(
              key: trackKey,
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
          ),

          const Spacer(flex: 1),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: _trackChangeTransition,
            child: Text(
              displayName ?? 'No track loaded',
              key: trackKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
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

          const SizedBox(height: 10),

          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              final isActive = hasTrack && playing;
              // Wrapped in RepaintBoundary: this widget animates
              // continuously at ~60fps while active, so isolating its
              // repaint layer prevents that from forcing repaints of
              // surrounding, otherwise-static UI.
              return RepaintBoundary(
                child: _VisualizerStrip(
                  isActive: isActive,
                  color: hasTrack ? AppColors.accentGreen : AppColors.surfaceLight,
                ),
              );
            },
          ),

          const SizedBox(height: 10),

          StreamBuilder<Duration?>(
            stream: _player.durationStream,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data;
              final maxMs = (duration?.inMilliseconds ?? 0).toDouble();
              final seekEnabled = hasTrack && maxMs > 0;

              return StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, positionSnapshot) {
                  final livePosition = positionSnapshot.data ?? Duration.zero;
                  final displayPosition =
                      _isDragging && _dragPosition != null ? _dragPosition! : livePosition;

                  final clampedMs = displayPosition.inMilliseconds
                      .clamp(0, maxMs > 0 ? maxMs.toInt() : 0)
                      .toDouble();
                  final progress = seekEnabled && maxMs > 0 ? (clampedMs / maxMs) : 0.0;

                  return Column(
                    children: [
                      RepaintBoundary(
                        child: _CustomSeekBar(
                          progress: progress,
                          enabled: seekEnabled,
                          onDragStart: (p) => _onSeekStart(p * maxMs),
                          onDragUpdate: (p) => _onSeekChanged(p * maxMs),
                          onDragEnd: () =>
                              _onSeekEnd(_dragPosition?.inMilliseconds.toDouble() ?? 0),
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

          // Scoped to controller.speedNotifier only: dragging this slider
          // rebuilds just this small subtree, not the whole PlayerScreen.
          ValueListenableBuilder<double>(
            valueListenable: controller.speedNotifier,
            builder: (context, speedValue, _) {
              final isNightcore = (speedValue - kNightcoreSpeed).abs() < kSpeedCompareTolerance;
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          isNightcore ? '⚡ Nightcore Mode' : 'Speed & Pitch',
                          key: ValueKey(isNightcore),
                          style: TextStyle(
                            color: isNightcore ? AppColors.accentGreen : AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: isNightcore ? FontWeight.w700 : FontWeight.normal,
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            formatSpeed(speedValue),
                            style: const TextStyle(
                              color: AppColors.accentGreen,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Opens the Presets sheet (save/apply/delete).
                          GestureDetector(
                            onTap: () => _openPresetsSheet(context, controller),
                            child: const Icon(
                              Icons.bookmark_border_rounded,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: speedValue,
                      min: kMinSpeed,
                      max: kMaxSpeed,
                      divisions: kSpeedDivisions,
                      onChanged: controller.setSpeed,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _NightcoreToggleChip(
                    isActive: isNightcore,
                    onTap: controller.toggleNightcoreMode,
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 10),

          // Scoped to controller.volumeNotifier only: dragging this
          // slider rebuilds just this small subtree.
          ValueListenableBuilder<double>(
            valueListenable: controller.volumeNotifier,
            builder: (context, volumeValue, _) {
              return Row(
                children: [
                  GestureDetector(
                    onTap: controller.toggleMute,
                    child: Icon(
                      _volumeIcon(volumeValue),
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
                        value: volumeValue,
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
                      formatVolumePercent(volumeValue),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              );
            },
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
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: AppColors.accentGreen,
                        shape: BoxShape.circle,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, animation) => ScaleTransition(
                          scale: animation,
                          child: FadeTransition(opacity: animation, child: child),
                        ),
                        child: Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          key: ValueKey(playing),
                          color: Colors.black,
                          size: 34,
                        ),
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

/// Modal bottom sheet content listing saved Speed & Pitch presets, with
/// actions to apply, save a new one, or delete existing ones.
class _PresetsSheet extends StatelessWidget {
  final PlayerController controller;

  const _PresetsSheet({required this.controller});

  Future<void> _promptSaveNewPreset(BuildContext context) async {
    final nameController = TextEditingController();
    final suggested = formatSpeed(controller.speed);

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Save Preset', style: TextStyle(color: AppColors.textPrimary)),
          content: TextField(
            controller: nameController,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Preset name (e.g. "$suggested")',
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surfaceLight),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.accentGreen),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(nameController.text),
              child: const Text('Save', style: TextStyle(color: AppColors.accentGreen)),
            ),
          ],
        );
      },
    );

    if (name != null) {
      await controller.savePreset(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        // Merged with speedNotifier so the "active preset" highlight
        // stays correct if speed changes while this sheet is open (e.g.
        // applying a preset), without listening to the full controller
        // for every routine slider drag elsewhere in the app.
        listenable: Listenable.merge([controller, controller.speedNotifier]),
        builder: (context, _) {
          final presets = controller.presets;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Presets',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _promptSaveNewPreset(context),
                      icon: const Icon(Icons.add, color: AppColors.accentGreen, size: 18),
                      label: const Text('Save Current', style: TextStyle(color: AppColors.accentGreen)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (presets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No presets saved yet',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: presets.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final preset = presets[index];
                        final isActive =
                            (preset.value - controller.speed).abs() < kSpeedCompareTolerance;
                        return ListTile(
                          onTap: () => controller.applyPreset(preset),
                          tileColor: isActive ? AppColors.surfaceLight : null,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          leading: Icon(
                            isActive ? Icons.bookmark : Icons.bookmark_border,
                            color: isActive ? AppColors.accentGreen : AppColors.textSecondary,
                          ),
                          title: Text(preset.name, style: const TextStyle(color: AppColors.textPrimary)),
                          subtitle: Text(
                            formatSpeed(preset.value),
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: AppColors.accentRed, size: 20),
                            onPressed: () => controller.deletePreset(preset.id),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A lightweight, programmatic audio visualizer strip.
class _VisualizerStrip extends StatefulWidget {
  final bool isActive;
  final Color color;

  const _VisualizerStrip({required this.isActive, required this.color});

  @override
  State<_VisualizerStrip> createState() => _VisualizerStripState();
}

class _VisualizerStripState extends State<_VisualizerStrip>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 28;
  static const double _stripHeight = 28;

  late final AnimationController _controller;
  late final List<double> _phases;
  late final List<double> _amplitudes;

  @override
  void initState() {
    super.initState();
    final rand = math.Random(7);
    _phases = List.generate(_barCount, (_) => rand.nextDouble() * 2 * math.pi);
    _amplitudes = List.generate(_barCount, (_) => 0.4 + rand.nextDouble() * 0.6);

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    if (widget.isActive) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _VisualizerStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _stripHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(_barCount, (i) {
              double heightFactor;
              if (widget.isActive) {
                final t = _controller.value * 2 * math.pi;
                final wave = math.sin(t + _phases[i]);
                heightFactor = 0.15 + _amplitudes[i] * (0.5 + 0.5 * wave);
              } else {
                heightFactor = 0.12;
              }
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 3,
                height: _stripHeight * heightFactor.clamp(0.08, 1.0),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// A custom, drag-only seek bar.
class _CustomSeekBar extends StatelessWidget {
  final double progress;
  final bool enabled;
  final ValueChanged<double>? onDragStart;
  final ValueChanged<double>? onDragUpdate;
  final VoidCallback? onDragEnd;

  const _CustomSeekBar({
    required this.progress,
    required this.enabled,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  double _progressFromDx(double dx, double width) {
    if (width <= 0) return 0;
    return (dx / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (details) =>
                  onDragStart?.call(_progressFromDx(details.localPosition.dx, width))
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) =>
                  onDragUpdate?.call(_progressFromDx(details.localPosition.dx, width))
              : null,
          onHorizontalDragEnd: enabled ? (_) => onDragEnd?.call() : null,
          child: SizedBox(
            height: 24,
            width: double.infinity,
            child: CustomPaint(
              painter: _SeekBarPainter(
                progress: progress,
                enabled: enabled,
                activeColor: AppColors.accentGreen,
                inactiveColor: AppColors.surfaceLight,
                thumbColor: AppColors.textPrimary,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeekBarPainter extends CustomPainter {
  final double progress;
  final bool enabled;
  final Color activeColor;
  final Color inactiveColor;
  final Color thumbColor;

  _SeekBarPainter({
    required this.progress,
    required this.enabled,
    required this.activeColor,
    required this.inactiveColor,
    required this.thumbColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const trackHeight = 3.0;
    final centerY = size.height / 2;

    final trackPaint = Paint()..color = inactiveColor;
    final trackRect = RRect.fromLTRBR(
      0,
      centerY - trackHeight / 2,
      size.width,
      centerY + trackHeight / 2,
      const Radius.circular(2),
    );
    canvas.drawRRect(trackRect, trackPaint);

    if (!enabled) return;

    final activeWidth = size.width * progress.clamp(0.0, 1.0);
    final activePaint = Paint()..color = activeColor;
    final activeRect = RRect.fromLTRBR(
      0,
      centerY - trackHeight / 2,
      activeWidth,
      centerY + trackHeight / 2,
      const Radius.circular(2),
    );
    canvas.drawRRect(activeRect, activePaint);

    final thumbPaint = Paint()..color = thumbColor;
    canvas.drawCircle(Offset(activeWidth, centerY), 6, thumbPaint);
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.enabled != enabled;
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

/// A small animated 3-bar equalizer visual for the active Queue item.
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
                                                // Wrapped in RepaintBoundary: continuously
                                                // animates while playing, isolated so it
                                                // doesn't force repaints of the whole
                                                // ListView item / list.
                                                return playing
                                                    ? const RepaintBoundary(
                                                        child: _EqualizerBars(color: Colors.black),
                                                      )
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