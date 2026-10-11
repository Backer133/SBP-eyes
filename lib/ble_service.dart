import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'image_pipeline.dart' show kEyeJpegMax, isCompleteJpeg;

// UUIDs MUESSEN identisch zu denen im Master.ino sein!
class EyeUuids {
  static final Guid svcEyeCtrl   = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrEyeId     = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrBrightness= Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrAnimEn    = Guid("6E400004-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrEyeCount  = Guid("6E400006-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrEyeUpload    = Guid("6E400007-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrUploadStat   = Guid("6E400008-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrSlaveReceipt = Guid("6E400009-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Guid chrSlotStatus   = Guid("6E40000A-B5A3-F393-E0A9-E50E24DCCA9E");
  // Zugangsschutz (BLE-Sicherheit)
  static final Guid chrAuth         = Guid("6E40000B-B5A3-F393-E0A9-E50E24DCCA9E");  // WRITE uint32: 6-stelliger Code
  static final Guid chrSetKey       = Guid("6E40000C-B5A3-F393-E0A9-E50E24DCCA9E");  // WRITE uint32: neuen Geraete-Key
  static final Guid chrAuthStatus   = Guid("6E40000D-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/NOTIFY: 1=autorisiert
  static final Guid chrDeviceName   = Guid("6E40000E-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/WRITE: Anzeigename
  // Paar-Kopplung. 6E400010 ist bereits svcDiag -> kollisionsfreier Block ab 0012.
  static final Guid chrPairCtrl     = Guid("6E400012-B5A3-F393-E0A9-E50E24DCCA9E");  // WRITE: Kommando (+MAC)
  static final Guid chrPairFound    = Guid("6E400013-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/NOTIFY: ein Fund
  static final Guid chrPairState    = Guid("6E400014-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/NOTIFY: Zustand
  // Augen-Ausrichtung auf die Maske (je Auge) und Bewegung (fuers Paar)
  static final Guid chrEyeGeom      = Guid("6E400015-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/WRITE
  // Bewusst OHNE Notify - NimBLE hat pro Verbindung nur ~8 CCCD-Slots, und die sind
  // bereits vergeben. Der Stand wird nach jedem Schreibvorgang aktiv gelesen.
  static final Guid chrAnimCfg      = Guid("6E400018-B5A3-F393-E0A9-E50E24DCCA9E");  // READ/WRITE

  static final Guid svcDiag      = Guid("6E400010-B5A3-F393-E0A9-E50E24DCCA9E");
  // Funk-Status: 1 = zweiter Screen (Slave) per ESP-NOW verbunden, 0 = nicht.
  static final Guid chrSlaveLink = Guid("6E400016-B5A3-F393-E0A9-E50E24DCCA9E");
  // ESP-NOW-Verbindungsqualitaet: [0]=state, [1..2]=silence_ms (LE), [3]=loss_pct.
  static final Guid chrLinkDiag  = Guid("6E400017-B5A3-F393-E0A9-E50E24DCCA9E");
}

const int kHardcodedEyeCount = 4;   // A7, A10, A12, A13 (in dieser Reihenfolge!)
// Vier Slots. Als Cloud-Augen noch Rohdaten waren (204800 Byte je Slot), war das
// die Obergrenze: vier belegten 819200 der 917504 Byte des LittleFS. Als JPEG sind
// es nur noch rund 45 KB je Slot, es waeren also deutlich mehr moeglich - acht
// waere das Maximum, weil die Belegt-Maske vom Master ein Byte breit ist.
// Bewusst bei vier geblieben: so bleiben alle gespeicherten Augen-Nummern gueltig
// und das Raster bleibt wie es war. MUSS zu CLOUD_SLOT_COUNT in der Firmware passen.
const int kCloudSlotCount    = 4;

// Werks-Standard-Zugangscode (muss zu DEFAULT_DEVICE_KEY in der Firmware passen).
// Referenzwert/Hinweis fuer den User - wird NICHT mehr automatisch gesendet: der Code
// muss bei jedem Verbinden manuell eingegeben werden (auch dieser Default).
const int kDefaultDeviceKey = 123456;

// Der Admin-Code steht BEWUSST NICHT in der App: dieses Repo ist oeffentlich, und
// ein veroeffentlichter Admin-Code waere der Generalschluessel fuer alle Augen.
// Ob die aktuelle Sitzung Admin-Rechte hat, meldet die Firmware ueber
// CHR_AUTH_STATUS (0 = gesperrt, 1 = Geraete-Code, 2 = Admin).

/// Bewegungs-Konfiguration des Paares. Spiegelt `struct AnimCfg` aus Pairing.h -
/// 17 Byte, little-endian, gepackt. Gilt fuer BEIDE Augen: sie muessen identisch
/// rechnen, sonst blinzeln sie nicht mehr gleichzeitig.
///
/// Werkswerte und Voreinstellungen stehen bewusst NICHT hier, sondern nur in der
/// Firmware - sonst muessten dieselben Zahlenreihen doppelt gepflegt werden. Die App
/// bittet um "Voreinstellung 1" und liest das Ergebnis zurueck.
class AnimCfg {
  final int holdMs, moveMs;
  final int posCount, ampX, ampY, arc, ease;
  final int blinkWindowMs, blinkCloseMs, blinkHoldMs, blinkOpenMs;

  const AnimCfg({
    required this.holdMs, required this.moveMs,
    required this.posCount, required this.ampX, required this.ampY,
    required this.arc, required this.ease,
    required this.blinkWindowMs, required this.blinkCloseMs,
    required this.blinkHoldMs, required this.blinkOpenMs,
  });

  static const int byteLength = 17;

  factory AnimCfg.fromBytes(List<int> v) {
    final b = ByteData.sublistView(Uint8List.fromList(v));
    return AnimCfg(
      holdMs:        b.getUint16(0, Endian.little),
      moveMs:        b.getUint16(2, Endian.little),
      posCount:      b.getUint8(4),
      ampX:          b.getUint8(5),
      ampY:          b.getUint8(6),
      arc:           b.getUint8(7),
      ease:          b.getUint8(8),
      blinkWindowMs: b.getUint16(9,  Endian.little),
      blinkCloseMs:  b.getUint16(11, Endian.little),
      blinkHoldMs:   b.getUint16(13, Endian.little),
      blinkOpenMs:   b.getUint16(15, Endian.little),
    );
  }

  Uint8List toBytes() {
    final b = ByteData(byteLength);
    b.setUint16(0, holdMs, Endian.little);
    b.setUint16(2, moveMs, Endian.little);
    b.setUint8(4, posCount);
    b.setUint8(5, ampX);
    b.setUint8(6, ampY);
    b.setUint8(7, arc);
    b.setUint8(8, ease);
    b.setUint16(9,  blinkWindowMs, Endian.little);
    b.setUint16(11, blinkCloseMs,  Endian.little);
    b.setUint16(13, blinkHoldMs,   Endian.little);
    b.setUint16(15, blinkOpenMs,   Endian.little);
    return b.buffer.asUint8List();
  }

  AnimCfg copyWith({
    int? holdMs, int? moveMs, int? posCount, int? ampX, int? ampY,
    int? arc, int? ease, int? blinkWindowMs, int? blinkCloseMs,
    int? blinkHoldMs, int? blinkOpenMs,
  }) => AnimCfg(
        holdMs: holdMs ?? this.holdMs,
        moveMs: moveMs ?? this.moveMs,
        posCount: posCount ?? this.posCount,
        ampX: ampX ?? this.ampX,
        ampY: ampY ?? this.ampY,
        arc: arc ?? this.arc,
        ease: ease ?? this.ease,
        blinkWindowMs: blinkWindowMs ?? this.blinkWindowMs,
        blinkCloseMs: blinkCloseMs ?? this.blinkCloseMs,
        blinkHoldMs: blinkHoldMs ?? this.blinkHoldMs,
        blinkOpenMs: blinkOpenMs ?? this.blinkOpenMs,
      );
}

/// Ein vom Master gefundener koppelbarer Slave (aus CHR_PAIR_FOUND).
class FoundSlave {
  final List<int> mac;      // 6 Bytes
  final int rssi;           // dBm, negativ
  final bool alreadyBound;  // gebunden - egal an wen
  final bool boundToOther;  // gebunden an einen ANDEREN Master als diesen
  const FoundSlave(this.mac, this.rssi, this.alreadyBound, this.boundToOther);

  /// Gehoert zu genau dem Master, mit dem die App gerade verbunden ist.
  bool get boundToThisMaster => alreadyBound && !boundToOther;
  /// Frei zum Koppeln.
  bool get free => !alreadyBound;

  String get macStr =>
      mac.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
  /// Letzte zwei Bytes, z.B. "FD:D8" - kurz genug fuer die Liste.
  String get shortId => macStr.substring(12);
}

// Asset-Namen zu Eye-Index. MUSS in der Reihenfolge identisch zu EYE_IMAGES[]
// im Master.ino + Slave.ino sein! Nur hardcoded Augen (Index 0..3).
const List<String> kEyeAssets = [
  'assets/eyes/A7.png',
  'assets/eyes/A10.png',
  'assets/eyes/A12.png',
  'assets/eyes/A13.png',
];
const List<String> kEyeLabels = [
  'A7','A10','A12','A13'
];

class EyeBle extends ChangeNotifier {
  BluetoothDevice? device;
  final Map<Guid, BluetoothCharacteristic> _chars = {};

  // State exposed to UI
  //
  // Augenbild, Helligkeit und Animation gelten JE AUGE: Index 0 = Master, 1 = Slave.
  // Gleiche Anordnung wie eyeYOff/eyeVisH bei der Maskenausrichtung, damit der
  // Ausricht-Bildschirm und das Augen-Raster dasselbe Muster verwenden.
  List<int> eyeId       = [0, 0];
  List<int> brightness  = [255, 255];
  List<int> animEnabled = [1, 1];
  int eyeCount = 0;

  /// Ziel fuer die Setter unten.
  static const int kMaster = 0;
  static const int kSlave  = 1;
  static const int kBeide  = 2;
  // Funk-Status: haengt der zweite Screen (Slave) per ESP-NOW dran? Kommt aus dem
  // Pair-State, den der Master ueber CHR_SLAVE_LINK meldet.
  bool slaveLinked = false;
  // ESP-NOW-Funk-Diagnose (aus CHR_LINK_DIAG): Zustand + Qualitaet der Verbindung.
  int linkState = 0;    // PairState: 4=LINKED 5=DEGRADED 6=LOST (siehe linkStateName)
  int silenceMs = 0;    // ms seit letztem Signal vom Slave
  int lossPct   = 0;    // Master->Slave Unicast-Verlustrate in %
  // WLAN-Kanal des Masters und der zuletzt vom Slave gemeldete Kanal (0 = unbekannt).
  // Bei bestehender Verbindung sind beide zwangslaeufig gleich - ESP-NOW funktioniert
  // nur so. Auseinanderlaufende Werte heissen: der Slave sucht noch.
  int masterChannel = 0;
  int slaveChannel  = 0;
  StreamSubscription<List<int>>? _subLinkDiag;
  bool connected = false;
  // Zugangsschutz: true = Verbindung ist autorisiert (Steuerung freigeschaltet).
  bool authorized = false;
  /// Vom Master gemeldetes Auth-Level: 0 = gesperrt, 1 = Geraete-Code, 2 = Admin.
  int authLevel = 0;
  /// UUID-Kurzformen der Characteristics, deren Abo beim Verbinden scheiterte.
  /// Leer = alles in Ordnung. Wird in der Diagnose angezeigt.
  final List<String> subscribeErrors = [];
  bool authSupported = false;  // false = alte Firmware ohne Auth-Charakteristik
  // Zaehlt hoch bei jedem fehlgeschlagenen Code-Versuch (fuer UI-Feedback).
  int authAttempts = 0;
  // Nur im RAM (nie in SharedPreferences): der in DIESER App-Sitzung erfolgreich
  // eingegebene Zugangscode. Damit laufen interne Reconnects (z.B. Cloud-Upload)
  // still weiter, ein frischer App-Start / manuelles Verbinden aber verlangt den
  // Code erneut. So reicht App-Besitz allein nicht fuer Zugriff.
  int? _sessionKey;
  StreamSubscription<List<int>>? _subAuthStatus;
  // Frei waehlbarer Anzeigename dieses Augenpaars (aus CHR_DEVICE_NAME).
  String deviceName = "";
  // Slave-Receipt nach Cloud-Eye-Upload
  int slaveReceiptSlot      = 0;
  int slaveUniqueReceived   = 0;
  int slaveTotalChunks      = 0;
  int slaveReRequestRound   = 0;
  StreamSubscription<List<int>>? _subSlaveReceipt;
  // --- Paar-Kopplung ---
  final List<FoundSlave> pairingFound = [];
  int pairingState = 0;   // 0 idle, 1 scannend, 2 bindend, 3 entkoppelnd, 4 Fehler
  int pairingError = 0;   // siehe pairingErrorText
  List<int> boundMac = const [0, 0, 0, 0, 0, 0];
  int boundPairId = 0;
  /// true, wenn in dieser Sitzung mit dem Admin-Code autorisiert wurde.
  bool isAdmin = false;
  StreamSubscription<List<int>>? _subPairFound;
  StreamSubscription<List<int>>? _subPairState;

  bool get isBound => boundMac.any((b) => b != 0);

  String get boundMacStr =>
      boundMac.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

  String get pairingErrorText {
    switch (pairingError) {
      case 1: return 'Der Slave hat die Kopplung nicht bestaetigt';
      case 2: return 'Der Slave gehoert schon zu einem anderen Master';
      case 3: return 'Dafuer wird der Admin-Code gebraucht';
      case 4: return 'Slave nicht gefunden';
      case 5: return 'Eigene Kopplung geloest, aber der Slave hat sich nicht '
                     'gemeldet - er haelt sich weiter fuer gebunden. Mit dem '
                     'Admin-Code zwangsloesen.';
      default: return '';
    }
  }

  // --- Augen-Ausrichtung auf die Maske (je Auge) ---
  // Index 0 = Master, 1 = Slave. Handgeschnitzte Oeffnungen weichen voneinander ab,
  // deshalb hat jedes Auge eigene Werte.
  List<int> eyeYOff = [0, 0];
  List<int> eyeVisH = [240, 240];
  // Seitlicher Versatz und Augengroesse, ebenfalls je Auge. Die Firmware klemmt
  // den Versatz zusaetzlich auf den tatsaechlich vorhandenen Bildueberhang -
  // der Regler darf also weiter gehen, als am Ende sichtbar wirkt.
  List<int> eyeXOff = [0, 0];
  List<int> eyeZoom = [100, 100];   // Prozent, 100 = unveraendert

  // --- Bewegung (fuers Paar) ---
  AnimCfg? animCfg;                 // null = noch nicht gelesen

  // Slot-Bitmap (Bit n = Slot n hat ein Bild auf dem Master in LittleFS).
  // Wird nur EINMAL beim Connect aus CHR_SLOT_STATUS gelesen (kein Notify mehr -
  // das hat den ESP-NOW-Forward gestoert). Reicht fuer "belegt"-Anzeige nach
  // App-Reinstall: SharedPreferences leer, aber Master kennt den Status noch.
  int slotOccupiedMask      = 0;

  StreamSubscription<List<int>>? _subEyeId;
  StreamSubscription<List<int>>? _subSlaveLink;
  StreamSubscription<BluetoothConnectionState>? _subConn;

  Future<void> connectAndDiscover(BluetoothDevice d) async {
    // Erst eine eventuell noch offene Verbindung sauber abbauen.
    //
    // Ohne das blieben beim Wechsel auf ein anderes Augenpaar die alte Verbindung UND
    // ihre Notify-Abos bestehen. Beide Master schrieben dann in denselben Zustand, und
    // die Diagnose sprang bei jeder Meldung zwischen den Werten des einen und des
    // anderen hin und her - sichtbar als Kanal, der zwischen 1 und 6 wechselt, obwohl
    // im Seriellen Log beider Geraete der Kanal stabil stand.
    //
    // Mit nur einem Paar konnte das nie auffallen.
    if (device != null || _subConn != null) {
      await disconnect();
    }
    device = d;
    await d.connect(timeout: const Duration(seconds: 10), autoConnect: false);

    // Groessere BLE-Pakete aushandeln, bevor irgendetwas uebertragen wird.
    //
    // Beim Cloud-Auge zaehlt fast nur die Anzahl der Pakete: jedes kostet rund ein
    // Verbindungsintervall, weil auf die Bestaetigung des Auges gewartet wird - egal
    // wie voll es ist. Mit der bisherigen MTU (255, NimBLE-Voreinstellung) waren das
    // 861 Pakete fuer ein Bild.
    //
    // Die Haeppchengroesse wird bewusst aus dem TATSAECHLICH gewaehrten Wert berechnet
    // und nicht fest gesetzt: ein Auge mit aelterer Firmware gewaehrt weiterhin nur 255,
    // und die App muss sich danach richten, statt mit zu grossen Paketen aufzulaufen.
    try {
      final mtu = await d.requestMtu(512);
      // 3 Byte ATT-Kopf, 6 Byte eigener Kopf. Untergrenze ist der bisherige Wert,
      // damit sich am Verhalten gegenueber alter Firmware nichts aendert.
      _chunkSize = (mtu - 9).clamp(_kChunkSizeMin, _kChunkSizeMax);
    } catch (_) {
      // Schlaegt die Aushandlung fehl, bleibt es beim bisherigen Wert - der hat
      // immer funktioniert.
      _chunkSize = _kChunkSizeMin;
    }

    _subConn = d.connectionState.listen((s) {
      connected = (s == BluetoothConnectionState.connected);
      notifyListeners();
    });

    final services = await d.discoverServices();
    for (final s in services) {
      for (final c in s.characteristics) {
        _chars[c.uuid] = c;
      }
    }

    await _readAll();
    await _subscribeNotifies();
    await _authenticate();   // Zugangscode (Default 123456) automatisch senden

    connected = true;
    notifyListeners();
  }

  // ===== Zugangsschutz =====

  /// Stabiler, eindeutiger Schluessel pro Geraet (BLE-Adresse). Wird fuer lokal
  /// gespeicherte Daten benutzt (Zugangscode, Cloud-Slot-Metadaten).
  String get deviceId => device?.remoteId.str ?? 'unknown';

  /// true = Firmware verlangt Autorisierung, aber wir sind (noch) nicht
  /// autorisiert -> die App muss die Steuerung sperren (Zugangs-Gate zeigen).
  bool get locked => authSupported && !authorized;

  /// Klartext des ESP-NOW-Verbindungszustands (PairState aus der Firmware).
  ///
  /// Ohne Kopplung steht die Firmware bewusst in PS_LOST (die Discovery-Maschinerie
  /// ist stillgelegt). "Verloren" laese sich dort als Stoerung, obwohl schlicht noch
  /// kein Partner gebunden ist - deshalb der eigene Text.
  String get linkStateName {
    if (!isBound) return 'Nicht gekoppelt';
    switch (linkState) {
      case 4: return 'Verbunden';
      case 5: return 'Instabil';
      case 6: return 'Verloren';
      case 3: return 'Koppeln...';
      case 2: return 'Suche...';
      case 1: return 'Reconnect...';
      default: return 'Startet...';
    }
  }

  /// CHR_AUTH_STATUS liefert das Auth-Level: 0 = gesperrt, 1 = Geraete-Code,
  /// 2 = Admin-Code. Aeltere Firmware kennt nur 0/1 - deshalb ">= 1" statt "== 1".
  void _parseAuthLevel(int level) {
    authLevel  = level;
    authorized = level >= 1;
    isAdmin    = level >= 2;
  }

  Future<void> _writeKey(BluetoothCharacteristic c, int key) async {
    final b = ByteData(4)..setUint32(0, key, Endian.little);
    await c.write(b.buffer.asUint8List(), withoutResponse: false);
  }

  // Beim Connect: Auth-Status abonnieren. Es wird KEIN gespeicherter Code mehr
  // automatisch gesendet -> ohne Session-Key bleibt die Verbindung gesperrt und die
  // App zeigt das LockGate (Code-Eingabe noetig, auch beim ersten Verbinden).
  // Nur wenn in dieser Sitzung bereits ein Code erfolgreich eingegeben wurde
  // (_sessionKey), wird er still gesendet - damit interne Reconnects (Cloud-Upload)
  // nicht erneut nach dem Code fragen.
  // Alte Firmware ohne CHR_AUTH -> authSupported=false, alles gilt als frei.
  Future<void> _authenticate() async {
    final c = _chars[EyeUuids.chrAuth];
    if (c == null) {
      authSupported = false;
      authorized = true;
      notifyListeners();
      return;
    }
    authSupported = true;
    final cs = _chars[EyeUuids.chrAuthStatus];
    if (cs != null) {
      try {
        await cs.setNotifyValue(true);
        _subAuthStatus = cs.lastValueStream.listen((v) {
          if (v.isNotEmpty) { _parseAuthLevel(v[0]); notifyListeners(); }
        });
        final init = await cs.read();
        if (init.isNotEmpty) _parseAuthLevel(init[0]);
      } catch (_) {}
    }
    if (_sessionKey != null) {
      final before = authLevel;
      await _writeKey(c, _sessionKey!);
      // Kurz auf die Autorisierungs-Antwort warten, damit das Gate beim stillen
      // Reconnect nicht aufblitzt. Fragt aktiv nach statt nur zu lauschen -
      // Begruendung bei _awaitAuthLevelChange().
      await _awaitAuthLevelChange(before, tries: 16);
    }
  }

  /// Wartet darauf, dass die Firmware das Autorisierungs-Level ändert.
  ///
  /// Wartet NICHT nur auf die Benachrichtigung, sondern FRAGT AKTIV NACH.
  /// Grund: Das Abonnieren von Benachrichtigungen kann stillschweigend
  /// fehlschlagen — die App führt dafür nicht umsonst eine Liste
  /// (`subscribeErrors`, im Diagnose-Bildschirm sichtbar). Im Browser ist das
  /// der Normalfall statt der Ausnahme: über Web Bluetooth kam die Antwort auf
  /// dem iPhone nie an, die Eingabe des Zugangscodes lief ins Leere, obwohl das
  /// Auge ihn längst angenommen hatte.
  ///
  /// CHR_AUTH_STATUS ist READ/NOTIFY — Nachfragen ist also jederzeit erlaubt und
  /// auf jeder Plattform verlässlich. Die Benachrichtigung bleibt zusätzlich
  /// aktiv; kommt sie an, ist man nur schneller fertig.
  Future<void> _awaitAuthLevelChange(int before, {int tries = 20}) async {
    final cs = _chars[EyeUuids.chrAuthStatus];
    for (int i = 0; i < tries && authLevel == before; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (cs == null || authLevel != before) continue;
      try {
        final v = await cs.read();
        if (v.isNotEmpty) { _parseAuthLevel(v[0]); notifyListeners(); }
      } catch (_) {
        // Ein fehlgeschlagener Lesevorgang ist kein Grund abzubrechen - beim
        // naechsten Durchgang kann es klappen.
      }
    }
  }

  /// Manuelle Code-Eingabe (falls der gespeicherte Code nicht passt, z.B. anderer
  /// Nutzer / Admin-Key). Sendet den Code, wartet auf die Autorisierungs-Antwort
  /// der Firmware und merkt sich den Code NUR bei Erfolg. Gibt true zurueck, wenn
  /// die Verbindung danach autorisiert ist.
  Future<bool> authenticateWith(int key) async {
    final c = _chars[EyeUuids.chrAuth];
    if (c == null) return false;
    // Auf die AENDERUNG des Levels warten, nicht auf "authorized". Sonst laeuft
    // ein Wechsel vom Geraete- auf den Admin-Code sofort durch, ohne dass die
    // Antwort der Firmware da ist - isAdmin waere dann noch nicht gesetzt.
    final before = authLevel;
    await _writeKey(c, key);
    await _awaitAuthLevelChange(before);
    if (authorized) {
      _sessionKey = key;   // korrekter Code -> nur fuer diese Sitzung merken (RAM)
      // isAdmin wurde bereits aus CHR_AUTH_STATUS gesetzt (_parseAuthLevel) -
      // die App muss den Admin-Code dafuer nicht kennen.
      return true;
    }
    authAttempts++;        // falscher Code -> UI-Feedback
    notifyListeners();
    return false;
  }

  /// Aendert den Geraete-Key (nur wenn autorisiert). Merkt sich den neuen Code nur
  /// fuer diese Sitzung, damit ein stiller Reconnect ihn nutzt - beim naechsten
  /// App-Start wird wieder danach gefragt.
  Future<bool> changeDeviceKey(int newKey) async {
    final c = _chars[EyeUuids.chrSetKey];
    if (c == null || locked || newKey < 0 || newKey > 999999) return false;
    await _writeKey(c, newKey);
    // Gegenprobe: mit dem neuen Code neu autorisieren. Die Firmware liest den
    // Schluessel nicht zurueck - er liegt dort nur als Hash - also ist das der
    // einzige Weg festzustellen, ob der Wechsel wirklich angekommen ist.
    // Ohne diese Pruefung meldete die App auch dann Erfolg, wenn der Write
    // verworfen wurde, und der Nutzer verliesse sich auf einen Code, der nicht gilt.
    // Nebenwirkung: War die Sitzung als Admin angemeldet, faellt sie damit auf
    // die normale Geraete-Berechtigung zurueck.
    final ok = await authenticateWith(newKey);
    if (ok) _sessionKey = newKey;
    return ok;
  }

  /// Setzt den frei waehlbaren Anzeigenamen des Augenpaars (nur wenn autorisiert).
  /// Der neue Name erscheint beim naechsten Scan in der Geraeteliste.
  Future<bool> setDeviceName(String name) async {
    final c = _chars[EyeUuids.chrDeviceName];
    final trimmed = name.trim();
    if (c == null || trimmed.isEmpty || trimmed.length > 23) return false;
    await c.write(trimmed.codeUnits, withoutResponse: false);
    deviceName = trimmed;
    notifyListeners();
    return true;
  }

  /// Reconnect zum gleichen Master nach Disconnect (z.B. nach Cloud-Upload).
  /// Wirft Exception wenn kein device bekannt oder Reconnect fehlschlaegt.
  Future<void> reconnect() async {
    if (device == null) throw Exception('Kein vorheriges Geraet bekannt');
    await connectAndDiscover(device!);
  }

  /// [forget]=true vergisst den Sitzungs-Code -> der naechste Connect verlangt wieder
  /// die PIN (fuer den vom Nutzer ausgeloesten Trennen-Button). Der interne
  /// Cloud-Upload-Ablauf ruft disconnect() ohne forget, damit sein automatischer
  /// Reconnect still bleibt.
  Future<void> disconnect({bool forget = false}) async {
    await _subEyeId?.cancel();
    await _subSlaveLink?.cancel();
    await _subLinkDiag?.cancel();
    await _subSlaveReceipt?.cancel();
    await _subAuthStatus?.cancel();
    await _subPairFound?.cancel();
    await _subPairState?.cancel();
    await _subConn?.cancel();
    _chars.clear();
    try { await device?.disconnect(); } catch (_) {}
    connected = false;
    authorized = false;
    authLevel = 0;
    authSupported = false;
    slaveLinked = false;
    // Diagnosewerte mit zuruecksetzen, sonst zeigt der Bildschirm nach einem Wechsel
    // noch die Zahlen des vorigen Augenpaares, bis dessen Nachfolger sich meldet.
    linkState = 0;
    silenceMs = 0;
    lossPct = 0;
    masterChannel = 0;
    slaveChannel = 0;
    pairingFound.clear();
    pairingState = 0;
    pairingError = 0;
    isAdmin = false;
    if (forget) _sessionKey = null;
    notifyListeners();
  }

  /// Liest einen Wert, der je Auge getrennt ist: 2 Bytes [Master, Slave].
  ///
  /// Aeltere Firmware antwortet mit EINEM Byte - dann galt der Wert noch fuer beide
  /// Augen, also wird er auf beide Plaetze gelegt. Ohne diesen Fall braeche die App
  /// an einem noch nicht aktualisierten Auge ab.
  Future<List<int>?> _readPair(Guid id) async {
    final v = await _readBytes(id);
    if (v == null || v.isEmpty) return null;
    return v.length >= 2 ? [v[0], v[1]] : [v[0], v[0]];
  }

  Future<void> _readAll() async {
    final eid   = await _readPair(EyeUuids.chrEyeId);
    final br    = await _readPair(EyeUuids.chrBrightness);
    final anim  = await _readPair(EyeUuids.chrAnimEn);
    final cnt   = await _readByte(EyeUuids.chrEyeCount);
    final link  = await _readByte(EyeUuids.chrSlaveLink);

    if (eid != null)  eyeId      = eid;
    if (br != null)   brightness = br;
    if (anim != null) animEnabled = anim;
    if (cnt != null)  eyeCount   = cnt;
    if (link != null) slaveLinked = link == 1;
    final diag = await _readBytes(EyeUuids.chrLinkDiag);
    if (diag != null && diag.length >= 4) _parseLinkDiag(diag);
    final rcp = await _readBytes(EyeUuids.chrSlaveReceipt);
    if (rcp != null && rcp.length >= 6) {
      _parseReceipt(rcp);
    }
    final slotMask = await _readByte(EyeUuids.chrSlotStatus);
    if (slotMask != null) slotOccupiedMask = slotMask;
    final nm = await _readBytes(EyeUuids.chrDeviceName);
    if (nm != null && nm.isNotEmpty) deviceName = String.fromCharCodes(nm);
  }

  void _parseReceipt(List<int> v) {
    slaveReceiptSlot    = v[0];
    slaveUniqueReceived = v[1] | (v[2] << 8);
    slaveTotalChunks    = v[3] | (v[4] << 8);
    slaveReRequestRound = v[5];
  }

  void _parseLinkDiag(List<int> v) {
    linkState = v[0];
    silenceMs = v[1] | (v[2] << 8);
    lossPct   = v[3];
    // Bytes 4/5 kamen erst spaeter dazu - aeltere Firmware sendet nur 4 Bytes.
    if (v.length >= 6) {
      masterChannel = v[4];
      slaveChannel  = v[5];
    }
  }

  /// Abonniert eine Characteristic, ohne dass ein Fehlschlag die ganze Verbindung
  /// reisst. Vorher brach ein einziges scheiterndes Abo `connectAndDiscover` ab -
  /// und die Fehlermeldung verriet nicht einmal, welches. Jetzt merken wir uns die
  /// betroffene UUID und machen weiter; die Diagnose zeigt sie an.
  Future<StreamSubscription<List<int>>?> _subscribe(
      Guid uuid, void Function(List<int>) onData) async {
    final c = _chars[uuid];
    if (c == null) return null;
    try {
      await c.setNotifyValue(true);
      return c.lastValueStream.listen(onData);
    } catch (e) {
      final short = uuid.str.length >= 8 ? uuid.str.substring(4, 8) : uuid.str;
      subscribeErrors.add(short);
      notifyListeners();
      return null;
    }
  }

  Future<void> _subscribeNotifies() async {
    subscribeErrors.clear();

    _subEyeId = await _subscribe(EyeUuids.chrEyeId, (v) {
      // 2 Bytes [Master, Slave]; aeltere Firmware meldet nur eines fuer beide.
      if (v.isEmpty) return;
      eyeId = v.length >= 2 ? [v[0], v[1]] : [v[0], v[0]];
      notifyListeners();
    });
    // Funk-Status live mitverfolgen (Master notifyt 1x/s).
    _subSlaveLink = await _subscribe(EyeUuids.chrSlaveLink, (v) {
      if (v.isNotEmpty) { slaveLinked = v[0] == 1; notifyListeners(); }
    });
    // ESP-NOW-Verbindungsqualitaet live (state / silence / loss).
    _subLinkDiag = await _subscribe(EyeUuids.chrLinkDiag, (v) {
      if (v.length >= 4) { _parseLinkDiag(v); notifyListeners(); }
    });
    _subSlaveReceipt = await _subscribe(EyeUuids.chrSlaveReceipt, (v) {
      if (v.length >= 6) { _parseReceipt(v); notifyListeners(); }
    });
    // chrSlotStatus wird nur EINMAL via _readAll gelesen - kein Notify-Subscribe,
    // weil das beim ESP zu BLE-Coex-Druck waehrend Forward gefuehrt hat.

    // --- Kopplung: ein Fund pro Notify (8 Bytes), Zustand als 9-Byte-Block ---
    _subPairFound = await _subscribe(EyeUuids.chrPairFound, (v) {
      if (v.length < 8) return;
      final mac = v.sublist(0, 6);
      if (pairingFound.any((f) => _macEq(f.mac, mac))) return;
      final rssi = v[6] > 127 ? v[6] - 256 : v[6];   // int8
      pairingFound.add(FoundSlave(
        mac, rssi, (v[7] & 0x01) != 0, (v[7] & 0x02) != 0));
      notifyListeners();
    });
    _subPairState = await _subscribe(EyeUuids.chrPairState, (v) {
      if (v.length < 9) return;
      _parsePairState(v);
      notifyListeners();
    });
    // Startwert des Kopplungs-Zustands, damit der Screen nicht bei Null beginnt.
    final cps = _chars[EyeUuids.chrPairState];
    if (cps != null) {
      try {
        final init = await cps.read();
        if (init.length >= 9) _parsePairState(init);
      } catch (_) {}
    }

    // --- Ausrichtung: einmal lesen, damit die Regler richtig starten ---
    final cg = _chars[EyeUuids.chrEyeGeom];
    if (cg != null) {
      try {
        final v = await cg.read();
        if (v.length >= 4) {
          eyeYOff = [_s8(v[0]), _s8(v[2])];
          eyeVisH = [v[1], v[3]];
        }
        // Versatz und Groesse kamen spaeter dazu und haengen hinten dran. Eine
        // aeltere Firmware antwortet mit vier Bytes - dann bleibt es bei den
        // Vorgaben, statt dass die Regler auf Null springen.
        if (v.length >= 8) {
          eyeXOff = [_s8(v[4]), _s8(v[6])];
          eyeZoom = [v[5], v[7]];
        }
      } catch (_) {}
    }

    // --- Bewegung: nur lesen, KEIN Abo. NimBLE haelt pro Verbindung nur begrenzt
    //     viele CCCD-Slots vor (Standard 8), und die waren bereits vergeben - ein
    //     neuntes Abo scheitert mit GATT_WRITE_NOT_PERMITTED und riss die ganze
    //     Verbindung mit. Den Stand holen wir nach jedem Schreibvorgang aktiv ab.
    await _readAnimCfg();
  }

  /// Holt den tatsaechlichen Stand aus der Firmware. Wichtig nach Voreinstellung,
  /// Werkseinstellung und nach jedem Setzen: die Firmware klemmt Werte auf gueltige
  /// Bereiche, und die Regler sollen zeigen, was das Auge wirklich macht.
  Future<void> _readAnimCfg() async {
    final ca = _chars[EyeUuids.chrAnimCfg];
    if (ca == null) return;
    try {
      final v = await ca.read();
      if (v.length >= AnimCfg.byteLength) {
        animCfg = AnimCfg.fromBytes(v);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Byte als vorzeichenbehaftet lesen - y_off kann negativ sein.
  int _s8(int b) => b > 127 ? b - 256 : b;

  // ===== Augen-Ausrichtung und Bewegung =====

  // Drossel fuer Vorschau-Sendungen. Ein gezogener Regler feuert ~60 Ereignisse pro
  // Sekunde; jedes davon loest am Master einen Funk-Weiterleitung aus. Ungedrosselt
  // staut sich der BLE-Stack auf und die Bedienung ruckelt. Der Endwert geht beim
  // Loslassen immer raus, ungedrosselt.
  static const Duration _previewGap = Duration(milliseconds: 250);
  DateTime _lastGeomPreview = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAnimPreview = DateTime.fromMillisecondsSinceEpoch(0);

  bool _throttled(DateTime last) => DateTime.now().difference(last) < _previewGap;

  /// Setzt die Ausrichtung eines Auges. [target] 0 = Master, 1 = Slave.
  /// [persist] false = nur Vorschau (waehrend des Regler-Ziehens, kein Flash-Schreiben),
  /// true = uebernehmen und speichern.
  ///
  /// Schreibt sechs Bytes: die vier alten plus xOff und zoom ANGEHAENGT. Eine
  /// aeltere Firmware liest nur die ersten vier und laesst Versatz und Groesse
  /// unveraendert - die App bleibt damit auch an einem noch nicht geflashten
  /// Auge bedienbar.
  Future<void> setEyeGeom(int target, int yOff, int visH,
                          {int? xOff, int? zoom, bool persist = false}) async {
    final c = _chars[EyeUuids.chrEyeGeom];
    if (c == null || locked) return;
    final x = xOff ?? eyeXOff[target];
    final z = zoom ?? eyeZoom[target];
    eyeYOff[target] = yOff;
    eyeVisH[target] = visH;
    eyeXOff[target] = x;
    eyeZoom[target] = z;
    notifyListeners();
    if (!persist) {
      if (_throttled(_lastGeomPreview)) return;
      _lastGeomPreview = DateTime.now();
    }
    await c.write([target, yOff & 0xFF, visH & 0xFF, persist ? 1 : 0,
                   x & 0xFF, z & 0xFF],
        withoutResponse: false);
  }

  /// Setzt Ausrichtung zurueck: Auge mittig, nichts abgedeckt, Groesse 100 %.
  Future<void> resetEyeGeom(int target) =>
      setEyeGeom(target, 0, 240, xOff: 0, zoom: 100, persist: true);

  Future<void> _animCmd(int cmd, int arg, [Uint8List? payload]) async {
    final c = _chars[EyeUuids.chrAnimCfg];
    if (c == null || locked) return;
    await c.write(<int>[cmd, arg, ...?payload], withoutResponse: false);
  }

  Future<void> setAnimCfg(AnimCfg cfg, {bool persist = false}) async {
    animCfg = cfg;
    notifyListeners();
    if (!persist) {
      if (_throttled(_lastAnimPreview)) return;
      _lastAnimPreview = DateTime.now();
    }
    await _animCmd(persist ? 1 : 0, 0, cfg.toBytes());
    // Beim Speichern den geklemmten Stand zurueckholen. Waehrend des Ziehens nicht -
    // das waere ein zusaetzlicher Funkweg pro Reglerbewegung.
    if (persist) await _readAnimCfg();
  }

  /// Voreinstellung anwenden (0 ruhig, 1 normal, 2 lebhaft). Die Werte selbst liegen
  /// in der Firmware; anschliessend holen wir den neuen Stand ab.
  Future<void> applyAnimPreset(int index) async {
    await _animCmd(3, index);
    await _readAnimCfg();
  }

  /// Zurueck auf die Werkseinstellung der Firmware.
  Future<void> resetAnimCfg() async {
    await _animCmd(2, 0);
    await _readAnimCfg();
  }

  /// Hilfslinien an den Kanten des sichtbaren Bandes ein-/ausblenden - auf beiden Augen.
  Future<void> setEyeGuides(bool on) => _animCmd(4, on ? 1 : 0);

  void _parsePairState(List<int> v) {
    pairingState = v[0];
    boundPairId  = v[1];
    pairingError = v[2];
    boundMac     = v.sublist(3, 9);
  }

  bool _macEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ===== Kopplung =====

  Future<void> _pairCmd(int cmd, [List<int>? mac]) async {
    final c = _chars[EyeUuids.chrPairCtrl];
    if (c == null || locked) return;
    await c.write(<int>[cmd, ...?mac], withoutResponse: false);
  }

  /// Startet die Suche nach koppelbaren Slaves. Der Master wechselt dafuer auf
  /// Kanal 6 und funkt 60 s lang; danach laeuft der Modus von selbst aus.
  Future<void> startPairingScan() async {
    pairingFound.clear();
    pairingError = 0;
    notifyListeners();
    await _pairCmd(0x01);
  }

  Future<void> stopPairingScan()            => _pairCmd(0x02);
  /// Laesst das Auge 5 s blinken - so erkennt der Nutzer, welcher Slave gemeint ist.
  Future<void> identifySlave(List<int> mac) => _pairCmd(0x03, mac);
  /// Laesst den MASTER blinken. Braucht ein eigenes Kommando, weil die App die
  /// MAC des Masters gar nicht kennt.
  Future<void> identifySelf()               => _pairCmd(0x07);
  Future<void> bindSlave(List<int> mac)     => _pairCmd(0x04, mac);
  Future<void> unbindOwn()                  => _pairCmd(0x05);
  /// Nur mit Admin-Code: loest die Bindung eines fremden Slaves (defekter Master).
  Future<void> unbindAdmin(List<int> mac)   => _pairCmd(0x06, mac);

  Future<int?> _readByte(Guid uuid) async {
    final c = _chars[uuid];
    if (c == null) return null;
    try {
      final v = await c.read();
      return v.isNotEmpty ? v[0] : null;
    } catch (e) { return null; }
  }

  Future<List<int>?> _readBytes(Guid uuid) async {
    final c = _chars[uuid];
    if (c == null) return null;
    try { return await c.read(); } catch (e) { return null; }
  }

  /// Schreibt einen Wert, der je Auge getrennt ist.
  ///
  /// [target] 0 = Master, 1 = Slave, 2 = beide. Bei "beide" geht EIN Byte raus, genau
  /// wie frueher - das versteht auch ein Auge mit aelterer Firmware.
  Future<bool> _writePair(Guid id, int target, int value, List<int> state) async {
    if (locked) return false;   // Firmware ignoriert den Write ohnehin
    final c = _chars[id];
    if (c == null) return false;
    await c.write(target == kBeide ? [value] : [target, value], withoutResponse: false);
    if (target == kBeide) {
      state[kMaster] = value;
      state[kSlave]  = value;
    } else {
      state[target] = value;
    }
    notifyListeners();
    return true;
  }

  Future<void> setEyeId(int target, int id) =>
      _writePair(EyeUuids.chrEyeId, target, id, eyeId);

  /// Setzt die Display-Helligkeit beider Augen (0..255). Der Master stellt sein
  /// eigenes Backlight und schiebt den Wert per ConfigMsg an den Slave weiter.
  ///
  /// War frueher ausgebaut mit der Begruendung, es funktioniere auf dem ESP32
  /// nicht zuverlaessig. Die eigentliche Ursache lag in der Firmware: ledcAttach()
  /// lief vor tft.begin(), und TFT_eSPI::init() reisst den Backlight-Pin danach
  /// als normalen GPIO an sich - die PWM war damit wirkungslos. Seit die
  /// Zuordnung nach tft.begin() passiert, geht es.
  Future<void> setBrightness(int target, int value) =>
      _writePair(EyeUuids.chrBrightness, target, value.clamp(0, 255), brightness);

  Future<void> setAnimEnabled(int target, bool en) =>
      _writePair(EyeUuids.chrAnimEn, target, en ? 1 : 0, animEnabled);

  // setPairId entfernt - PAIR_ID ist read-only und wird nur im Sketch-Code geaendert.

  // === Cloud-Eye Upload via BLE Chunks ===
  // Protocol-Header (6 Byte): cmd, slot, idx_lo, idx_hi, total_lo, total_hi
  // Payload: max 238 Byte data
  // Master quittiert nicht jeden Chunk - wir nutzen WRITE-WITH-RESPONSE damit
  // die BLE-Stack-Bestaetigung Flow-Control macht.
  //
  // Die Groesse ist nicht mehr fest, sondern ergibt sich aus der beim Verbinden
  // ausgehandelten MTU (siehe connectAndDiscover). 238 war der alte feste Wert und
  // bleibt die Untergrenze; 503 ist das Maximum bei MTU 512.
  static const int _kChunkSizeMin = 238;
  static const int _kChunkSizeMax = 503;
  int _chunkSize = _kChunkSizeMin;

  Future<bool> uploadEye(int slot, Uint8List jpegData,
                          {void Function(int sent, int total)? onProgress}) async {
    if (locked) return false;
    final c = _chars[EyeUuids.chrEyeUpload];
    if (c == null) return false;
    if (slot < 0 || slot >= kCloudSlotCount) return false;
    // Keine feste Groesse mehr - ein JPEG ist beliebig lang. Geprueft wird
    // stattdessen, dass es ueberhaupt ein vollstaendiges JPEG ist und den
    // Deckel einhaelt: die Firmware bricht einen zu grossen Upload sonst
    // mitten in der Uebertragung ab, und ein unvollstaendiges Bild wuerde als
    // Geisterbild im Slot zurueckbleiben.
    if (!isCompleteJpeg(jpegData)) {
      throw Exception('Kein vollstaendiges JPEG (SOI/EOI fehlen)');
    }
    if (jpegData.length > kEyeJpegMax) {
      throw Exception('JPEG zu gross: ${jpegData.length} Bytes, erlaubt sind $kEyeJpegMax');
    }
    final total = (jpegData.length + _chunkSize - 1) ~/ _chunkSize;
    for (int i = 0; i < total; i++) {
      final start = i * _chunkSize;
      final end   = (start + _chunkSize) > jpegData.length
                    ? jpegData.length
                    : (start + _chunkSize);
      final payload = <int>[
        0x01, slot,
        i & 0xFF, (i >> 8) & 0xFF,
        total & 0xFF, (total >> 8) & 0xFF,
        ...jpegData.sublist(start, end),
      ];
      await c.write(payload, withoutResponse: false);
      onProgress?.call(i + 1, total);
    }
    // Commit-Marker
    await c.write([0x02, slot, 0, 0, 0, 0], withoutResponse: false);
    // Mask lokal setzen - Master notifyt nicht (BLE-Coex), wir wollen aber die
    // Slot-Status-Anzeige aktuell halten ohne Reconnect.
    slotOccupiedMask |= (1 << slot);
    notifyListeners();
    return true;
  }

  /// Stoesst die Funk-Weitergabe eines bereits hochgeladenen Auges an den Slave neu an.
  ///
  /// Noetig, wenn die Weitergabe abgebrochen ist - etwa weil eines der Augen neu
  /// gestartet hat. Der Master hat das Bild dann vollstaendig liegen, sein
  /// Weitergabe-Zustand lebt aber nur im RAM und ist nach einem Neustart weg. Ohne
  /// dieses Kommando muesste man die 200 KB erneut vom Handy schicken, nur um eine
  /// Funkuebertragung auszuloesen, die der Master allein erledigen kann.
  ///
  /// Der Master lehnt ab, wenn der Slot leer oder die Datei unvollstaendig ist.
  Future<void> reforwardEye(int slot) async {
    if (locked) return;
    final c = _chars[EyeUuids.chrEyeUpload];
    if (c == null) return;
    if (slot < 0 || slot >= kCloudSlotCount) return;
    await c.write([0x04, slot, 0, 0, 0, 0], withoutResponse: false);
  }

  /// Loescht den Cloud-Slot auf Master + Slave.
  Future<void> deleteEye(int slot) async {
    if (locked) return;
    final c = _chars[EyeUuids.chrEyeUpload];
    if (c == null) return;
    if (slot < 0 || slot >= kCloudSlotCount) return;
    await c.write([0x03, slot, 0, 0, 0, 0], withoutResponse: false);
    // Mask lokal nachfuehren - Master notifyt nicht (BLE-Coex), wir muessten sonst
    // bis zum naechsten Connect warten bis "belegt" verschwindet.
    slotOccupiedMask &= ~(1 << slot);
    notifyListeners();
  }

}
