import 'package:flutter/material.dart';

import '../ble_service.dart';
import '../theme.dart';

/// Gestaltet die Bewegung des Augenpaares.
///
/// Die elf Rohwerte aus der Firmware sagen niemandem etwas, der den Quelltext nicht
/// kennt. Deshalb steht vorne, was man wirklich meint: wie lebhaft, wie weit, wie oft.
/// Jeder dieser drei Regler verstellt mehrere Rohwerte sinnvoll zusammen. Wer doch an
/// eine Feinheit will, klappt den Expertenbereich auf.
///
/// Die Werte gelten für **beide** Augen: sie müssen identisch rechnen, sonst blinzeln
/// sie nicht mehr gleichzeitig. Werkswerte und Voreinstellungen liegen in der Firmware.
class MotionScreen extends StatefulWidget {
  final EyeBle ble;
  const MotionScreen({super.key, required this.ble});
  @override
  State<MotionScreen> createState() => _MotionScreenState();
}

// --- Abbildung der drei einfachen Regler auf die Rohwerte -------------------
// Bewusst monoton, damit sie sich eindeutig zurueckrechnen laesst: verstellt man im
// Expertenbereich einen Rohwert, wandert der einfache Regler mit. So gibt es keinen
// zweiten Zustand, der auseinanderlaufen koennte.
double _inv(num v, num at0, num at100) =>
    ((v - at0) / (at100 - at0) * 100).clamp(0, 100).toDouble();
int _map(double t, num at0, num at100) =>
    (at0 + (at100 - at0) * t / 100).round();

class _MotionScreenState extends State<MotionScreen> {
  bool _expert = false;
  AnimCfg? _preview;

  AnimCfg? get _cfg => _preview ?? widget.ble.animCfg;

