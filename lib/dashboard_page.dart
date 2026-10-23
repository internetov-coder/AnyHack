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
echo CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
echo V=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
echo I=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
echo T=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
echo S=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
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
  'stock': [1.0, 1.0, 1.0],
};

const List<({String id, String label})> _profiles = [
  (id: 'performance', label: 'Performance'),
  (id: 'balanced', label: 'Balanced'),
  (id: 'economy', label: 'Economy'),
  (id: 'economy_plus', label: 'Economy+'),
  (id: 'stock', label: 'Stock'),
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
        // ядро клэмпит наверху (термо, зарядка), поэтому успех =
        // применённое не выше цели профиля
        final t0 = targets[0] ?? 0;
        final t4 = targets[4] ?? 0;
        final t7 = targets[7] ?? 0;
        final ok = got.length >= 3 &&
            got[0] <= t0 &&
            got[1] <= t4 &&
            got[2] <= t7;
        if (ok) {
          final clamped = got[0] < t0 || got[1] < t4 || got[2] < t7;
          status = 'применено · little ${_fmtGhz(got[0])} · '
              'medium ${_fmtGhz(got[1])} · big ${_fmtGhz(got[2])} ГГц'
              '${clamped ? ' · ограничение системы' : ''}';
          try {
            final prefs = await SharedPreferences.getInstance();
            if (id == 'stock') {
              await prefs.remove('cpu_profile');
            } else {
              await prefs.setString('cpu_profile', id);
            }
          } catch (_) {}
          if (mounted) {
            setState(() => _profile = id == 'stock' ? null : id);
          }
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
      padding: const EdgeInsets.only(bottom: 20),
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
        _section(context, 'Железо'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cpuTile(context, snap)),
              const SizedBox(width: 10),
              Expanded(child: _gpuTile(context, snap)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _ramTile(context, snap)),
              const SizedBox(width: 10),
              Expanded(child: _diskTile(context, snap)),
            ],
          ),
        ),
        _section(context, 'Питание'),
        _batCard(context, snap),
        _section(context, 'Частоты ядер'),
        _profileCard(context),
        _coresCard(context, snap),
        _section(context, 'Температуры'),
        _tempCard(context, snap),
        const SizedBox(height: 6),
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

  Widget _tile(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String value,
    required double bar,
    required String caption,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: bar.clamp(0.0, 1.0).toDouble(),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  int? _avgKhz(List<int> l) =>
      l.isEmpty ? null : l.reduce((a, b) => a + b) ~/ l.length;

  ({int? l, int? m, int? b}) _clusterAvg(HwSnapshot snap) {
    final little = <int>[];
    final medium = <int>[];
    final big = <int>[];
    for (final e in snap.coreFreqs.entries) {
      if (e.key < 4) {
        little.add(e.value);
      } else if (e.key < 7) {
        medium.add(e.value);
      } else {
        big.add(e.value);
      }
    }
    return (l: _avgKhz(little), m: _avgKhz(medium), b: _avgKhz(big));
  }

  String _ghz(int? khz) => khz == null ? '—' : (khz / 1000000).toString();

  Widget _cpuTile(BuildContext context, HwSnapshot snap) {
    final load = _cpuLoad;
    final a = _clusterAvg(snap);
    return _tile(
      context,
      title: 'CPU',
      icon: Icons.memory,
      value: load == null ? '—' : '${load.toStringAsFixed(0)}%',
      bar: (load ?? 0) / 100,
      caption: 'L ${_ghz(a.l)} · M ${_ghz(a.m)} · B ${_ghz(a.b)} ГГц',
    );
  }

  Widget _gpuTile(BuildContext context, HwSnapshot snap) {
    final freq = snap.gpuFreqHz;
    final load = snap.gpuLoad;
    return _tile(
      context,
      title: 'GPU',
      icon: Icons.videogame_asset,
      value: freq == null ? '—' : '${(freq / 1e6).round()} МГц',
      bar: (load ?? 0) / 100,
      caption:
          load == null ? 'Mali-G615' : 'Mali-G615 · нагрузка $load%',
    );
  }

  Widget _ramTile(BuildContext context, HwSnapshot snap) {
    final total = snap.memTotalKb;
    final avail = snap.memAvailKb;
    final used = total > 0 ? total - avail : 0;
    final ratio = total > 0 ? used / total : 0.0;
    return _tile(
      context,
      title: 'ОЗУ',
      icon: Icons.layers,
      value: total == 0 ? '—' : '${_fmtSize(used)} / ${_fmtSize(total)}',
      bar: ratio,
      caption: total == 0 ? 'нет данных' : 'доступно ${_fmtSize(avail)}',
    );
  }

  Widget _diskTile(BuildContext context, HwSnapshot snap) {
    final total = snap.diskTotalKb;
    final used = snap.diskUsedKb;
    if (total == null || used == null) {
      return _tile(
        context,
        title: 'Диск',
        icon: Icons.sd_storage,
        value: '—',
        bar: 0,
        caption: 'нет данных',
      );
    }
    final ratio = total > 0 ? used / total : 0.0;
    return _tile(
      context,
      title: 'Диск',
      icon: Icons.sd_storage,
      value: '${_fmtSize(used)} / ${_fmtSize(total)}',
      bar: ratio,
      caption: 'свободно ${_fmtSize(total - used)}',
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

  Widget _coresCard(BuildContext context, HwSnapshot snap) {
    final a = _clusterAvg(snap);
    return _card(
      context,
      'Ядра',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < 8; i++)
                _coreChip(context, i, snap.coreFreqs[i]),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Little ×4 ${a.l == null ? '—' : _fmtFreq(a.l!)}  ·  '
            'Medium ×3 ${a.m == null ? '—' : _fmtFreq(a.m!)}  ·  '
            'Big ${a.b == null ? '—' : _fmtFreq(a.b!)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: snap.governor.isEmpty
          ? null
          : Chip(
              label: Text(snap.governor,
                  style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
