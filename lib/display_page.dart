import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'root_shell.dart';

class DisplayPage extends StatefulWidget {
  const DisplayPage({super.key});

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  // ключи в двух пространствах, миуи читает и system и secure
  static const _keys = [
    'system user_refresh_rate',
    'system miui_refresh_rate',
    'system min_refresh_rate',
    'system peak_refresh_rate',
    'secure user_refresh_rate',
    'secure miui_refresh_rate',
  ];

  static const _getScript =
      'settings get system user_refresh_rate; '
      'settings get system miui_refresh_rate; '
      'settings get system min_refresh_rate; '
      'settings get system peak_refresh_rate; '
      'settings get secure user_refresh_rate; '
      'settings get secure miui_refresh_rate';

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
    // display всегда через su, этот путь проверен на устройстве
    final out =
        await RootShell.instance.run(_getScript, forceSu: true);
    // фильтр null/число защищает от шума вывода su
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

  int? _vInt(String key) => int.tryParse(_values[key] ?? '');

  int? get _lockedHz {
    final peak = _vInt('system peak_refresh_rate');
    final min = _vInt('system min_refresh_rate');
    if (peak != null && min != null && peak == min) return peak;
    return null;
  }

  bool get _isAuto => _values['system min_refresh_rate'] == 'null';

  Future<void> _apply(int? hz) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    HapticFeedback.selectionClick();

    final String cmd;
    if (hz == null) {
      // auto снимает лок, потолок 144
      cmd = 'settings put system user_refresh_rate 144; '
          'settings put system miui_refresh_rate 144; '
          'settings put system peak_refresh_rate 144; '
          'settings delete system min_refresh_rate; '
          'settings put secure user_refresh_rate 144; '
          'settings put secure miui_refresh_rate 144';
    } else {
      // фикс: min == peak, secure дублирует для миуи
      cmd = 'settings put system user_refresh_rate $hz; '
          'settings put system miui_refresh_rate $hz; '
          'settings put system min_refresh_rate $hz; '
          'settings put system peak_refresh_rate $hz; '
          'settings put secure user_refresh_rate $hz; '
          'settings put secure miui_refresh_rate $hz';
    }
    await RootShell.instance.run(cmd,
        timeout: const Duration(seconds: 5), forceSu: true);
    await _read();
    if (!mounted) return;

    // проверка по обратному чтению ключей
    final peak = _vInt('system peak_refresh_rate');
    final min = _vInt('system min_refresh_rate');
    final ok = hz == null
        ? (peak == 144 && min == null)
        : (peak == hz && min == hz);
    setState(() {
      _busy = false;
      if (ok) {
        _message = hz == null ? 'auto применён' : 'применилось: $hz Гц';
      } else {
        _message = 'не применилось (peak=${peak ?? 'null'}, '
            'min=${min ?? 'null'})';
      }
    });
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final peak = _vInt('system peak_refresh_rate');
    final min = _vInt('system min_refresh_rate');
    final ok = _message != null && !_message!.startsWith('не ');

    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Сейчас',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.outline),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          peak == null ? '—' : '$peak Гц',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          min == null
                              ? 'динамическая герцовка'
                              : 'зафиксирована min $min Гц',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_message != null)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: ok
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _message!,
                          textAlign: TextAlign.right,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: ok
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer
                                    : Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                              ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        _section(context, 'Частота'),
        _presetGrid(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            'панель xiaomi 14t: 60 / 90 / 120 / 144 гц · '
            'запись идёт в system и secure настройки',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text('Ключи настроек',
                  style: Theme.of(context).textTheme.titleMedium),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              children: [
                for (final k in _keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(k,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                        Text(
                          _values[k] ?? '—',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: (_values[k] == 'null' ||
                                    _values[k] == '—')
                                ? Theme.of(context).colorScheme.outline
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
      ),
    );
  }

  Widget _presetGrid(BuildContext context) {
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3.0,
      ),
      children: [
        for (final p in _presets)
          _presetCell(
            context,
            label: p.label,
            icon: p.icon,
            selected: p.hz == null ? _isAuto : (_lockedHz == p.hz),
            onTap: _busy ? null : () => _apply(p.hz),
          ),
        _presetCell(
          context,
          label: 'Custom Hz',
          icon: Icons.tune,
          selected: _lockedHz != null && ![60, 90, 120, 144].contains(_lockedHz),
          onTap: _busy ? null : _openCustom,
        ),
      ],
    );
  }

  Widget _presetCell(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.primaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? scheme.onPrimaryContainer : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? scheme.onPrimaryContainer : null,
                      ),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle,
                    size: 16, color: scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
