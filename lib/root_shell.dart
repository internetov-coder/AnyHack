import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class RootShell {
  RootShell._();

  static final RootShell instance = RootShell._();

  static const int _kInstallMagic1 = 0xDEADBEEF;
  static const int _kInstallMagic2 = 0xCAFEBABE;
  static const int _kIoctlGrantRoot = 0x4B01;
  static const int _rebootCmdInvalid = 0x13572468;

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
    if (!forceSu) _kickAcquire();

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

  // быстрая проверка root через su, для стартового экрана
  Future<bool> probeSu({Duration timeout = const Duration(seconds: 12)}) async {
    final out = await _exec('su', ['-c', 'id -u'], timeout);
    return out.split('\n').any((l) => l.trim() == '0');
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

  // классический kernelSU api: prctl(0xDEADBEEF, cmd_grant_root)
  try {
    final prctl = DynamicLibrary.process()
        .lookupFunction<_PrctlNative, _PrctlDart>('prctl');
    prctl(0xDEADBEEF, 0, 0, 0, 0);
    if (await _probeRoot()) return true;
  } catch (_) {}

  // новый supercall kernelSU: reboot с магией ставит fd, ioctl выдаёт root.
  // неверные магии дают лишь -EINVAL, ребута не происходит
  try {
    _ksuSuperCallGrantRoot();
    if (await _probeRoot()) return true;
  } catch (_) {}

  return false;
}

void _ksuSuperCallGrantRoot() {
  final lib = DynamicLibrary.process();
  final syscall = lib.lookupFunction<_SyscallNative, _SyscallDart>('syscall');
  final ioctl = lib.lookupFunction<_IoctlNative, _IoctlDart>('ioctl');
  final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');

  final out = calloc<Int32>();
  try {
    out.value = -1;
    syscall(142, 0xDEADBEEF, 0xCAFEBABE, _rebootCmdInvalid, out.address);
    final fd = out.value;
    if (fd >= 0) {
      try {
        ioctl(fd, _kIoctlGrantRoot, 0);
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
