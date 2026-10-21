import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Постоянная root-сессия (`su`) с захватом вывода по маркеру.
///
/// Команды выполняются последовательно внутри одного интерактивного shell,
/// без перезапуска процесса на каждый запрос.
class RootShell {
  RootShell._();

  static final RootShell instance = RootShell._();

  Process? _proc;
  final List<String> _buf = <String>[];
  Completer<String>? _active;
  String _marker = '';
  Future<void> _tail = Future<void>.value();
  bool _starting = false;

  Future<void> _ensureStarted() async {
    if (_proc != null || _starting) return;
    _starting = true;
    try {
      final p = await Process.start('/system/bin/su');
      _proc = p;
      p.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      p.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      p.exitCode.then((_) {
        if (identical(_proc, p)) {
          _proc = null;
          final a = _active;
          _active = null;
          if (a != null && !a.isCompleted) {
            a.completeError(StateError('su exited'));
          }
        }
      });
    } finally {
      _starting = false;
    }
  }

  void _onLine(String line) {
    final a = _active;
    if (a == null) return;
    final idx = line.indexOf(_marker);
    if (idx >= 0) {
      final head = line.substring(0, idx);
      if (head.isNotEmpty) _buf.add(head);
      final out = _buf.join('\n');
      _buf.clear();
      _active = null;
      if (!a.isCompleted) a.complete(out);
    } else {
      _buf.add(line);
    }
  }

  /// Выполняет [cmd] в фоновой root-сессии.
  /// Возвращает stdout+stderr, либо пустую строку при ошибке/таймауте.
  Future<String> run(
    String cmd, {
    Duration timeout = const Duration(seconds: 6),
  }) {
    final next = _tail.then<String>((_) => _raw(cmd, timeout));
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<String> _raw(String cmd, Duration timeout) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _ensureStarted();
        final p = _proc;
        if (p == null) return '';
        _marker = '__AH_${DateTime.now().microsecondsSinceEpoch}__${attempt}_';
        _buf.clear();
        final c = Completer<String>();
        _active = c;
        p.stdin.writeln('{ $cmd ; } 2>&1; echo "$_marker:\$?"');
        try {
          return await c.future.timeout(timeout);
        } on TimeoutException {
          _active = null;
          _buf.clear();
          _kill();
        }
      } catch (_) {
        _active = null;
        _buf.clear();
        _kill();
        if (attempt == 1) return '';
      }
    }
    return '';
  }

  void _kill() {
    final p = _proc;
    _proc = null;
    p?.kill(ProcessSignal.sigkill);
  }
}