  @override
  void initState() {
    super.initState();
    // Die Bewegungs-Einstellungen kommen erst hier vom Auge: sie werden nicht
    // mehr beim Verbinden mitgelesen, damit das Anmelden nicht auf Werte wartet,
    // die nur dieser Bildschirm anzeigt (siehe EyeBle.ensureGeom).
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.ble.ensureGeom());
  }

  void _live(AnimCfg next) {
    setState(() => _preview = next);
    widget.ble.setAnimCfg(next, persist: false);
  }

  /// Vorschau erst loslassen, wenn der Wert wirklich gespeichert ist - sonst springt
  /// der Regler kurz auf den alten Stand zurueck.
  Future<void> _commit(AnimCfg c) async {
    setState(() => _preview = c);
    await widget.ble.setAnimCfg(c, persist: true);
    if (mounted) setState(() => _preview = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ble,
      builder: (context, _) {
        final ble = widget.ble;
        final cfg = _cfg;

        if (cfg == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Bewegung & Blinzeln')),
            body: const Center(child: Text('Lese Einstellungen vom Auge ...')),
          );
        }

        final tempo = _inv(cfg.holdMs, 8000, 1500);
        // Seitlich reicht der Regler weiter als vertikal: im Maskenschlitz ist nach
        // links und rechts viel mehr zu sehen, dieselbe Pixelzahl wirkt dort also
        // schwaecher. Das obere Ende sind 40 px.
        //
        // Seit die Bilder 360 px breit sind, betraegt der Ueberschuss ueber den
        // 240er-Bildschirm 60 px statt 40 - die Grenze hier bleibt trotzdem bei 40.
        // Die gewonnenen 20 px sind bewusst dem seitlichen Versatz zugedacht
        // (Augen ausrichten, Schritt 3). Wer sie hier verbraucht, nimmt sie dort
        // weg: die Firmware klemmt die Summe aus Ausschlag und Versatz auf den
        // vorhandenen Ueberhang, damit am Rand keine Luecke aufreisst.
        final range = _inv(cfg.ampX, 10, 40);
        final blink = _inv(cfg.blinkWindowMs, 12000, 2000);

        return Scaffold(
          appBar: AppBar(title: const Text('Bewegung & Blinzeln')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Row(
                children: [
                  _preset(ble, 0, 'Ruhig'),
                  const SizedBox(width: 8),
                  _preset(ble, 1, 'Normal'),
                  const SizedBox(width: 8),
                  _preset(ble, 2, 'Lebhaft'),
                ],
              ),
              const SizedBox(height: 24),

              _dial('Tempo', 'Wie oft und wie schnell das Auge den Blick wechselt',
                  tempo, 'traege', 'quirlig',
                  (t) => cfg.copyWith(
                        holdMs: _map(t, 8000, 1500),
                        moveMs: _map(t, 700, 200),
                      )),
              _dial('Bewegungsumfang', 'Wie weit der Blick vom Mittelpunkt abweicht',
                  range, 'knapp', 'weit',
                  (t) => cfg.copyWith(
                        ampX: _map(t, 10, 40),
                        ampY: _map(t, 4, 14),
                      )),
              _dial('Blinzeln', 'Wie haeufig das Auge zwinkert',
                  blink, 'selten', 'oft',
                  (t) => cfg.copyWith(blinkWindowMs: _map(t, 12000, 2000))),

              const Divider(height: 32),

              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt, color: kWarn),
                title: const Text('Auf Werkseinstellung zuruecksetzen'),
                onTap: ble.locked ? null : () {
                  _preview = null;
                  ble.resetAnimCfg();
                },
              ),

              // --- Expertenbereich: die Rohwerte, klar als solche gekennzeichnet ---
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: _expert,
                  onExpansionChanged: (v) => setState(() => _expert = v),
                  leading: const Icon(Icons.tune, color: Colors.white38),
                  title: const Text('Einzelwerte (Experten)',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Nur noetig, wenn die drei Regler nicht reichen',
                      style: TextStyle(fontSize: 12)),
                  children: [
                    const _Group('Bewegung'),
                    _raw(cfg, 'Verweildauer', cfg.holdMs.toDouble(), 500, 10000,
                        '${(cfg.holdMs / 1000).toStringAsFixed(1)} s',
                        (v) => cfg.copyWith(holdMs: v.round())),
                    _raw(cfg, 'Bewegungsdauer', cfg.moveMs.toDouble(), 80, 1500,
                        '${cfg.moveMs} ms', (v) => cfg.copyWith(moveMs: v.round())),
                    _raw(cfg, 'Blickrichtungen', cfg.posCount.toDouble(), 2, 5,
                        '${cfg.posCount}', (v) => cfg.copyWith(posCount: v.round()),
                        divisions: 3),
                    _raw(cfg, 'Ausschlag seitlich', cfg.ampX.toDouble(), 0, 40,
                        '${cfg.ampX} px', (v) => cfg.copyWith(ampX: v.round())),
                    _raw(cfg, 'Ausschlag vertikal', cfg.ampY.toDouble(), 0, 40,
                        '${cfg.ampY} px', (v) => cfg.copyWith(ampY: v.round())),
                    _raw(cfg, 'Schwung', cfg.arc.toDouble(), 0, 40,
                        '${cfg.arc}', (v) => cfg.copyWith(arc: v.round())),
                    _raw(cfg, 'Weichheit', cfg.ease.toDouble(), 0, 100,
                        '${cfg.ease}', (v) => cfg.copyWith(ease: v.round())),
                    const _Group('Blinzeln'),
                    _raw(cfg, 'Zeitfenster', cfg.blinkWindowMs.toDouble(), 1500, 20000,
                        '${(cfg.blinkWindowMs / 1000).toStringAsFixed(1)} s',
                        (v) => cfg.copyWith(blinkWindowMs: v.round())),
                    _raw(cfg, 'Zufahren', cfg.blinkCloseMs.toDouble(), 40, 600,
                        '${cfg.blinkCloseMs} ms', (v) => cfg.copyWith(blinkCloseMs: v.round())),
                    _raw(cfg, 'Geschlossen', cfg.blinkHoldMs.toDouble(), 0, 1500,
                        '${cfg.blinkHoldMs} ms', (v) => cfg.copyWith(blinkHoldMs: v.round())),
                    _raw(cfg, 'Aufgehen', cfg.blinkOpenMs.toDouble(), 40, 600,
                        '${cfg.blinkOpenMs} ms', (v) => cfg.copyWith(blinkOpenMs: v.round())),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Wird das Blinzeln laenger als sein Zeitfenster, hebt das Auge '
                        'das Fenster selbst an und meldet den korrigierten Wert zurueck.',
                        style: TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              const Text(
                'Gilt fuer beide Augen gemeinsam - nur so blinzeln sie gleichzeitig.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _preset(EyeBle ble, int index, String label) => Expanded(
        child: FilledButton.tonal(
          onPressed: ble.locked ? null : () {
            _preview = null;
            ble.applyAnimPreset(index);
          },
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
      );

  /// Einer der drei sprechenden Regler. Zeigt die Enden benannt statt beziffert -
  /// eine Zahl waere hier bedeutungslos, weil sie mehrere Rohwerte zugleich verstellt.
  Widget _dial(String title, String hint, double value, String low, String high,
      AnimCfg Function(double) build) {
    final locked = widget.ble.locked;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text(hint, style: const TextStyle(fontSize: 12, color: Colors.white38)),
          Slider(
            min: 0, max: 100,
            value: value,
            activeColor: kAccent,
            onChanged: locked ? null : (v) => _live(build(v)),
            onChangeEnd: (v) => _commit(build(v)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(low, style: const TextStyle(fontSize: 11, color: Colors.white30)),
                Text(high, style: const TextStyle(fontSize: 11, color: Colors.white30)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _raw(AnimCfg cfg, String title, double value, double min, double max,
      String label, AnimCfg Function(double) build, {int? divisions}) {
    final locked = widget.ble.locked;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 118,
            child: Text(title, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              min: min, max: max, divisions: divisions,
              value: value.clamp(min, max),
              activeColor: kAccent,
              onChanged: locked ? null : (v) => _live(build(v)),
              onChangeEnd: (v) => _commit(build(v)),
            ),
          ),
          SizedBox(
            width: 54,
            child: Text(label,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String text;
  const _Group(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 11, letterSpacing: 1.2, color: kAccentGlow,
                fontWeight: FontWeight.w700)),
      );
}
