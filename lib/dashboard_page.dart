import 'dart:async';

import 'package:flutter/material.dart';

import 'root_shell.dart';

/// Один root-запрос со всеми метриками (опрос раз в 1.5 с).
const String _sampleScript = r'''
cat /proc/stat | head -1
echo @FREQ
for i in 0 1 2 3 4 5 6 7; do f=/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq; if [ -r "$f" ]; then echo "$i $(cat "$f")"; else echo "$i -"; fi; done
echo @GOV
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
echo @GPU
cat /sys/class/devfreq/13000000.mali/cur_freq 2>/dev/null
cat /sys/kernel/ged/hal/gpu_utilization 2>/dev/null
echo @MEM
cat /proc/meminfo
echo @DF
df -k /data
echo @TEMP
for z in /sys/class/thermal/thermal_zone*; do t=$(cat "$z/type" 2>/dev/null); v=$(cat "$z/temp" 2>/dev/null); echo "$t $v"; done
''';

class HwSnapshot {
  const HwSnapshot({
    required this.cpuLine,
    required this.coreFreqs,
    required this.governor,
    required this.gpuFreqHz,
    required this.gpuLoad,
    required this.memTotalKb,
    required this.memAvailKb,
    required this.diskTotalKb,
    required this.diskUsedKb,
    required this.temps,
  });

  final String cpuLine;
  final Map<int, int> coreFreqs; // ядро -> кГц
  final String governor;
  final int? gpuFreqHz;
  final int? gpuLoad; // %
  final int memTotalKb;
  final int memAvailKb;
  final int? diskTotalKb;
  final int? diskUsedKb;
  final Map<String, int> temps; // тип -> м°C (только правдоподобные)

  bool get hasData => cpuLine.isNotEmpty || coreFreqs.isNotEmpty;

  static HwSnapshot parse(String out) {
    final sections = <String, List<String>>{'HEAD': <String>[]};
    var cur = 'HEAD';
    for (final raw in out.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('@')) {
        cur = line.substring(1).trim();
        sections.putIfAbsent(cur, () => <String>[]);
      } else {
        (sections[cur] ??= <String>[]).add(line);
      }
    }

    List<String> sec(String name) => (sections[name] ?? const <String>[])
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final cpuLines = sec('HEAD').where((l) => l.startsWith('cpu ')).toList();
    final cpuLine = cpuLines.isEmpty ? '' : cpuLines.first;

    final coreFreqs = <int, int>{};
    for (final l in sec('FREQ')) {
      final p = l.split(RegExp(r'\s+'));
      if (p.length < 2) continue;
      final idx = int.tryParse(p[0]);
      final khz = int.tryParse(p[1]);
      if (idx != null && khz != null && khz > 0) coreFreqs[idx] = khz;
    }

    final gov = sec('GOV').isNotEmpty ? sec('GOV').first : '';

    int? gpuFreq;
    int? gpuLoad;
    final gpuLines = sec('GPU');
    if (gpuLines.isNotEmpty) gpuFreq = int.tryParse(gpuLines[0]);
    if (gpuLines.length > 1) {
      final nums = RegExp(r'\d+')
          .allMatches(gpuLines[1])
          .map((m) => int.parse(m.group(0)!))
          .toList();
      if (nums.isNotEmpty && nums.first <= 100) gpuLoad = nums.first;
    }

    var memTotal = 0;
    var memAvail = 0;
    for (final l in sec('MEM')) {
      final m = RegExp(r'^(MemTotal|MemAvailable):\s*(\d+)')
          .firstMatch(l);
      if (m == null) continue;
      if (m.group(1) == 'MemTotal') {
        memTotal = int.parse(m.group(2)!);
      } else {
        memAvail = int.parse(m.group(2)!);
      }
    }

