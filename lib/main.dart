import 'package:flutter/material.dart';

import 'dashboard_page.dart';
import 'display_page.dart';
import 'other_page.dart';

void main() {
  runApp(const AnyHackApp());
}

class AnyHackApp extends StatefulWidget {
  const AnyHackApp({super.key});

  @override
  State<AnyHackApp> createState() => _AnyHackAppState();
}

class _AnyHackAppState extends State<AnyHackApp> {
  ThemeMode _mode = ThemeMode.system;

  void _cycleTheme() {
    setState(() {
      _mode = switch (_mode) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnyHack',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
        ),
      ),
      home: HomeShell(onToggleTheme: _cycleTheme, mode: _mode),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.onToggleTheme,
    required this.mode,
  });

  final VoidCallback onToggleTheme;
  final ThemeMode mode;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _titles = ['Dashboard', 'Display', 'Other'];

  IconData _themeIcon() => switch (widget.mode) {
        ThemeMode.system => Icons.brightness_auto,
        ThemeMode.light => Icons.light_mode,
        ThemeMode.dark => Icons.dark_mode,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AnyHack · ${_titles[_index]}'),
        actions: [
          IconButton(
            tooltip: 'Тема: системная / светлая / тёмная',
            onPressed: widget.onToggleTheme,
            icon: Icon(_themeIcon()),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [DashboardPage(), DisplayPage(), OtherPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.display_settings_outlined),
            selectedIcon: Icon(Icons.display_settings),
            label: 'Display',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_remote_outlined),
            selectedIcon: Icon(Icons.settings_remote),
            label: 'Other',
          ),
        ],
      ),
    );
  }
}
