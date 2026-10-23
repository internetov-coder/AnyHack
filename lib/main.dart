import 'package:flutter/material.dart';

import 'dashboard_page.dart';
import 'display_page.dart';
import 'other_page.dart';
import 'poll_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PollConfig.init();
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

  Future<void> _editInterval() async {
    final controller = TextEditingController(
      text: (PollConfig.intervalMs.value / 1000).toString(),
    );
    var choice = PollConfig.intervalMs.value == 500
        ? 0
        : PollConfig.intervalMs.value == 1000
            ? 1
            : 2; // 0 = 0.5 с, 1 = 1 с, 2 = custom

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Интервал обновления'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('0.5 с'),
                    selected: choice == 0,
                    onSelected: (_) => setD(() => choice = 0),
                  ),
                  ChoiceChip(
                    label: const Text('1 с'),
                    selected: choice == 1,
                    onSelected: (_) => setD(() => choice = 1),
                  ),
                  ChoiceChip(
                    label: const Text('Custom'),
                    selected: choice == 2,
                    onSelected: (_) => setD(() => choice = 2),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                enabled: choice == 2,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Время обновления',
                  suffixText: 'сек',
                  hintText: 'например, 2.5',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                int ms;
                if (choice == 0) {
                  ms = 500;
                } else if (choice == 1) {
                  ms = 1000;
                } else {
                  final v = double.tryParse(
                      controller.text.trim().replaceAll(',', '.'));
                  if (v == null || v < 0.1 || v > 60) return;
                  ms = (v * 1000).round();
                }
                PollConfig.set(ms);
                Navigator.pop(ctx);
              },
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AnyHack · ${_titles[_index]}'),
        actions: [
          if (_index == 0)
            IconButton(
              tooltip: 'Интервал обновления',
              onPressed: _editInterval,
              icon: const Icon(Icons.settings),
            ),
          if (_index == 2)
            IconButton(
              tooltip: 'Добавить пульт (.ir)',
              onPressed: () => OtherPage.importAction?.call(),
              icon: const Icon(Icons.add),
            ),
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
