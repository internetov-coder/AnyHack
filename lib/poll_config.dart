import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PollConfig {
  PollConfig._();

  static const String key = 'poll_interval_ms';
  static final ValueNotifier<int> intervalMs = ValueNotifier<int>(1500);

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(key);
      if (v != null && v >= 100 && v <= 120000) intervalMs.value = v;
    } catch (_) {
      // остаётся дефолт 1500 мс
    }
  }

  static Future<void> set(int ms) async {
    intervalMs.value = ms;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, ms);
    } catch (_) {}
  }
}
