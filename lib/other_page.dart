import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ir_parser.dart';
import 'root_shell.dart';

class OtherPage extends StatefulWidget {
  const OtherPage({super.key});

  /// Кнопка «+» в AppBar (main.dart) дёргает этот колбэк.
  static VoidCallback? importAction;

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
    OtherPage.importAction = _import;
    _load();
  }

  @override
  void dispose() {
    if (OtherPage.importAction == _import) OtherPage.importAction = null;
    super.dispose();
  }

  Future<void> _load() async {
    // Лечение: если в прошлой сессии процесс был root (KSU API), файлы
    // SharedPreferences могли стать root-owned — возвращаем владельца приложения.
    try {
      await RootShell.instance.run(
        'D=\$(stat -c %u:%g /data/data/com.anyhack.app 2>/dev/null); '
        '[ -n "\$D" ] && chown -R "\$D" /data/data/com.anyhack.app/shared_prefs '
        '2>/dev/null; true',
        forceSu: true,
        timeout: const Duration(seconds: 4),
      );
    } catch (_) {}

    var list = <IrRemote>[];
    bool? ir;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 3));
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
    IrRemote? firstAdded;
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
        firstAdded ??= remote;
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
      // Сразу открываем управление первого добавленного пульта.
      if (firstAdded != null) _openRemote(firstAdded);
    } else if (notIr == picked.length) {
      _snack('Можно выбирать только файлы .ir (Flipper Zero)');
    } else {
      _snack('В файле не найдено сигналов .ir');
    }
  }

  void _openRemote(IrRemote remote) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RemoteControlPage(
        remote: remote,
        onSend: _send,
        onDeleteRequest: () => _removeRemote(remote),
      ),
    ));
  }

  Future<bool> _removeRemote(IrRemote remote) async {
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
    if (confirmed != true) return false;
    _remotes.removeWhere((r) => r.name == remote.name);
    try {
      await _save();
    } catch (_) {}
    if (mounted) setState(() {});
    _snack('Пульт удалён', ok: true);
    return true;
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
    final scheme = Theme.of(context).colorScheme;

    if (_remotes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings_remote, size: 72, color: scheme.outline),
              const SizedBox(height: 16),
              const Text(
                'Нет пультов. Нажмите «+» сверху\nили импортируйте .ir-файлы Flipper Zero',
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
      );
    }

    return Column(
      children: [
        if (_irAvailable == false)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Card(
              color: scheme.errorContainer,
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
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1,
            ),
            itemCount: _remotes.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _addTile(context);
              return _remoteTile(context, _remotes[i - 1]);
            },
          ),
        ),
      ],
    );
  }

  /// Квадратная плитка «+» — импорт нового пульта.
  Widget _addTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _import,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 44, color: scheme.primary),
            const SizedBox(height: 8),
            Text('Добавить', style: Theme.of(context).textTheme.titleMedium),
            Text('.ir-файл', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  /// Квадратная плитка пульта: тап — управление, долгое нажатие — удаление.
  Widget _remoteTile(BuildContext context, IrRemote remote) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          HapticFeedback.lightImpact();
          _openRemote(remote);
        },
        onLongPress: () => _removeRemote(remote),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.settings_remote, size: 40, color: scheme.primary),
              const SizedBox(height: 10),
              Text(
                remote.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '${remote.buttons.length} кнопок',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Экран управления пульта: сетка его команд.
class RemoteControlPage extends StatelessWidget {
  const RemoteControlPage({
    super.key,
    required this.remote,
    required this.onSend,
    required this.onDeleteRequest,
  });

  final IrRemote remote;
  final Future<void> Function(IrButton) onSend;
  final Future<bool> Function() onDeleteRequest;

  Future<void> _confirmDelete(BuildContext context) async {
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
    final ok = await onDeleteRequest();
    if (ok && context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(remote.name),
        actions: [
          IconButton(
            tooltip: 'Удалить пульт',
            onPressed: () => _confirmDelete(context),
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: remote.buttons.isEmpty
          ? Center(
              child: Text('В пульте нет кнопок',
                  style: Theme.of(context).textTheme.bodyLarge),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in remote.buttons)
                    FilledButton.tonal(
                      onPressed: () => onSend(b),
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
            ),
    );
  }
}

String _hex4(int v) =>
    v.toRadixString(16).padLeft(4, '0').toUpperCase();
