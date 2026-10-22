/// Парсер файлов Flipper Zero `.ir` (raw + parsed) и кодировщики протоколов
/// по исходникам Flipper firmware (lib/infrared/encoder_decoder):
/// NEC, NECext, NEC42, NEC42ext, Samsung32, SIRC/SIRC15/SIRC20, RC5, RC6,
/// Kaseikyo (Panasonic), RCA.
///
/// На выходе — паттерн чередующихся mark/space (µs, первый элемент — mark)
/// и частота несущей для `ConsumerIrManager.transmit()`.
library;

class IrButton {
  IrButton({
    required this.name,
    required this.type,
    this.frequency = 38000,
    this.data = const <int>[],
    this.protocol,
    this.address,
    this.command,
  });

  final String name;
  final String type; // 'raw' | 'parsed'
  final int frequency; // raw: частота из файла
  final List<int> data; // raw: тайминги µs, начинается с mark
  final String? protocol;
  final int? address;
  final int? command;

  bool get isRaw => type == 'raw';

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'frequency': frequency,
        'data': data,
        'protocol': protocol,
        'address': address,
        'command': command,
      };

  factory IrButton.fromJson(Map<String, dynamic> j) => IrButton(
        name: j['name'] as String? ?? 'button',
        type: j['type'] as String? ?? 'raw',
        frequency: j['frequency'] as int? ?? 38000,
        data: (j['data'] as List?)?.map((e) => e as int).toList() ??
            const <int>[],
        protocol: j['protocol'] as String?,
        address: j['address'] as int?,
        command: j['command'] as int?,
      );
}

class IrRemote {
  IrRemote({required this.name, required this.buttons});

  final String name;
  final List<IrButton> buttons;

  Map<String, dynamic> toJson() => {
        'name': name,
        'buttons': buttons.map((b) => b.toJson()).toList(),
      };

  factory IrRemote.fromJson(Map<String, dynamic> j) => IrRemote(
        name: j['name'] as String? ?? 'remote',
        buttons: (j['buttons'] as List? ?? const [])
            .map((e) => IrButton.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class IrEncoded {
  const IrEncoded(this.frequency, this.pattern);
  final int frequency;
  final List<int> pattern;
}

/// Разбор содержимого .ir-файла. [fallbackName] — имя без расширения.
IrRemote? parseIrFile(String content, String fallbackName) {
  final blocks = <List<String>>[];
  var cur = <String>[];
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('#')) {
      if (cur.isNotEmpty) {
        blocks.add(cur);
        cur = <String>[];
      }
      continue;
    }
    if (line.isNotEmpty) cur.add(line);
  }
  if (cur.isNotEmpty) blocks.add(cur);

  final buttons = <IrButton>[];
  for (final block in blocks) {
    final kv = <String, String>{};
    for (final line in block) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      kv[line.substring(0, i).trim().toLowerCase()] =
          line.substring(i + 1).trim();
    }
    final type = kv['type'];
    if (type == null) continue; // заголовочный блок Filetype/Version

    final name = kv['name'] ?? 'button ${buttons.length + 1}';
    if (type == 'raw') {
      final data = (kv['data'] ?? '')
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      if (data.isEmpty) continue;
      final freq = int.tryParse(kv['frequency'] ?? '') ?? 38000;
      buttons.add(IrButton(name: name, type: 'raw', frequency: freq, data: data));
    } else if (type == 'parsed') {
      final protocol = kv['protocol'];
      final addr = _parseHexOrBytes(kv['address']);
      final cmd = _parseHexOrBytes(kv['command']);
      if (protocol == null || addr == null || cmd == null) continue;
      buttons.add(IrButton(
        name: name,
        type: 'parsed',
        protocol: protocol,
        address: addr,
        command: cmd,
      ));
    }
  }

  if (buttons.isEmpty) return null;
  return IrRemote(name: fallbackName, buttons: buttons);
}

/// Flipper пишет 4 байта little-endian: "B0 02 20 00" -> 0x002002B0.
/// Также принимает одиночный hex вида "0x04" / "04".
int? _parseHexOrBytes(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  final s = v.trim();
  if (s.contains(' ')) {
    final parts = s.split(RegExp(r'\s+'));
    var result = 0;
    for (var i = 0; i < 4; i++) {
      final b = i < parts.length ? int.tryParse(parts[i], radix: 16) : 0;
      if (b == null) return null;
      result |= (b & 0xFF) << (8 * i);
    }
    return result;
  }
  final hex = (s.startsWith('0x') || s.startsWith('0X')) ? s.substring(2) : s;
  return int.tryParse(hex, radix: 16);
}

