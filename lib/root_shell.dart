import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

class RootShell {
  RootShell._();

  static final RootShell instance = RootShell._();

  bool? _selfRooted;
  bool _acqInFlight = false;
  bool _acqFailed = false;
  DateTime _lastAcq = DateTime.fromMillisecondsSinceEpoch(0);

  bool get usingSh => _selfRooted == true;

  // принудительный переход на su, например если api-путь ненадёжен
  void demote() {
    _selfRooted = false;
    _acqFailed = true;
    _lastAcq = DateTime.now();
  }

  Future<String> run(
    String cmd, {
    Duration timeout = const Duration(seconds: 6),
    bool expectOutput = false,
    bool forceSu = false,
  }) async {
    // ждём api-захват до 2 с, дальше работаем через sh без su
    if (!forceSu) await _ensureAcquired(const Duration(seconds: 2));

    if (!forceSu && _selfRooted == true) {
      final out = await _exec('/system/bin/sh', ['-c', cmd], timeout);
      if (out.isNotEmpty || !expectOutput) return out;
    }

    var out = await _exec('su', ['-c', cmd], timeout);
    if (out.isEmpty && expectOutput) {
      out = await _exec('su', ['-c', cmd], timeout);
    }
    return out;
  }

  // причина последней неудачной проверки, показывается на старте
  String? lastProbeNote;

  // проверка для стартового экрана: api и su идут параллельно,
  // выигрывает первый положительный ответ
  Future<bool> probeRoot() async {
    final done = Completer<bool>();

    final api = Isolate.run(_tryBecomeRootApi)
        .timeout(const Duration(seconds: 3), onTimeout: () => false)
        .catchError((_) => false);
    final su = _probeSu().catchError((_) => false);
    api.then((v) {
      if (v && !done.isCompleted) {
        lastProbeNote = null;
        done.complete(true);
      }
    });
    su.then((v) {
      if (v && !done.isCompleted) {
        lastProbeNote = null;
        done.complete(true);
      }
    });

    bool ok;
    try {
      ok = await done.future.timeout(const Duration(seconds: 22),
          onTimeout: () => false);
    } catch (_) {
      ok = false;
    }
    if (ok) {
      lastProbeNote = null;
      return true;
    }
    lastProbeNote ??= 'проверка прервана, нажмите повторить';
    return false;
  }

  Future<bool> _probeSu() async {
    const timeout = Duration(seconds: 20);
    try {
      final p = await Process.start('/system/bin/su', ['-c', 'id -u']);
      final res = await Future.wait<Object>([
        p.stdout.transform(utf8.decoder).join(),
        p.stderr.transform(utf8.decoder).join(),
        p.exitCode,
      ]).timeout(timeout);
      final out = res[0] as String;
      final err = res[1] as String;
      final code = res[2] as int;
      final ok = out
          .split('\n')
          .any((l) => l.trim() == '0' || l.trim() == 'root');
      if (ok) {
        lastProbeNote = null;
        return true;
      }
      if (err.trim().isNotEmpty) {
        lastProbeNote = err.trim().split('\n').last;
      } else if (out.trim().isNotEmpty) {
        lastProbeNote = out.trim();
      } else {
        lastProbeNote = 'su завершился с кодом $code без вывода';
      }
      return false;
    } on TimeoutException {
      lastProbeNote = 'таймаут 20 с: подтвердите запрос kernelsu';
      return false;
    } catch (_) {
      lastProbeNote = 'не удалось запустить su';
      return false;
    }
  }

  Future<String> _exec(
    String bin,
    List<String> args,
    Duration timeout,
  ) async {
    try {
      final r = await Process.run(bin, args, runInShell: false)
          .timeout(timeout);
      return r.stdout?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void>? _acqFuture;

  void _kickAcquire() {
    if (_selfRooted == true || _acqInFlight) return;
    final now = DateTime.now();
    if (_acqFailed && now.difference(_lastAcq).inSeconds < 15) return;
    _acqInFlight = true;
    _lastAcq = now;
    _acqFuture = _acquire();
  }

  // ждёт текущую попытку api-захвата не дольше budget
  Future<void> _ensureAcquired(Duration budget) async {
    if (_selfRooted == true) return;
    _kickAcquire();
    final f = _acqFuture;
    if (f == null) return;
    try {
      await f.timeout(budget);
    } catch (_) {}
  }

  Future<void> _acquire() async {
    try {
      final ok = await Isolate.run(_tryBecomeRootApi)
          .timeout(const Duration(seconds: 4));
      _selfRooted = ok;
      _acqFailed = !ok;
    } catch (_) {
      _acqFailed = true;
    } finally {
      _acqInFlight = false;
    }
  }
}

typedef _PrctlNative = Int32 Function(Int32, Int32, IntPtr, IntPtr, IntPtr);
typedef _PrctlDart = int Function(int, int, int, int, int);

Future<bool> _tryBecomeRootApi() async {
  if (await _probeRoot()) return true;

  // классический kernelSU api: prctl(0xDEADBEEF, cmd_grant_root)
  try {
    final prctl = DynamicLibrary.process()
        .lookupFunction<_PrctlNative, _PrctlDart>('prctl');
    prctl(0xDEADBEEF, 0, 0, 0, 0);
    if (await _probeRoot()) return true;
  } catch (_) {}

  return false;
}

// строгий пробник: uid0 + доступ к gpu файлу (только root) + системные данные.
// без gpu-файла sh путь даёт частичные данные без root, этого нельзя допускать
Future<bool> _probeRoot() async {
  try {
    final r = await Process.run(
      '/system/bin/sh',
      [
        '-c',
        'id -u; '
            'cat /sys/class/devfreq/13000000.mali/cur_freq 2>/dev/null; '
            '[ -r /data/system/packages.xml ] && echo OK',
      ],
      runInShell: false,
    ).timeout(const Duration(seconds: 3));
    final lines = r.stdout
        ?.toString()
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines == null || lines.isEmpty) return false;
    final uidOk = lines.first == '0';
    final gpuOk = lines.any((l) => RegExp(r'^\d{6,}$').hasMatch(l));
    final selinuxOk = lines.contains('OK');
    return uidOk && gpuOk && selinuxOk;
  } catch (_) {
    return false;
  }
}
