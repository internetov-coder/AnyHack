import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Корневой доступ AnyHack — три стратегии (в порядке приоритета):
///
/// 1. **KernelSU API, классический** — `prctl(0xDEADBEEF, CMD_GRANT_ROOT)`.
/// 2. **KernelSU / KernelSU Next supercall** — fd устанавливается kprobe'ом
///    на `reboot(0xDEADBEEF, 0xCAFEBABE, …)`, затем
///    `ioctl(fd, KSU_IOCTL_GRANT_ROOT = 0x4B01)` — процесс приложения
///    сам получает root (uid + root SELinux-профиль), после чего команды
///    выполняются обычным `/system/bin/sh` БЕЗ порождения `su` на каждый тик.
/// 3. **Fallback** — атомарный `su -c` с повтором (как раньше).
///
/// Попытки API выполняются в отдельном isolate с таймаутом, поэтому UI
/// никогда не зависает, даже если ядро «залипает» на запросе root.
class RootShell {
  RootShell._();

  static final RootShell instance = RootShell._();

  // ---- KernelSU constants (uapi/supercall.h) ----
  static const int _kSuOption = 0xDEADBEEF;
  static const int _kInstallMagic1 = 0xDEADBEEF;
  static const int _kInstallMagic2 = 0xCAFEBABE;
  static const int _kIoctlGrantRoot = 0x4B01; // _IOC(_IOC_NONE, 'K', 1, 0)
  static const int _sysRebootAarch64 = 142;
  static const int _rebootCmdInvalid = 0x13572468; // не LINUX_REBOOT_CMD_*

  bool? _selfRooted; // true → работаем через sh без su
  bool _acqInFlight = false;
  bool _acqFailed = false;
  DateTime _lastAcq = DateTime.fromMillisecondsSinceEpoch(0);

  /// Активен ли быстрый sh-путь (процесс получил root через KSU API).
  bool get usingSh => _selfRooted == true;

  /// Принудительно перейти на su (например, если API-путь ненадёжен).
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
    if (!forceSu) _kickAcquire();

    if (!forceSu && _selfRooted == true) {
      final out = await _exec('/system/bin/sh', ['-c', cmd], timeout);
      if (out.isNotEmpty || !expectOutput) return out;
      // Пустой вывод при ожидаемых данных — падаем на su для этого вызова.
    }

    var out = await _exec('su', ['-c', cmd], timeout);
    if (out.isEmpty && expectOutput) {
      out = await _exec('su', ['-c', cmd], timeout);
    }
    return out;
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

  /// Фоновая (не блокирующая) попытка получить root процессу через KSU API.
  void _kickAcquire() {
    if (_selfRooted == true || _acqInFlight) return;
    final now = DateTime.now();
    if (_acqFailed && now.difference(_lastAcq).inSeconds < 15) return;
    _acqInFlight = true;
    _lastAcq = now;
    _acquire();
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

// ---------------------------------------------------------------------------
// Выполняется в отдельном isolate.
// ---------------------------------------------------------------------------

typedef _PrctlNative = Int32 Function(Int32, Int32, IntPtr, IntPtr, IntPtr);
typedef _PrctlDart = int Function(int, int, int, int, int);

typedef _SyscallNative =
    IntPtr Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr);
typedef _SyscallDart = int Function(int, int, int, int, int);

typedef _IoctlNative = Int32 Function(Int32, IntPtr, IntPtr);
typedef _IoctlDart = int Function(int, int, int);

typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);

Future<bool> _tryBecomeRootApi() async {
  if (await _probeRoot()) return true;

  // 1) Классический KernelSU: prctl(0xDEADBEEF, CMD_GRANT_ROOT=0).
  try {
    final prctl = DynamicLibrary.process()
        .lookupFunction<_PrctlNative, _PrctlDart>('prctl');
    prctl(0xDEADBEEF, 0, 0, 0, 0);
    if (await _probeRoot()) return true;
  } catch (_) {}

  // 2) Новый KernelSU / KernelSU Next: supercall.
  try {
    _ksuSuperCallGrantRoot();
    if (await _probeRoot()) return true;
  } catch (_) {}

  return false;
}

/// reboot(142, 0xDEADBEEF, 0xCAFEBABE, мусорный cmd, &fd) — kprobe KSU
/// перехватывает магические аргументы и устанавливает fd [ksu_driver] в
/// текущий процесс; настоящий reboot не происходит (магические числа
/// не совпадают с LINUX_REBOOT_MAGIC_* → мгновенный -EINVAL).
/// Далее ioctl(fd, 0x4B01) = GRANT_ROOT → escape_with_root_profile().
void _ksuSuperCallGrantRoot() {
  final lib = DynamicLibrary.process();
  final syscall = lib.lookupFunction<_SyscallNative, _SyscallDart>('syscall');
  final ioctl = lib.lookupFunction<_IoctlNative, _IoctlDart>('ioctl');
  final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');

  final out = calloc<Int32>();
  try {
    out.value = -1;
    syscall(142, 0xDEADBEEF, 0xCAFEBABE, 0x13572468, out.address);
    final fd = out.value;
    if (fd >= 0) {
      try {
        ioctl(fd, 0x4B01, 0);
      } finally {
        try {
          close(fd);
        } catch (_) {}
      }
    }
  } finally {
    calloc.free(out);
  }
}

/// Строгая проверка root: uid == 0, ЧИТАЕТСЯ root-only sysfs (GPU-файл
/// на Xiaomi 14T недоступен без root) и системные данные (SELinux-домен).
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