/// Кодировщик parsed-сигнала в паттерн Android ConsumerIrManager.
IrEncoded? encodeParsed(String protocol, int address, int command) {
  switch (protocol) {
    case 'NEC':
      final data = (address & 0xFF) |
          ((~address & 0xFF) << 8) |
          ((command & 0xFF) << 16) |
          ((~command & 0xFF) << 24);
      return _necLike(data, 32);
    case 'NECext':
      final data = (address & 0xFFFF) | ((command & 0xFFFF) << 16);
      return _necLike(data, 32);
    case 'NEC42':
      // 13 addr + 13 ~addr + 8 cmd(0..5) | cmd(6..7) + ~cmd
      final d1 = (address & 0x1FFF) |
          ((~address & 0x1FFF) << 13) |
          ((command & 0x3F) << 26);
      final d2 = ((command & 0xC0) >> 6) | ((~command & 0xFF) << 2);
      final bits =
          _lsb(d1 & 0xFFFFFFFF, 32) + _lsb(d2 & 0x3FF, 10);
      return IrEncoded(
        38000,
        _pwmFrame(
          preMark: 9000,
          preSpace: 4500,
          bit1Mark: 560,
          bit1Space: 1690,
          bit0Mark: 560,
          bit0Space: 560,
          bits: bits,
          stopMark: 560,
        ),
      );
    case 'NEC42ext':
      final d1 = (address & 0x3FFFFFF) | ((command & 0x3F) << 26);
      final d2 = (command & 0xFFC0) >> 6;
      final bits =
          _lsb(d1 & 0xFFFFFFFF, 32) + _lsb(d2 & 0x3FF, 10);
      return IrEncoded(
        38000,
        _pwmFrame(
          preMark: 9000,
          preSpace: 4500,
          bit1Mark: 560,
          bit1Space: 1690,
          bit0Mark: 560,
          bit0Space: 560,
          bits: bits,
          stopMark: 560,
        ),
      );
    case 'Samsung32':
      final a = address & 0xFF;
      final data = a |
          (a << 8) |
          ((command & 0xFF) << 16) |
          ((~command & 0xFF) << 24);
      return IrEncoded(
        38000,
        _pwmFrame(
          preMark: 4500,
          preSpace: 4500,
          bit1Mark: 550,
          bit1Space: 1650,
          bit0Mark: 550,
          bit0Space: 550,
          bits: _lsb(data, 32),
          stopMark: 550,
        ),
      );
    case 'SIRC':
    case 'SIRC15':
    case 'SIRC20':
      final bits = switch (protocol) {
        'SIRC' => 12,
        'SIRC15' => 15,
        _ => 20,
      };
      final addrMask = switch (protocol) {
        'SIRC' => 0x1F,
        'SIRC15' => 0xFF,
        _ => 0x1FFF,
      };
      final data = (command & 0x7F) | ((address & addrMask) << 7);
      return IrEncoded(40000, _sircFrame(data, bits));
    case 'RC5':
      return IrEncoded(36000, _rc5Frame(address & 0x1F, command & 0x3F));
    case 'RC6':
      return IrEncoded(36000, _rc6Frame(address & 0xFF, command & 0xFF));
    case 'Kaseikyo':
      return _kaseikyoFrame(address, command);
    case 'RCA':
      return _rcaFrame(address, command);
    default:
      return null;
  }
}

List<int> _lsb(int data, int count) =>
    [for (var i = 0; i < count; i++) (data >> i) & 1];

/// PWM/PDWM-кадр (NEC-семейство, Samsung32, Kaseikyo, RCA):
/// преамбула + биты + stop mark.
List<int> _pwmFrame({
  required int preMark,
  required int preSpace,
  required int bit1Mark,
  required int bit1Space,
  required int bit0Mark,
  required int bit0Space,
  required List<int> bits,
  required int stopMark,
}) {
  final out = <int>[preMark, preSpace];
  for (final b in bits) {
    out.add(b == 1 ? bit1Mark : bit0Mark);
    out.add(b == 1 ? bit1Space : bit0Space);
  }
  if (stopMark > 0) out.add(stopMark);
  return out;
}

/// NEC и NECext: преамбула 9000/4500, 560/1690 | 560/560, stop 560.
IrEncoded _necLike(int data, int bits) {
  return IrEncoded(
    38000,
    _pwmFrame(
      preMark: 9000,
      preSpace: 4500,
      bit1Mark: 560,
      bit1Space: 1690,
      bit0Mark: 560,
      bit0Space: 560,
      bits: _lsb(data, bits),
      stopMark: 560,
    ),
  );
}

/// Sony SIRC: преамбула 2400/600, бит1 = 1200/600, бит0 = 600/600.
List<int> _sircFrame(int data, int bits) {
  final out = <int>[2400, 600];
  for (var i = 0; i < bits; i++) {
    final b = (data >> i) & 1;
    out.add(b == 1 ? 1200 : 600);
    out.add(600);
  }
  return out;
}

