import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'root_shell.dart';

class DisplayPage extends StatefulWidget {
  const DisplayPage({super.key});

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  static const _keys = [
    'user_refresh_rate',
    'miui_refresh_rate',
    'min_refresh_rate',
    'peak_refresh_rate',
  ];

  static const _presets = <({String label, int? hz, IconData icon})>[
    (label: 'Auto (Dynamic)', hz: null, icon: Icons.autorenew),
    (label: '60 Hz', hz: 60, icon: Icons.looks_one),
    (label: '90 Hz', hz: 90, icon: Icons.filter_9),
    (label: '120 Hz', hz: 120, icon: Icons.bolt),
    (label: '144 Hz', hz: 144, icon: Icons.rocket_launch),
  ];

  Map<String, String> _values = {for (final k in _keys) k: '—'};
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final out = await RootShell.instance.run(
      'settings get system user_refresh_rate; '
      'settings get system miui_refresh_rate; '
      'settings get system min_refresh_rate; '
      'settings get system peak_refresh_rate',
    );
    // Только строки вида null/<число> — устойчиво к шуму su-баннера.
    final vals = out
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e == 'null' || RegExp(r'^\d+$').hasMatch(e))
        .take(_keys.length)
        .toList();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _keys.length; i++) {
        _values[_keys[i]] = i < vals.length ? vals[i] : '—';
      }
    });
  }

  int? get _lockedHz {
    final peak = int.tryParse(_values['peak_refresh_rate'] ?? '');
    final min = int.tryParse(_values['min_refresh_rate'] ?? '');
    if (peak != null && min != null && peak == min) return peak;
    return null;
  }

  bool get _isAuto => _values['min_refresh_rate'] == 'null';

  Future<void> _apply(int? hz) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    HapticFeedback.selectionClick();

    final String cmd;
    if (hz == null) {
      // Auto: снимаем лок (min удаляется), потолок — максимум панели 144 Гц.
      cmd = 'settings put system user_refresh_rate 144; '
          'settings put system miui_refresh_rate 144; '
          'settings put system peak_refresh_rate 144; '
          'settings delete system min_refresh_rate';
    } else {
      // Лок: min == peak => фиксированная частота; дублируем MIUI-ключи.
      cmd = 'settings put system user_refresh_rate $hz; '
          'settings put system miui_refresh_rate $hz; '
          'settings put system min_refresh_rate $hz; '
          'settings put system peak_refresh_rate $hz';
    }
    await RootShell.instance.run(cmd);
    await _read();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = hz == null
          ? 'Auto: min сброшен, peak/user/miui = 144 (динамическая герцовка)'
          : 'Лок $hz Гц: min = peak = user = miui = $hz';
    });
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Системные ключи', style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (_busy)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final k in _keys)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(k, style: Theme.of(context).textTheme.bodySmall),
                          ),
                          Text(
                            _values[k] ?? '—',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: (_values[k] == 'null' || _values[k] == '—')
                                  ? scheme.outline
                                  : scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(_message!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Применение: root-запись settings put system … · панель Xiaomi 14T '
            'поддерживает 60/90/120/144 Гц',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        const SizedBox(height: 8),
        for (final p in _presets) _presetTile(context, p),
      ],
    );
  }

  Widget _presetTile(
    BuildContext context,
    ({String label, int? hz, IconData icon}) p,
  ) {
    final selected = p.hz == null ? _isAuto : (_lockedHz == p.hz);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        color: selected ? scheme.primaryContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : () => _apply(p.hz),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(p.icon, color: selected ? scheme.onPrimaryContainer : null),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    p.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: selected ? scheme.onPrimaryContainer : null,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
