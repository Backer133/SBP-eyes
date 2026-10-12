import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble_service.dart';
import '../theme.dart';
import 'home.dart';

class DiscoveryScreen extends StatefulWidget {
  final EyeBle ble;
  const DiscoveryScreen({super.key, required this.ble});
  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen>
    with SingleTickerProviderStateMixin {
  final List<ScanResult> _results = [];
  /// true, wenn der zuletzt abgeschlossene Suchlauf nichts gefunden hat.
  ///
  /// Wichtig fuer die Unterscheidung "kein Auge da" gegen "Android hat den Scanner
  /// gedrosselt": Nach zu vielen Scan-Starts liefert Android stumm keine Treffer mehr.
  /// Da die Liste jetzt bei jedem Suchlauf neu aufgebaut wird, saehe beides gleich aus -
  /// deshalb der Hinweis in der Oberflaeche.
  bool _emptyScan = false;
  StreamSubscription<List<ScanResult>>? _subScan;
  StreamSubscription<bool>? _subScanning;
  bool _scanning = false;   // vom echten BLE-Stack (FlutterBluePlus.isScanning)
  bool _starting = false;   // _scan() laeuft gerade (Stop/Debounce/Start)
  String? _error;
  String? _connectingId;   // remoteId des Geraets, zu dem gerade verbunden wird
  DateTime _lastScanStart = DateTime.fromMillisecondsSinceEpoch(0);
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    // Scan-Status direkt vom BLE-Stack ableiten: bleibt bis zum Timeout true, damit
    // der "Neu suchen"-Button waehrend eines laufenden Scans wirklich gesperrt ist
    // (verhindert das schnelle Neu-Starten, das Android drosselt).
    _subScanning = FlutterBluePlus.isScanning.listen((s) {
      if (!mounted) return;
      setState(() {
        // Endet ein Suchlauf ohne einen einzigen Treffer, ist das mehrdeutig: entweder
        // ist wirklich kein Auge in Reichweite, oder Android hat den Scanner gedrosselt.
        // Beides sieht gleich aus, deshalb wird es in der Oberflaeche benannt statt
        // stillschweigend als "nichts da" dargestellt.
        if (_scanning && !s) _emptyScan = _results.isEmpty;
        _scanning = s;
      });
    });
    // Die Liste zeigt AUSSCHLIESSLICH die Treffer des laufenden Suchlaufs.
    //
    // onScanResults liefert ohnehin genau diese - der Stack leert seine Sammlung bei
    // jedem startScan(). Frueher wurden die Ergebnisse hier ueber alle Suchlaeufe
    // hinweg zusammengefuehrt, damit ein einmal gefundenes Auge nicht verschwindet,
    // wenn Android drosselt. Das hielt dafuer abgeschaltete Augen endlos in der Liste.
    //
    // Jetzt ist die Anzeige ehrlich, und der Drossel-Fall wird stattdessen benannt
    // (siehe _emptyScan).
    _subScan = FlutterBluePlus.onScanResults.listen((rs) {
      _results
        ..clear()
        ..addAll(rs);
      if (rs.isNotEmpty) _emptyScan = false;
      _results.sort((a, b) => b.rssi.compareTo(a.rssi));   // staerkstes Signal zuerst
      if (mounted) setState(() {});
    });
    _start();
  }

  Future<void> _start() async {
    await _ensurePermissions();
    if (!await FlutterBluePlus.isSupported) {
      setState(() => _error = "BLE wird auf diesem Geraet nicht unterstuetzt");
      return;
    }
    _scan();
  }

