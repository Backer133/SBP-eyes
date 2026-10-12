import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_version.dart';
import 'ble_service.dart';
import 'eye_log.dart';
import 'theme.dart';
import 'screens/discovery.dart';

void main() {
  // Alles, was sonst nur in der Entwicklerkonsole landet, zusaetzlich ins
  // Protokoll der App legen.
  //
  // Auf dem iPhone gibt es keine Konsole: Safari kann kein Web Bluetooth, Bluefy
  // bringt keine mit, und Safari-Fernwartung braucht einen Mac. Ein Fehler, den
  // niemand sehen kann, ist dort gleichbedeutend mit "die App tut einfach
  // nichts" - und genau daran hat die Fehlersuche mehrfach gehangen.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    final vorher = FlutterError.onError;
    FlutterError.onError = (details) {
      EyeLog.add('Fehler: ${details.exceptionAsString()}');
      vorher?.call(details);
    };
    EyeLog.add('App $kAppVersion gestartet (${kIsWeb ? "Browser" : "App"})');
    runApp(const EyePairApp());
  }, (error, stack) {
    // Hier landen Ausnahmen aus Futures, die niemand abwartet - also genau die
    // Sorte, die vorher spurlos verschwand.
    EyeLog.add('Nicht abgefangen: $error');
  });
}

class EyePairApp extends StatefulWidget {
  const EyePairApp({super.key});
  @override
  State<EyePairApp> createState() => _EyePairAppState();
}

class _EyePairAppState extends State<EyePairApp> {
  final ble = EyeBle();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SBP Eye Settings',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildDarkTheme(),
      theme: buildDarkTheme(),
      home: DiscoveryScreen(ble: ble),
    );
  }
}
