import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'poll_config.dart';
import 'root_shell.dart';

// один su запрос на все метрики дашборда
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
echo @BAT
echo CAP=$(cat /sys/class/power/battery/capacity 2>/dev/null)
echo V=$(cat /sys/class/power/battery/voltage_now 2>/dev/null)
echo I=$(cat /sys/class/power/battery/current_now 2>/dev/null)
echo T=$(cat /sys/class/power/battery/temp 2>/dev/null)
echo S=$(cat /sys/class/power/battery/status 2>/dev/null)
echo @TEMP
for z in /sys/class/thermal/thermal_zone*; do t=$(cat "$z/type" 2>/dev/null); v=$(cat "$z/temp" 2>/dev/null); echo "$t $v"; done
''';

const String _freqInfoScript = r'''
for i in 0 4 7; do echo "$i MAX=$(cat /sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq 2>/dev/null) AV=$(cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_available_frequencies 2>/dev/null)"; done
''';

const String _freqReadbackScript =
    'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq '
    '/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq '
    '/sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2>/dev/null';

// доля от максимума кластера: little, medium, big
const Map<String, List<double>> _profileRatios = {
  'performance': [1.0, 1.0, 1.0],
  'balanced': [1.0, 0.85, 0.8],
  'economy': [0.85, 0.65, 0.55],
  'economy_plus': [0.7, 0.5, 0.4],
};

const List<({String id, String label})> _profiles = [
  (id: 'performance', label: 'Performance'),
  (id: 'balanced', label: 'Balanced'),
  (id: 'economy', label: 'Economy'),
  (id: 'economy_plus', label: 'Economy+'),
];

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
    required this.batCapacity,
    required this.batVoltageUv,
    required this.batCurrentUa,
    required this.batTemp,
    required this.batStatus,
    required this.temps,
  });

  final String cpuLine;
  final Map<int, int> coreFreqs;
  final String governor;
  final int? gpuFreqHz;
  final int? gpuLoad;
  final int memTotalKb;
  final int memAvailKb;
  final int? diskTotalKb;
  final int? diskUsedKb;
  final int? batCapacity;
  final int? batVoltageUv;
  final int? batCurrentUa;
  final int? batTemp;
  final String? batStatus;
  final Map<String, int> temps;

  static const HwSnapshot empty = HwSnapshot(
    cpuLine: '',
    coreFreqs: <int, int>{},
    governor: '',
    gpuFreqHz: null,
    gpuLoad: null,
    memTotalKb: 0,
    memAvailKb: 0,
    diskTotalKb: null,
    diskUsedKb: null,
    batCapacity: null,
    batVoltageUv: null,
    batCurrentUa: null,
    batTemp: null,
    batStatus: null,
    temps: <String, int>{},
  );

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
    var cpuLine = cpuLines.isEmpty ? '' : cpuLines.first;
    if (cpuLine.isEmpty) {
      for (final lines in sections.values) {
        for (final l in lines) {
          if (l.trimLeft().startsWith('cpu ')) {
            cpuLine = l.trim();
            break;
          }
        }
        if (cpuLine.isNotEmpty) break;
      }
    }

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
      final m = RegExp(r'^(MemTotal|MemAvailable):\s*(\d+)').firstMatch(l);
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

    int? batCap;
    int? batV;
    int? batI;
    int? batT;
    String? batS;
    for (final l in sec('BAT')) {
      final i = l.indexOf('=');
      if (i <= 0) continue;
      final v = l.substring(i + 1).trim();
      switch (l.substring(0, i)) {
        case 'CAP':
          batCap = int.tryParse(v);
        case 'V':
          batV = int.tryParse(v);
        case 'I':
          batI = int.tryParse(v);
        case 'T':
          batT = int.tryParse(v);
        case 'S':
          if (v.isNotEmpty) batS = v;
      }
    }

    final temps = <String, int>{};
    for (final l in sec('TEMP')) {
      final t = l.split(RegExp(r'\s+'));
      if (t.length < 2) continue;
      final v = int.tryParse(t.last);
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
      batCapacity: batCap,
      batVoltageUv: batV,
      batCurrentUa: batI,
      batTemp: batT,
      batStatus: batS,
      temps: temps,
    );
  }

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

String _fmtW(double w) => '${w.toStringAsFixed(w < 10 ? 2 : 1)} Вт';

String _fmtTempDeci(int t) => '${(t / 10).toStringAsFixed(1)}°C';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;
  bool _resumed = true;
  int _emptyStreak = 0;
  HwSnapshot? _snap;
  double? _cpuLoad;
  (int, int)? _prevTotals;

  String? _profile;
  bool _profileBusy = false;
  String? _profileStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
    _startTimer();
    PollConfig.intervalMs.addListener(_onIntervalChanged);
    _tick();
    _restoreProfile();
  }

  void _onIntervalChanged() => _startTimer();

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: PollConfig.intervalMs.value),
      (_) => _tick(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final was = _resumed;
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed && !was) {
      _emptyStreak = 0;
      _startTimer();
      _tick();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PollConfig.intervalMs.removeListener(_onIntervalChanged);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _restoreProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('cpu_profile');
      if (id == null || !_profileRatios.containsKey(id)) return;
      if (!mounted) return;
      setState(() => _profile = id);
      await _applyProfile(id, silent: true);
    } catch (_) {}
  }

  int _targetFreq(List<int> avail, int max, double ratio) {
    final t = (max * ratio).round();
    if (avail.isEmpty) return (t ~/ 100000) * 100000;
    final sorted = [...avail]..sort();
    var best = sorted.first;
    for (final f in sorted) {
      if (f <= t) best = f;
    }
    return best;
  }

  Future<void> _applyProfile(String id, {bool silent = false}) async {
    if (_profileBusy) return;
    final ratios = _profileRatios[id]!;
    setState(() {
      _profileBusy = true;
      _profileStatus = null;
    });
    if (!silent) HapticFeedback.selectionClick();

    String? status;
    try {
      final info = await RootShell.instance
          .run(_freqInfoScript, expectOutput: true);
      final maxes = <int, int>{};
      final avails = <int, List<int>>{};
      for (final line in info.split('\n')) {
        final m =
            RegExp(r'^(\d+) MAX=(\d+) AV=(.*)$').firstMatch(line.trim());
        if (m == null) continue;
        final core = int.parse(m.group(1)!);
        maxes[core] = int.parse(m.group(2)!);
        avails[core] = (m.group(3) ?? '')
            .split(RegExp(r'\s+'))
            .map(int.tryParse)
            .whereType<int>()
            .toList();
      }

      if (maxes.length < 3) {
        status = 'не удалось прочитать частоты ядер';
      } else {
        const reps = [0, 4, 7];
        final targets = <int, int>{};
        for (var c = 0; c < 3; c++) {
          final rep = reps[c];
          targets[rep] =
              _targetFreq(avails[rep] ?? const [], maxes[rep]!, ratios[c]);
        }
        final parts = <String>[];
        for (var i = 0; i < 8; i++) {
          final c = i < 4 ? 0 : (i < 7 ? 1 : 2);
          parts.add('echo ${targets[reps[c]]} > '
              '/sys/devices/system/cpu/cpu$i/cpufreq/scaling_max_freq');
        }
        await RootShell.instance.run(
          parts.join('; '),
          forceSu: true,
          timeout: const Duration(seconds: 8),
        );

        final rb = await RootShell.instance.run(
          _freqReadbackScript,
          forceSu: true,
          expectOutput: true,
        );
        final got = rb
            .split('\n')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .toList();
        final ok = got.length >= 3 &&
            got[0] == targets[0] &&
            got[1] == targets[4] &&
            got[2] == targets[7];
        if (ok) {
          status = 'применено · little ${_fmtGhz(got[0])} · '
              'medium ${_fmtGhz(got[1])} · big ${_fmtGhz(got[2])} ГГц';
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('cpu_profile', id);
          } catch (_) {}
          if (mounted) setState(() => _profile = id);
        } else {
          status = 'не применилось';
        }
      }
    } catch (_) {
      status = 'ошибка применения';
    } finally {
      if (mounted) {
        setState(() {
          _profileBusy = false;
          _profileStatus = status;
        });
      }
    }
  }

  String _fmtGhz(int khz) => (khz / 1000000).toString();

  Future<void> _tick() async {
    if (_busy || !_resumed) return;
    _busy = true;
    try {
      var out =
          await RootShell.instance.run(_sampleScript, expectOutput: true);
      if (!mounted || !_resumed) return;

      // gpu файл читается только с root, он же канарейка sh пути
      if (out.isNotEmpty &&
          RootShell.instance.usingSh &&
          HwSnapshot.parse(out).gpuFreqHz == null) {
        RootShell.instance.demote();
        out =
            await RootShell.instance.run(_sampleScript, expectOutput: true);
        if (!mounted || !_resumed) return;
      }

      if (out.isEmpty) {
        // при сбое не затираем последние валидные данные
        _emptyStreak++;
        setState(() {});
        return;
      }
      _emptyStreak = 0;

      final snap = HwSnapshot.parse(out);
      final totals = HwSnapshot.cpuTotals(snap.cpuLine);
      if (totals != null) {
        final prev = _prevTotals;
        if (prev != null) {
          final dt = totals.$1 - prev.$1;
          final di = totals.$2 - prev.$2;
          if (dt > 0) {
            _cpuLoad = (((dt - di) / dt) * 100).clamp(0.0, 100.0).toDouble();
          }
        }
        _prevTotals = totals;
      } else {
        _cpuLoad = null;
      }
      setState(() {
        _snap = snap;
      });
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap ?? HwSnapshot.empty;
    final rootLost = _emptyStreak >= 2;

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
                    Icon(Icons.block,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                          'Нет данных: подтвердите root-доступ в KernelSU'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _cpuCard(context, snap),
        _profileCard(context),
        _gpuCard(context, snap),
        _batCard(context, snap),
        _ramCard(context, snap),
        _diskCard(context, snap),
        _tempCard(context, snap),
      ],
    );
  }

  Widget _card(BuildContext context, String title, Widget child,
      {Widget? trailing}) {
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
    final load = _cpuLoad ?? 0.0;
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
                _cpuLoad == null ? '—' : '${_cpuLoad!.toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(width: 10),
              if (snap.governor.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Chip(
                    label:
                        Text(snap.governor, style: const TextStyle(fontSize: 11)),
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
              for (var i = 0; i < 8; i++) _coreChip(context, i, cores[i]),
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

  Widget _profileCard(BuildContext context) {
    return _card(
      context,
      'Профиль частот',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _profiles)
                ChoiceChip(
                  label: Text(p.label),
                  selected: _profile == p.id,
                  onSelected:
                      _profileBusy ? null : (_) => _applyProfile(p.id),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_profileBusy)
            Text('применяется…',
                style: Theme.of(context).textTheme.bodySmall)
          else if (_profileStatus != null)
            Text(_profileStatus!,
                style: Theme.of(context).textTheme.bodySmall),
        ],
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
                load == null ? 'Нагрузка —' : 'Нагрузка $load%',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: load == null ? 0 : (load / 100).clamp(0.0, 1.0).toDouble(),
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

  Widget _batCard(BuildContext context, HwSnapshot snap) {
    final cap = snap.batCapacity;
    final v = snap.batVoltageUv;
    final i = snap.batCurrentUa;
    final t = snap.batTemp;
    final status = snap.batStatus ?? '';
    final charging = status == 'Charging';
    final full = status == 'Full' || status == 'Not charging';
    final w = (v != null && i != null) ? (v.abs() * i.abs()) / 1e12 : null;

    String headline;
    if (charging && v != null && i != null) {
      headline =
          '${(v / 1e6).toStringAsFixed(2)} В · ${(i.abs() / 1e6).toStringAsFixed(2)} А';
    } else if (full) {
      headline = 'Заряжено';
    } else if (w != null) {
      headline = _fmtW(w);
    } else {
      headline = '—';
    }

    final temp = t == null ? '' : ' · ${_fmtTempDeci(t)}';
    final String sub;
    if (charging) {
      sub = 'Зарядка${w == null ? '' : ' · ${_fmtW(w)}'}$temp';
    } else if (full) {
      sub = 'Батарея полна$temp';
    } else {
      sub = 'Разряд$temp';
    }

    return _card(
      context,
      'Батарея',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(headline,
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              if (cap != null)
                Text('$cap%', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: cap == null ? 0 : (cap / 100).clamp(0.0, 1.0).toDouble(),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text(sub, style: Theme.of(context).textTheme.bodySmall),
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
              value: ratio.clamp(0.0, 1.0).toDouble(),
              minHeight: 10,
            ),
          ),
          const SizedBox(height: 6),
          Text('Доступно: ${_fmtSize(avail)}',
              style: Theme.of(context).textTheme.bodySmall),
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
              value: ratio.clamp(0.0, 1.0).toDouble(),
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
    for (final e in temps.entries) {
      final k = e.key;
      if (k.startsWith('cpu-') || k.startsWith('cpu_')) {
        if (cpuMax == null || e.value > cpuMax) cpuMax = e.value;
      } else if (k.startsWith('gpu')) {
        if (gpu == null || e.value > gpu) gpu = e.value;
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
        ],
      ),
    );
  }
}
