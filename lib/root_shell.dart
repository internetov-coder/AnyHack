import 'dart:io';

/// Железобетонный root-сервис: атомарные вызовы `su -c <script>`
/// через Process.run — без интерактивных пайпов, стримов и PTY.
///
/// При ошибке/таймауте возвращает пустую строку, UI показывает
/// состояние «нет данных», экран никогда не зависает.
class RootShell {
  RootShell._();

  static final RootShell instance = RootShell._();

  Future<String> run(
    String script, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final result = await Process.run(
        'su',
        ['-c', script],
        runInShell: false,
      ).timeout(timeout);
      return result.stdout?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }
}
