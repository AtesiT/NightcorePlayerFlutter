import 'package:flutter/material.dart';

void main() {
  runApp(const NightcorePlayerApp());
}

class AppColors {
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF282828);
  static const surfaceLight = Color(0xFF3E3E3E);
  static const accentGreen = Color(0xFF1DB954);
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xFFB3B3B3);
}

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

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  static const List<Widget> _tabs = [
    PlayerScreen(),
    QueueScreen(),
  ];

  void _onTabTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: _tabs[_selectedIndex]),
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
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
            child: const Icon(
              Icons.music_note_rounded,
              size: 100,
              color: AppColors.textSecondary,
            ),
          ),

          const Spacer(flex: 1),

          // Track title & artist placeholders
          const Text(
            'No track loaded',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            'Pick a file to get started',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
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

          // Playback controls row (visual only — wired up in Phase 5)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Icon(Icons.shuffle, color: AppColors.textSecondary, size: 24),
              Icon(Icons.skip_previous_rounded, color: AppColors.textPrimary, size: 36),
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: AppColors.accentGreen,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 36),
              ),
              Icon(Icons.skip_next_rounded, color: AppColors.textPrimary, size: 36),
              Icon(Icons.repeat, color: AppColors.textSecondary, size: 24),
            ],
          ),

          const Spacer(flex: 2),
        ],
      ),
    );
  }
}

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Queue',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
        ),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.queue_music_outlined, size: 56, color: AppColors.textSecondary),
                SizedBox(height: 12),
                Text(
                  'No tracks in queue yet',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}