/// RC5: 14 бит, Manchester, полубит 888 µs.
/// Порядок: старт(1), старт(1), toggle(0), addr MSB-first, cmd MSB-first.
List<int> _rc5Frame(int address, int command) {
  final semantic = <int>[
    1,
    1,
    0, // toggle
    (address >> 4) & 1,
    (address >> 3) & 1,
    (address >> 2) & 1,
    (address >> 1) & 1,
    address & 1,
    (command >> 5) & 1,
    (command >> 4) & 1,
    (command >> 3) & 1,
    (command >> 2) & 1,
    (command >> 1) & 1,
    command & 1,
  ];
  // Семантика 1 -> space,mark; 0 -> mark,space (как в Flipper).
  final seq = <(int, bool)>[];
  for (final b in semantic) {
    if (b == 1) {
      seq.add((888, false));
      seq.add((888, true));
    } else {
      seq.add((888, true));
      seq.add((888, false));
    }
  }
  return _toPattern(seq);
}

/// RC6 mode0: преамбула 2666/889, 21 бит, полубит 444 µs,
/// бит toggle (индекс 4) удвоен до 888 µs.
List<int> _rc6Frame(int address, int command) {
  final semantic = <int>[
    1, // старт
    0, 0, 0, // mode = 0
    0, // toggle
    for (var i = 7; i >= 0; i--) (address >> i) & 1,
    for (var i = 7; i >= 0; i--) (command >> i) & 1,
  ];
  final seq = <(int, bool)>[(2666, true), (889, false)];
  for (var i = 0; i < semantic.length; i++) {
    final half = i == 4 ? 888 : 444;
    if (semantic[i] == 1) {
      seq.add((half, true));
      seq.add((half, false));
    } else {
      seq.add((half, false));
      seq.add((half, true));
    }
  }
  return _toPattern(seq);
}

/// Kaseikyo (Panasonic): 48 бит, unit 432 µs.
/// Преамбула 3456/1728, бит1 432/1296, бит0 432/432, stop 432.
/// Упаковка — точь-в-точь как в infrared_encoder_kaseikyo.c Flipper:
/// address 26 бит (id2 + vendor16 + genre1 4 + genre2 4), command 10 бит,
/// vendor parity + frame parity.
IrEncoded _kaseikyoFrame(int address, int command) {
  final id = (address >> 24) & 0x3;
  final vendor = (address >> 8) & 0xFFFF;
  final genre1 = (address >> 4) & 0xF;
  final genre2 = address & 0xF;

  final d0 = vendor & 0xFF;
  final d1 = (vendor >> 8) & 0xFF;
  var vendorParity = (d0 ^ d1) & 0xFF;
  vendorParity = ((vendorParity & 0xF) ^ ((vendorParity >> 4) & 0xF)) & 0xF;
  final d2 = vendorParity | ((genre1 & 0xF) << 4);
  final d3 = (genre2 & 0xF) | ((command & 0xF) << 4);
  final d4 = ((id & 0x3) << 6) | ((command >> 4) & 0xFF);
  final d5 = (d2 ^ d3 ^ d4) & 0xFF;

  final data = d0 |
      (d1 << 8) |
      (d2 << 16) |
      (d3 << 24) |
      (d4 << 32) |
      (d5 << 40);

  return IrEncoded(
    38000,
    _pwmFrame(
      preMark: 3456,
      preSpace: 1728,
      bit1Mark: 432,
      bit1Space: 1296,
      bit0Mark: 432,
      bit0Space: 432,
      bits: _lsb(data, 48),
      stopMark: 432,
    ),
  );
}

/// RCA: 24 бита. Преамбула 4000/4000, бит1 500/2000, бит0 500/1000, stop 500.
/// data = addr(4) | cmd(8) | ~addr(4) | ~cmd(8)  — infrared_encoder_rca.c.
IrEncoded _rcaFrame(int address, int command) {
  final a = address & 0xF;
  final c = command & 0xFF;
  final data = (a & 0xF) |
      (c << 4) |
      (((~a) & 0xF) << 12) |
      (((~c) & 0xFF) << 16);
  return IrEncoded(
    38000,
    _pwmFrame(
      preMark: 4000,
      preSpace: 4000,
      bit1Mark: 500,
      bit1Space: 2000,
      bit0Mark: 500,
      bit0Space: 1000,
      bits: _lsb(data, 24),
      stopMark: 500,
    ),
  );
}

/// Приводит последовательность к виду [mark, space, mark, …]:
/// ведущий space убирается (электрически это просто пауза до первого mark).
List<int> _toPattern(List<(int, bool)> seq) {
  var start = 0;
  if (seq.isNotEmpty && !seq.first.$2) start = 1;
  return [for (var i = start; i < seq.length; i++) seq[i].$1];
}
