import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ir_parser.dart';
import 'root_shell.dart';

class OtherPage extends StatefulWidget {
  const OtherPage({super.key});

  @override
  State<OtherPage> createState() => _OtherPageState();
}

class _OtherPageState extends State<OtherPage> {
  static const _channel = MethodChannel('com.anyhack.app/ir');
  static const _filesChannel = MethodChannel('com.anyhack.app/files');
  static const _prefsKey = 'ir_remotes_v1';

  List<IrRemote> _remotes = <IrRemote>[];
  bool? _irAvailable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Лечение: если в прошлой сессии процесс был root (KSU API), файлы
    // SharedPreferences могли стать root-owned — возвращаем владельца приложения.
    try {
      await RootShell.instance.run(
        'D=$(stat -c %u:%g /data/data/com.anyhack.app 2>/dev/null); '
        '[ -n "\$D" ] && chown -R "\$D" /data/data/com.anyhack.app/shared_prefs '
        '2>/dev/null; true',
        forceSu: true,
        timeout: const Duration(seconds: 4),
      );
    } catch (_) {}

    var list = <IrRemote>[];
    bool? ir;
    try {
      final prefs =
          await SharedPreferences.getInstance().timeout(const Duration(seconds: 3));
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw) as List<dynamic>;
          list = decoded
              .map((e) => IrRemote.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {
          // битые данные — начинаем с пустого списка
        }
      }
    } catch (_) {
      // prefs недоступны — работаем без сохранённых пультов
    }
    try {
      ir = await _channel
          .invokeMethod<bool>('hasIrEmitter')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      ir = null;
    }
    if (!mounted) return;
    setState(() {
      _remotes = list;
      _irAvailable = ir;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs
        .setString(
          _prefsKey,
          jsonEncode(_remotes.map((r) => r.toJson()).toList()),
        )
        .timeout(const Duration(seconds: 4));
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: ok ? scheme.primaryContainer : scheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _import() async {
    HapticFeedback.lightImpact();

    // Собственный SAF-пикер из MainActivity — без сторонних плагинов.
    final List<dynamic> picked;
    try {
      final r = await _filesChannel.invokeMethod<List<dynamic>>('pickIr');
      picked = r ?? const <dynamic>[];
    } catch (_) {
      _snack('Не удалось открыть выбор файлов');
      return;
    }
    if (picked.isEmpty) return; // отмена

    var added = 0;
    var failed = 0;
    var notIr = 0;
    for (final item in picked) {
      try {
        final m = Map<String, dynamic>.from(item as Map);
        final name = m['name'] as String? ?? '';
        if (!name.toLowerCase().endsWith('.ir')) {
          notIr++;
          continue;
        }
        final bytes = await _filesChannel
            .invokeMethod<Uint8List>('readIr', {'uri': m['uri']})
            .timeout(const Duration(seconds: 3));
        if (bytes == null) {
          failed++;
          continue;
        }
        final base =
            name.replaceAll(RegExp(r'\.ir$', caseSensitive: false), '');
        final remote =
            parseIrFile(utf8.decode(bytes, allowMalformed: true), base);
        if (remote == null) {
          failed++;
          continue;
        }
        _remotes.removeWhere((r2) => r2.name == remote.name);
        _remotes.add(remote);
        added++;
      } catch (_) {
        failed++;
      }
    }
    try {
      await _save();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    if (added > 0) {
      _snack(
        failed > 0
            ? 'Импортировано: $added, ошибок: $failed'
            : 'Импортировано пультов: $added',
        ok: true,
      );
    } else if (notIr == picked.length) {
      _snack('Можно выбирать только файлы .ir (Flipper Zero)');
    } else {
      _snack('В файле не найдено сигналов .ir');
    }
  }

  Future<void> _removeRemote(IrRemote remote) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить «${remote.name}»?'),
        content: Text('Кнопок: ${remote.buttons.length}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _remotes.removeWhere((r) => r.name == remote.name);
    try {
      await _save();
    } catch (_) {}
    if (mounted) setState(() {});
    _snack('Пульт удалён', ok: true);
  }

  Future<void> _send(IrButton b) async {
    HapticFeedback.lightImpact();

    int frequency;
    List<int> pattern;
    if (b.isRaw) {
      frequency = b.frequency;
      pattern = b.data;
    } else {
      final enc = encodeParsed(b.protocol!, b.address!, b.command!);
      if (enc == null) {
        _snack('Протокол ${b.protocol} не поддерживается');
        return;
      }
      frequency = enc.frequency;
      pattern = enc.pattern;
    }
    if (pattern.length < 2) {
      _snack('Пустой сигнал');
      return;
    }

    try {
      await _channel
          .invokeMethod('transmit', {
            'frequency': frequency,
            'pattern': pattern,
          })
          .timeout(const Duration(seconds: 2));
    } on PlatformException catch (e) {
      _snack('ИК-ошибка: ${e.message ?? e.code}');
    } catch (e) {
      _snack('ИК-ошибка: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_irAvailable == false)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline),
                    SizedBox(width: 10),
                    Expanded(child: Text('На устройстве нет ИК-излучателя')),
                  ],
                ),
              ),
            ),
          ),
        if (_remotes.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_remote,
                        size: 72,
                        color: Theme.of(context).colorScheme.outline),
                    const SizedBox(height: 16),
                    const Text(
                      'Импортируйте .ir-файлы Flipper Zero,\nчтобы собрать ИК-пульт',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.file_download),
                      label: const Text('Импорт .ir'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: _remotes.length,
              itemBuilder: (context, i) => _remoteCard(context, _remotes[i]),
            ),
          ),
      ],
    );
  }

  Widget _remoteCard(BuildContext context, IrRemote remote) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tv, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(remote.name,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text('${remote.buttons.length}',
                    style: Theme.of(context).textTheme.labelMedium),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) {
                    if (v == 'delete') _removeRemote(remote);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Удалить пульт')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in remote.buttons)
                  FilledButton.tonal(
                    onPressed: () => _send(b),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.name,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          b.isRaw
                              ? 'raw · ${b.frequency ~/ 1000} кГц'
                              : '${b.protocol} · A:${_hex4(b.address!)} C:${_hex4(b.command!)}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _hex4(int v) =>
    v.toRadixString(16).padLeft(4, '0').toUpperCase();
