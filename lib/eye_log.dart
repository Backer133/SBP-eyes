import 'package:flutter/foundation.dart';

/// Mitschrift dessen, was die App mit dem Auge tut - sichtbar IN der App.
///
/// Grund: Auf dem iPhone gibt es keine Entwicklerkonsole. Safari kann kein Web
/// Bluetooth, Bluefy bringt keine Konsole mit, und Safari-Fernwartung braucht
/// einen Mac. Ohne diese Mitschrift laesst sich im Browser nur sagen "es tut
/// nichts" - und genau daran hat die Fehlersuche zuletzt mehrfach gehangen.
///
/// Was hier landet, ist bewusst eng gefasst: jeder GATT-Vorgang mit Dauer und
/// Ausgang, dazu nicht abgefangene Fehler. Kein allgemeines Protokoll - eine
/// Liste, die alles enthaelt, enthaelt nichts Brauchbares.
class EyeLog {
  EyeLog._();

  /// Ringpuffer. 400 Zeilen reichen fuer mehrere Verbindungsversuche und bleiben
  /// klein genug, um sie am Stueck in die Zwischenablage zu legen.
  static const int _max = 400;
  static final List<String> _lines = [];

  /// Zaehlt hoch bei jeder neuen Zeile - die Anzeige haengt sich daran.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static DateTime? _t0;

  static void add(String text) {
    _t0 ??= DateTime.now();
    final ms = DateTime.now().difference(_t0!).inMilliseconds;
    final stamp = (ms / 1000).toStringAsFixed(1).padLeft(7);
    _lines.add('$stamp s  $text');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    revision.value++;
  }

  /// Ein GATT-Vorgang: was, wie lange, wie ausgegangen.
  ///
  /// Die Dauer ist der eigentliche Wert dieser Mitschrift. "Lesen 0002 ok 180ms"
  /// gegen "Lesen 0002 ok 4200ms" ist der Unterschied zwischen einem gesunden
  /// und einem ueberlasteten Kanal - und den sieht man sonst nirgends.
  static void gatt(String what, int ms, {String? fehler}) {
    add(fehler == null
        ? '$what  ok  ${ms}ms'
        : '$what  FEHLER nach ${ms}ms: $fehler');
  }

  static List<String> get lines => List.unmodifiable(_lines);

  static String get text => _lines.join('\n');

  static void clear() {
    _lines.clear();
    _t0 = null;
    revision.value++;
  }
}