    int? diskTotal;
    int? diskUsed;
    for (final l in sec('DF')) {
      final t = l.split(RegExp(r'\s+'));
      if (t.length < 6 || t[0] == 'Filesystem') continue;
      final total = int.tryParse(t[1]);
      final used = int.tryParse(t[2]);
      if (total == null || used == null) continue;
      diskTotal = total;
      diskUsed = used;
      break;
    }

    final temps = <String, int>{};
    for (final l in sec('TEMP')) {
      final t = l.split(RegExp(r'\s+'));
      if (t.length < 2) continue;
      final v = int.tryParse(t.last);
      // отсев мусора вида -274000 / 4000
      if (v == null || v < 10000 || v > 125000) continue;
      temps[t.first] = v;
    }

    return HwSnapshot(
      cpuLine: cpuLine,
      coreFreqs: coreFreqs,
      governor: gov,
      gpuFreqHz: gpuFreq,
      gpuLoad: gpuLoad,
      memTotalKb: memTotal,
      memAvailKb: memAvail,
      diskTotalKb: diskTotal,
      diskUsedKb: diskUsed,
      temps: temps,
    );
  }

  /// (total, idle) из строки "cpu user nice system idle iowait irq softirq steal".
  static (int, int)? cpuTotals(String line) {
    final p = line.split(RegExp(r'\s+'));
    if (p.length < 9) return null;
    final n = <int>[];
    for (var i = 1; i <= 8; i++) {
      n.add(int.tryParse(p[i]) ?? 0);
    }
    final total = n.fold<int>(0, (a, b) => a + b);
    final idle = n[3] + n[4];
    return (total, idle);
  }
}

String _fmtSize(int kb) {
  final gb = kb / 1048576;
  if (gb >= 1) return '${gb.toStringAsFixed(1)} ГБ';
  return '${(kb / 1024).round()} МБ';
}

