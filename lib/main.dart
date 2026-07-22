import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
}

// Supported audio file extensions for the picker.
const List<String> kSupportedAudioExtensions = [
  'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac',
];

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

  // Holds all picked audio files. PlatformFile already gives us name, path,
  // and size without needing a custom model class — keeps things minimal.
  final List<PlatformFile> _queue = [];

  // The just_audio engine instance.
  final AudioPlayer _player = AudioPlayer();

  // Index of the currently loaded track within _queue, or null if none.
  int? _currentIndex;

  // True while a track is in the process of being loaded into the engine.
  bool _isLoading = false;

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

      // result is null if the user cancelled the picker.
      if (result == null || result.files.isEmpty) return;

      setState(() {
        _queue.addAll(result.files);
      });

      if (wasQueueEmpty) {
        await _loadTrack(0);
      }
    } catch (e) {
      _showError('Failed to pick files: $e');
    }
  }

  /// Loads the track at [index] into the audio engine.
  Future<void> _loadTrack(int index) async {
    if (index < 0 || index >= _queue.length) return;

    final file = _queue[index];
    final path = file.path;

    if (path == null) {
      _showError('Could not resolve a file path for "${file.name}".');
      return;
    }

    setState(() {
      _isLoading = true;
      _currentIndex = index;
    });

    try {
      await _player.setFilePath(path);
    } catch (e) {
      _showError('Failed to load "${file.name}": $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Toggles between play and pause. Does nothing if no track is loaded.
  Future<void> _togglePlayPause() async {
    if (_currentIndex == null) return;

    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  /// Stops playback: pauses and resets position to the start.
  /// Does not unload the track. Does nothing if no track is loaded.
  Future<void> _stopPlayback() async {
    if (_currentIndex == null) return;

    await _player.pause();
    await _player.seek(Duration.zero);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
        onPlayPause: _togglePlayPause,
        onStop: _stopPlayback,
      ),
      QueueScreen(
        queue: _queue,
        currentIndex: _currentIndex,
        isLoading: _isLoading,
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

class PlayerScreen extends StatelessWidget {
  final String? currentTrackName;
  final bool isLoading;
  final AudioPlayer player;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;

  const PlayerScreen({
    super.key,
    this.currentTrackName,
    this.isLoading = false,
    required this.player,
    required this.onPlayPause,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final hasTrack = currentTrackName != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(flex: 2),

          // Album art placeholder
          Container(
            width: 260,
            height: 260,
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
              child: isLoading
                  ? const CircularProgressIndicator(color: AppColors.accentGreen)
                  : const Icon(
                      Icons.music_note_rounded,
                      size: 100,
                      color: AppColors.textSecondary,
                    ),
            ),
          ),

          const Spacer(flex: 1),

          // Track title
          Text(
            hasTrack ? currentTrackName! : 'No track loaded',
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

          // Live status text driven by the player state stream.
          StreamBuilder<PlayerState>(
            stream: player.playerStateStream,
            builder: (context, snapshot) {
              final state = snapshot.data;
              final playing = state?.playing ?? false;
              final processingState = state?.processingState;

              String statusText;
              if (!hasTrack) {
                statusText = 'Pick a file to get started';
              } else if (isLoading) {
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

          const SizedBox(height: 24),

          // Progress bar placeholder (disabled, static for now)
          Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: 0,
                  onChanged: null, // Disabled until Phase 7
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0:00', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text('0:00', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Playback controls row.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Stop — functional, resets position and pauses.
              IconButton(
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
                color: AppColors.textSecondary,
                iconSize: 26,
              ),

              // Skip previous — decorative until Phase 14.
              const Icon(Icons.skip_previous_rounded, color: AppColors.surfaceLight, size: 36),

              // Play / Pause — functional, reacts to real player state.
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return GestureDetector(
                    onTap: onPlayPause,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: AppColors.accentGreen,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.black,
                        size: 36,
                      ),
                    ),
                  );
                },
              ),

              // Skip next — decorative until Phase 14.
              const Icon(Icons.skip_next_rounded, color: AppColors.surfaceLight, size: 36),

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

class QueueScreen extends StatelessWidget {
  final List<PlatformFile> queue;
  final int? currentIndex;
  final bool isLoading;
  final VoidCallback onAddPressed;
  final ValueChanged<int> onTrackTapped;

  const QueueScreen({
    super.key,
    required this.queue,
    required this.currentIndex,
    required this.isLoading,
    required this.onAddPressed,
    required this.onTrackTapped,
  });

  /// Formats file size in bytes into a compact human-readable string.
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

                      return ListTile(
                        onTap: () => onTrackTapped(index),
                        selected: isActive,
                        selectedTileColor: AppColors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        leading: CircleAvatar(
                          backgroundColor:
                              isActive ? AppColors.accentGreen : AppColors.surface,
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
                                  isActive ? Icons.graphic_eq : Icons.music_note,
                                  color: isActive ? Colors.black : AppColors.textSecondary,
                                  size: 20,
                                ),
                        ),
                        title: Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isActive ? AppColors.accentGreen : AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          _formatFileSize(file.size),
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
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