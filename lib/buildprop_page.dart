import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'root_shell.dart';

class BuildPropPage extends StatefulWidget {
  const BuildPropPage({super.key});

  @override
  State<BuildPropPage> createState() => _BuildPropPageState();
}

class _BuildPropPageState extends State<BuildPropPage> {
  List<String> _lines = <String>[];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final out = await RootShell.instance.run(
      'cat /system/build.prop',
      forceSu: true,
      expectOutput: true,
      timeout: const Duration(seconds: 8),
    );
    final lines = out
        .split('\n')
        .map((e) => e.trimRight())
        .where((e) => e.isNotEmpty)
        .toList();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (lines.isEmpty) {
        _error = 'не удалось прочитать /system/build.prop';
      } else {
        _lines = lines;
      }
    });
  }

  List<String> get _filtered {
    if (_query.isEmpty) return _lines;
    final q = _query.toLowerCase();
    return _lines.where((l) => l.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('build.prop'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'поиск: ro.build.version…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _query = ''),
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'копировать всё',
            onPressed: _lines.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                        ClipboardData(text: _lines.join('\n')));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(
                        content: Text('скопировано'),
                        behavior: SnackBarBehavior.floating,
                      ));
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'обновить',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 56, color: scheme.error),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 12, endIndent: 12),
                  itemBuilder: (context, i) {
                    final line = items[i];
                    final eq = line.indexOf('=');
                    if (eq <= 0) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Text(line,
                            style: TextStyle(color: scheme.outline)),
                      );
                    }
                    final key = line.substring(0, eq);
                    final value = line.substring(eq + 1);
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(key,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(value, style: const TextStyle(fontSize: 14)),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