String _fmtFreq(int khz) {
  final mhz = khz / 1000;
  if (mhz >= 1000) return '${(mhz / 1000).toStringAsFixed(2)} ГГц';
  return '${mhz.round()} МГц';
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Timer? _timer;
  bool _busy = false;
  String? _lastRaw;
  HwSnapshot? _snap;
  double? _cpuLoad;
  (int, int)? _prevTotals;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final out = await RootShell.instance.run(_sampleScript);
      if (!mounted) return;
      final snap = HwSnapshot.parse(out);
      final totals = HwSnapshot.cpuTotals(snap.cpuLine);
      if (totals != null) {
        final prev = _prevTotals;
        if (prev != null) {
          final dt = totals.$1 - prev.$1;
          final di = totals.$2 - prev.$2;
          if (dt > 0) {
            _cpuLoad = (((dt - di) / dt) * 100).clamp(0.0, 100.0);
          }
        }
        _prevTotals = totals;
      }
      setState(() {
        _lastRaw = out;
        _snap = snap;
      });
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap;
    final rootPending = _lastRaw == null || (_lastRaw!.isEmpty && snap == null);

    if (snap == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(rootPending ? 'Запрос root-доступа в KernelSU…' : 'Чтение данных…'),
          ],
        ),
      );
    }

    final rootLost = _lastRaw != null && _lastRaw!.isEmpty;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (rootLost)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.block, color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Нет данных: подтвердите root-доступ в KernelSU'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _cpuCard(context, snap),
        _gpuCard(context, snap),
        _ramCard(context, snap),
        _diskCard(context, snap),
        _tempCard(context, snap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Опрос каждые 1.5 с через фоновую root-сессию su · /proc, sysfs, df',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, String title, Widget child, {Widget? trailing}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _cpuCard(BuildContext context, HwSnapshot snap) {
    final load = _cpuLoad ?? 0;
    final cores = snap.coreFreqs;
    final little = <int>[];
    final medium = <int>[];
    final big = <int>[];
    for (final e in cores.entries) {
      if (e.key < 4) {
        little.add(e.value);
      } else if (e.key < 7) {
        medium.add(e.value);
      } else {
        big.add(e.value);
      }
    }

    String avgF(List<int> l) =>
        l.isEmpty ? '—' : _fmtFreq(l.reduce((a, b) => a + b) ~/ l.length);

    return _card(
      context,
      'CPU',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${load.toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(width: 10),
              if (snap.governor.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Chip(
                    label: Text(snap.governor, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: load / 100,
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < 8; i++)
                _coreChip(context, i, cores[i]),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Little ×4 ${avgF(little)}  ·  Medium ×3 ${avgF(medium)}  ·  Big ${avgF(big)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _coreChip(BuildContext context, int idx, int? khz) {
    final color = idx < 4
        ? Colors.green
        : idx < 7
            ? Colors.orange
            : Colors.red;
    final bg = color.withValues(alpha: 0.14);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$idx · ${khz == null ? '—' : _fmtFreq(khz)}',
        style: const TextStyle(fontSize: 11),
      ),
    );
  }

  Widget _gpuCard(BuildContext context, HwSnapshot snap) {
    final freq = snap.gpuFreqHz;
    final load = snap.gpuLoad;
    return _card(
      context,
      'GPU Mali-G615',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                freq == null ? '—' : '${(freq / 1e6).round()} МГц',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(width: 12),
              Text(
                load == null ? '' : 'Нагрузка $load%',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: load == null ? null : (load / 100).clamp(0.0, 1.0),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '/sys/class/devfreq/13000000.mali · /sys/kernel/ged/hal/gpu_utilization',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _ramCard(BuildContext context, HwSnapshot snap) {
    final total = snap.memTotalKb;
    final avail = snap.memAvailKb;
    final used = total > 0 ? total - avail : 0;
    final ratio = total > 0 ? used / total : 0.0;
    return _card(
      context,
      'ОЗУ',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_fmtSize(used)} / ${_fmtSize(total)}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Text('${(ratio * 100).toStringAsFixed(0)}%'),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text('Доступно: ${_fmtSize(avail)}', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _diskCard(BuildContext context, HwSnapshot snap) {
    final total = snap.diskTotalKb;
    final used = snap.diskUsedKb;
    if (total == null || used == null) {
      return _card(context, 'Диск /data', const Text('Нет данных'));
    }
    final ratio = total > 0 ? used / total : 0.0;
    return _card(
      context,
      'Диск /data',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_fmtSize(used)} / ${_fmtSize(total)}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Text('${(ratio * 100).toStringAsFixed(0)}%'),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text('Свободно: ${_fmtSize(total - used)}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _tempCard(BuildContext context, HwSnapshot snap) {
    final temps = snap.temps;
    int? cpuMax;
    int? gpu;
    int? battery;
    int? skin;
    for (final e in temps.entries) {
      final k = e.key;
      if (k.startsWith('cpu-') || k.startsWith('cpu_')) {
        if (cpuMax == null || e.value > cpuMax) cpuMax = e.value;
      } else if (k.startsWith('gpu')) {
        if (gpu == null || e.value > gpu) gpu = e.value;
      } else if (k == 'battery') {
        battery = e.value;
      } else if (k == 'quiet_therm' || k == 'ScreenPmic_therm') {
        skin ??= e.value;
      }
    }

    Widget chip(String label, int? milliC) => Chip(
          avatar: Icon(
            Icons.thermostat,
            size: 16,
            color: milliC == null
                ? null
                : milliC > 60000
                    ? Colors.red
                    : milliC > 45000
                        ? Colors.orange
                        : Colors.green,
          ),
          label: Text(
            milliC == null ? '$label: —' : '$label: ${(milliC / 1000).toStringAsFixed(1)}°C',
            style: const TextStyle(fontSize: 12),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );

    return _card(
      context,
      'Температуры',
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip('CPU', cpuMax),
          chip('GPU', gpu),
          chip('Батарея', battery),
          chip('Кожа', skin),
        ],
      ),
    );
  }
}