  Future<void> _ensurePermissions() async {
    if (Theme.of(context).platform == TargetPlatform.android) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    }
  }

  Future<void> _scan() async {
    if (_starting || _scanning) return;   // kein Doppelstart
    setState(() { _starting = true; _error = null; });
    try {
      // Eine noch offene Verbindung VOR dem Suchen trennen.
      //
      // Das Auge wirbt nur, solange niemand verbunden ist: die Firmware ruft
      // startAdvertising() erst wieder beim Trennen auf. Hing also ein früherer
      // Versuch, blieb die Verbindung offen — und der nächste Suchlauf fand
      // schlicht nichts mehr, obwohl das Auge einen halben Meter entfernt lag.
      //
      // Im Browser fällt das besonders auf, weil dort jeder Suchlauf den
      // Auswahldialog öffnet und eine leere Liste dadurch unübersehbar ist.
      if (widget.ble.connected || widget.ble.device != null) {
        await widget.ble.disconnect();
      }
      // Laufenden Scan sauber stoppen.
      if (FlutterBluePlus.isScanningNow) {
        try { await FlutterBluePlus.stopScan(); } catch (_) {}
      }
      // Mindestabstand zwischen Scan-Starts: Android sperrt den Scanner nach zu
      // vielen Starts (5 in 30 s) stumm. Der Gap haelt uns sicher darunter.
      final since = DateTime.now().difference(_lastScanStart);
      const minGap = Duration(seconds: 3);
      if (since < minGap) await Future.delayed(minGap - since);
      if (!mounted) return;
      _lastScanStart = DateTime.now();
      // Alte Treffer verwerfen - ab jetzt zaehlt nur, was DIESER Suchlauf findet.
      if (mounted) setState(() { _results.clear(); _emptyScan = false; });
      // onScanResults-Listener laeuft dauerhaft (siehe initState) -> Ergebnisse
      // werden gemerged, nicht geloescht.
      await FlutterBluePlus.startScan(
        withServices: [EyeUuids.svcEyeCtrl],
        timeout: const Duration(seconds: 8),
        androidUsesFineLocation: false,
        // Nur fuer den Browser, auf Android/iOS wirkungslos.
        //
        // Web Bluetooth gibt einer Seite ausschliesslich die Dienste frei, die sie
        // VORHER angemeldet hat - alles andere ist nach dem Verbinden einfach nicht
        // vorhanden. Angemeldet war bisher nur svcEyeCtrl, weshalb der
        // Diagnose-Dienst (Funk-Status, Verbindungsqualitaet, Upload-Quittungen)
        // im Browser fehlte.
        webOptionalServices: [EyeUuids.svcEyeCtrl, EyeUuids.svcDiag],
      );
    } catch (e) {
      if (mounted) setState(() => _error = "Scan-Fehler: $e");
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _connect(ScanResult r) async {
    setState(() => _connectingId = r.device.remoteId.str);
    try {
      await FlutterBluePlus.stopScan();
      await widget.ble.connectAndDiscover(r.device);
      if (!mounted) return;
      setState(() => _connectingId = null);
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HomeScreen(ble: widget.ble),
      ));
      // Zurueck von Home -> erneut scannen.
      if (mounted) _scan();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectingId = null;
        _error = "Verbindungs-Fehler: $e\n${_hintFor(e)}";
      });
    }
  }

  /// Uebersetzt die kryptischen GATT-Fehler in eine Handlungsanweisung.
  ///
  /// Der haeufigste Fall nach einem Firmware-Update: Android merkt sich fuer ein
  /// gebondetes Geraet die entdeckten Services samt Handle-Nummern. Kommen in der
  /// Firmware Characteristics dazu, verschieben sich die Handles - das Handy schreibt
  /// dann auf veraltete Adressen und faengt sich GATT_WRITE_NOT_PERMITTED ein. Die
  /// Firmware kann daran nichts aendern; das Handy muss die Kopplung vergessen.
  String _hintFor(Object e) {
    final s = e.toString();
    if (s.contains('WRITE_NOT_PERMITTED') ||
        s.contains('INSUFFICIENT_AUTH') ||
        s.contains('setNotifyValue')) {
      return '\nWahrscheinliche Ursache: Das Handy hat eine veraltete Geraete-'
             'Struktur gespeichert (nach einem Firmware-Update). Abhilfe: In den '
             'Bluetooth-Einstellungen des Handys das Augenpaar "entkoppeln" bzw. '
             '"Geraet vergessen", dann hier neu verbinden.';
    }
    return '';
  }

  @override
  void dispose() {
    _pulse.dispose();
    _subScan?.cancel();
    _subScanning?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            if (_error != null) _errorBar(_error!),
            Expanded(
              child: _results.isEmpty ? _emptyState() : _deviceList(),
            ),
          ],
        ),
      ),
      floatingActionButton: Builder(builder: (_) {
        final busy = _scanning || _starting;
        return FloatingActionButton.extended(
          onPressed: busy ? null : _scan,
          backgroundColor: busy ? kSurfaceHi : kAccent,
          icon: busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
              : const Icon(Icons.refresh, color: Colors.white),
          label: Text(busy ? 'Suche laeuft' : 'Neu suchen',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        );
      }),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: kAccent.withOpacity(.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.remove_red_eye, color: kAccentGlow),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('SBP Eye Settings',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              Text(
                _scanning
                    ? 'Suche nach Augenpaaren...'
                    : '${_results.length} Augenpaar${_results.length == 1 ? '' : 'e'} gefunden',
                style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.55)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorBar(String msg) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBad.withOpacity(.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBad.withOpacity(.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: kBad, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(color: kBad, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _radar(),
          const SizedBox(height: 28),
          Text(
            _scanning ? 'Suche Augenpaare...' : 'Keine Augenpaare gefunden',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _scanning
                  ? 'Augen einschalten und in der Naehe bleiben.'
                  : 'Stelle sicher, dass die Augen mit Strom versorgt sind, und tippe auf "Neu suchen".',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.5), height: 1.4),
            ),
          ),
          // Ein leerer Suchlauf ist mehrdeutig: kein Auge da, ODER Android hat den
          // Scanner gedrosselt (nach zu vielen Starts liefert er stumm nichts mehr).
          // Seit die Liste bei jedem Suchlauf neu aufgebaut wird, sieht beides gleich
          // aus - deshalb wird die zweite Moeglichkeit hier ausdruecklich genannt,
          // statt den User an eingeschalteten Augen zweifeln zu lassen.
          if (_emptyScan && !_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 20, 40, 0),
              child: Text(
                'Findet der naechste Suchlauf ebenfalls nichts, obwohl die Augen '
                'laufen: kurz warten und erneut suchen. Android sperrt den '
                'Bluetooth-Scanner voruebergehend, wenn zu schnell hintereinander '
                'gesucht wird.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12, height: 1.4,
                  color: Colors.white.withOpacity(.38),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Pulsierender Radar-Ring waehrend der Suche (statisch, wenn nicht gescannt).
  Widget _radar() {
    return SizedBox(
      width: 160, height: 160,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              if (_scanning) ...[
                _ring(_pulse.value),
                _ring((_pulse.value + 0.5) % 1.0),
              ],
              Container(
                width: 76, height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kAccent.withOpacity(.16),
                  border: Border.all(color: kAccent.withOpacity(.5), width: 2),
                ),
                child: Icon(
                  _scanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
                  color: kAccentGlow, size: 34,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ring(double t) {
    final size = 76 + t * 84;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: kAccent.withOpacity((1 - t) * 0.5)),
      ),
    );
  }

  Widget _deviceList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _deviceCard(_results[i]),
    );
  }

  Widget _deviceCard(ScanResult r) {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : (r.device.platformName.isNotEmpty ? r.device.platformName : 'Augenpaar');
    final connecting = _connectingId == r.device.remoteId.str;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: connecting ? null : () => _connect(r),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: kAccent.withOpacity(.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.remove_red_eye, color: kAccentGlow, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        SignalBars(r.rssi),
                        const SizedBox(width: 8),
                        Text('${r.rssi} dBm',
                            style: TextStyle(
                                fontSize: 12, color: Colors.white.withOpacity(.5))),
                      ],
                    ),
                    // Waehrend des Verbindens zeigen, WOBEI es gerade steht.
                    //
                    // Der Ladekreis allein sagte nichts: auf dem iPhone blieb der
                    // Bildschirm stehen, und niemand konnte sehen, ob es an den
                    // Diensten, am Lesen oder an den Abos lag.
                    if (connecting)
                      ListenableBuilder(
                        listenable: widget.ble,
                        builder: (_, __) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            widget.ble.connectStep.isEmpty
                                ? 'Verbinden...'
                                : widget.ble.connectStep,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: kAccentGlow.withOpacity(.85)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              connecting
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: kAccentGlow))
                  : Transform.rotate(
                      angle: -math.pi / 4,
                      child: Icon(Icons.arrow_forward, color: Colors.white.withOpacity(.4)),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
