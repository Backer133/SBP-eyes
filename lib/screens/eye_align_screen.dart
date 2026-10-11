import 'package:flutter/material.dart';

import '../ble_service.dart';
import '../theme.dart';

/// Richtet ein einzelnes Auge auf seine Maskenöffnung aus.
///
/// Die Bedienung folgt der tatsächlichen Situation: Man steht vor der Maske, hält das
/// Handy in einer Hand und schaut abwechselnd aufs Auge und aufs Display. Deshalb eine
/// Vorschau statt bloßer Zahlen, Schrittknöpfe neben jedem Regler, und die vier
/// Einstellungen als nummerierte Schritte statt als gleichwertige Kästen.
///
/// Jede Maske ist handgeschnitzt, die Werte gelten deshalb je Auge — anders als die
/// Bewegung, die für beide identisch sein muss.
///
/// Schritt 3 und 4 hängen zusammen: das Bild ragt nur begrenzt über den Displayrand
/// hinaus, und die Blickbewegung verbraucht davon schon ihren Ausschlag. Was für den
/// seitlichen Versatz übrig bleibt, nennt die Hinweiszeile unter Schritt 3 —
/// Hineinzoomen in Schritt 4 vergrößert diesen Spielraum.
class EyeAlignScreen extends StatefulWidget {
  final EyeBle ble;
  const EyeAlignScreen({super.key, required this.ble});
  @override
  State<EyeAlignScreen> createState() => _EyeAlignScreenState();
}

class _EyeAlignScreenState extends State<EyeAlignScreen> {
  int _target = 0;               // 0 = Master, 1 = Slave
  bool _guides = true;           // beim Öffnen an: man will die Kante sehen
  int? _previewYOff;
  int? _previewVisH;
  int? _previewXOff;
  int? _previewZoom;

  static const int _minY = -60, _maxY = 60;
  static const int _minH = 60,  _maxH = 240;
  static const int _minX = -40, _maxX = 40;
  static const int _minZ = 100, _maxZ = 125;

  /// Breite des eigentlichen Augen-Inhalts und des Displays in Pixel.
  ///
  /// Das Bild ist 360 px breit, der Inhalt aber nur 280 — außen liegen 40 px
  /// fortgesetzte Randpixel, damit beim Verschieben keine harte Kante entsteht.
  /// Dauerhaft sichtbar werden darf dieser Streifen nicht: wo eine Ader die
  /// Inhaltskante kreuzt, wird sie darin zu einem Strich gezogen. Der nutzbare
  /// Versatz misst sich deshalb an der Inhaltskante, nicht an der Bildkante.
  /// Muss zu EYE_CONTENT_W und screenWidth in der Firmware passen.
  static const int _contentW = 280;
  static const int _screenPx = 240;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.ble.setEyeGuides(true));
  }

  @override
  void dispose() {
    // Hilfslinien nie stehen lassen - ein grüner Strich im Gesicht fällt später auf.
    widget.ble.setEyeGuides(false);
    super.dispose();
  }

  int _yOff(EyeBle b) => _previewYOff ?? b.eyeYOff[_target];
  int _visH(EyeBle b) => _previewVisH ?? b.eyeVisH[_target];
  int _xOff(EyeBle b) => _previewXOff ?? b.eyeXOff[_target];
  int _zoom(EyeBle b) => _previewZoom ?? b.eyeZoom[_target];

  void _send(EyeBle b, {required bool persist}) =>
      b.setEyeGeom(_target, _yOff(b), _visH(b),
                   xOff: _xOff(b), zoom: _zoom(b), persist: persist);

  void _stepY(EyeBle b, int delta) {
    setState(() => _previewYOff = (_yOff(b) + delta).clamp(_minY, _maxY));
    _send(b, persist: true);
    _previewYOff = null;
  }

  void _stepH(EyeBle b, int delta) {
    setState(() => _previewVisH = (_visH(b) + delta).clamp(_minH, _maxH));
    _send(b, persist: true);
    _previewVisH = null;
  }

  void _stepX(EyeBle b, int delta) {
    setState(() => _previewXOff = (_xOff(b) + delta).clamp(_minX, _maxX));
    _send(b, persist: true);
    _previewXOff = null;
  }

  void _stepZ(EyeBle b, int delta) {
    setState(() => _previewZoom = (_zoom(b) + delta).clamp(_minZ, _maxZ));
    _send(b, persist: true);
    _previewZoom = null;
  }

  String _yLabel(int v) {
    if (v == 0) return 'Mitte';
    return v < 0 ? '${-v} nach oben' : '$v nach unten';
  }

  String _xLabel(int v) {
    if (v == 0) return 'Mitte';
    return v < 0 ? '${-v} nach links' : '$v nach rechts';
  }

  /// Wie viel seitlicher Versatz bei der aktuellen Größe wirklich ankommt.
  ///
  /// Der Inhalt deckt das Display nur um (Inhalt·Zoom − Display)/2 je Seite
  /// über — bei 100 % sind das 20 px, bei 125 % schon 55. Weiter verschoben
  /// käme der fortgesetzte Rand ins Bild und die Adern würden zu Strichen
  /// gezogen. Die Firmware klemmt genau darauf; ohne diese Zeile wirkte ein
  /// Regler, der bis 40 geht, aber bei 20 stehen bleibt, wie ein Fehler.
  ///
  /// Die Blickbewegung zählt hier bewusst NICHT mit: sie darf kurz in den
  /// fortgesetzten Rand fahren (das war schon immer so und fällt im
  /// Vorbeifahren nicht auf), nur der Versatz ist ein Dauerzustand.
  int _xBudget(EyeBle b) {
    final contentHalf = (_contentW * _zoom(b)) ~/ 100 ~/ 2;
    final free = contentHalf - _screenPx ~/ 2;
    return free < 0 ? 0 : free;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ble,
      builder: (context, _) {
        final ble = widget.ble;
        final yOff = _yOff(ble);
        final visH = _visH(ble);
        final xOff = _xOff(ble);
        final zoom = _zoom(ble);
        final budget = _xBudget(ble);

        return Scaffold(
          appBar: AppBar(title: const Text('Augen ausrichten')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              // --- Auswahl + Blinken in einer Zeile: "welches Auge stelle ich ein" ---
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Master')),
                        ButtonSegment(value: 1, label: Text('Slave')),
                      ],
                      selected: {_target},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() {
                        _target = s.first;
                        _previewYOff = null;
                        _previewVisH = null;
                        _previewXOff = null;
                        _previewZoom = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: ble.locked ? null : _identify,
                    icon: const Icon(Icons.lightbulb_outline),
                    tooltip: 'Dieses Auge blinken lassen',
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // --- Vorschau: macht aus zwei Zahlen ein Bild ---
              Center(
                child: SizedBox(
                  width: 150, height: 150,
                  child: CustomPaint(
                    // xOff GEKLEMMT: die Vorschau soll zeigen, was das Gerät
                    // tatsächlich tut. Ungeklemmt stünde das Auge hier doppelt
                    // so weit außen wie in Wirklichkeit, sobald der Regler über
                    // den wirksamen Bereich hinaus gestellt ist.
                    painter: _EyePreview(
                      yOff: yOff, visH: visH, zoom: zoom,
                      xOff: xOff.clamp(-budget, budget),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              _step(
                number: '1',
                title: 'Auge mittig setzen',
                hint: 'Bis die Pupille mitten im Ausschnitt sitzt',
                value: _yLabel(yOff),
                raw: '$yOff px',
                sliderValue: yOff.toDouble(),
                min: _minY.toDouble(), max: _maxY.toDouble(),
                onChanged: (v) { setState(() => _previewYOff = v.round()); _send(ble, persist: false); },
                onChangeEnd: (v) { _previewYOff = v.round(); _send(ble, persist: true); _previewYOff = null; },
                onMinus: () => _stepY(ble, -2),
                onPlus:  () => _stepY(ble,  2),
              ),

              _step(
                number: '2',
                title: 'Ausschnitt anpassen',
                hint: 'Bis die dunklen Ränder hinter dem Holz verschwinden',
                value: '${(visH * 100 / 240).round()} % des Displays',
                raw: '$visH px',
                sliderValue: visH.toDouble(),
                min: _minH.toDouble(), max: _maxH.toDouble(),
                onChanged: (v) { setState(() => _previewVisH = v.round()); _send(ble, persist: false); },
                onChangeEnd: (v) { _previewVisH = v.round(); _send(ble, persist: true); _previewVisH = null; },
                onMinus: () => _stepH(ble, -2),
                onPlus:  () => _stepH(ble,  2),
              ),

              _step(
                number: '3',
                title: 'Auge seitlich ausrichten',
                hint: budget == 0
                    ? 'Bei $zoom % Größe bleibt seitlich kein Spielraum — '
                      'in Schritt 4 etwas größer stellen'
                    : 'Bis die Pupille waagrecht mittig sitzt. Wirksam sind '
                      '±$budget px — weiter würde der Bildrand sichtbar',
                value: _xLabel(xOff),
                raw: '$xOff px',
                sliderValue: xOff.toDouble(),
                min: _minX.toDouble(), max: _maxX.toDouble(),
                onChanged: (v) { setState(() => _previewXOff = v.round()); _send(ble, persist: false); },
                onChangeEnd: (v) { _previewXOff = v.round(); _send(ble, persist: true); _previewXOff = null; },
                onMinus: () => _stepX(ble, -2),
                onPlus:  () => _stepX(ble,  2),
              ),

              _step(
                number: '4',
                title: 'Augengröße',
                hint: 'Größer wirkende Pupille — schafft zugleich Spielraum '
                      'für Schritt 3',
                value: '$zoom %',
                raw: '$zoom %',
                sliderValue: zoom.toDouble(),
                min: _minZ.toDouble(), max: _maxZ.toDouble(),
                onChanged: (v) { setState(() => _previewZoom = v.round()); _send(ble, persist: false); },
                onChangeEnd: (v) { _previewZoom = v.round(); _send(ble, persist: true); _previewZoom = null; },
                onMinus: () => _stepZ(ble, -5),
                onPlus:  () => _stepZ(ble,  5),
              ),

              const SizedBox(height: 8),
              const Divider(),

              // --- Aktionszeile: Werkzeuge, keine eigenen Karten ---
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.straighten, color: kAccentGlow),
                title: const Text('Hilfslinien am Auge'),
                subtitle: const Text('Markiert die Kanten des Ausschnitts'),
                value: _guides,
                activeColor: kAccent,
                onChanged: (v) { setState(() => _guides = v); ble.setEyeGuides(v); },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt, color: kWarn),
                title: const Text('Auf Mitte zuruecksetzen'),
                subtitle: Text('Nur ${_target == 0 ? "Master" : "Slave"} - '
                               'das andere Auge bleibt unveraendert'),
                onTap: ble.locked ? null : () {
                  _previewYOff = null;
                  _previewVisH = null;
                  _previewXOff = null;
                  _previewZoom = null;
                  ble.resetEyeGeom(_target);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _identify() async {
    // Frueher zeigte der Master hier nur eine Textmeldung - beim Einbau in die Maske
    // braucht man das Blinken aber auf beiden Augen gleichermassen.
    if (_target == 0) {
      await widget.ble.identifySelf();
    } else if (widget.ble.isBound) {
      await widget.ble.identifySlave(widget.ble.boundMac);
    }
  }

  Widget _step({
    required String number,
    required String title,
    required String hint,
    required String value,
    required String raw,
    required double sliderValue,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    final locked = widget.ble.locked;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Schrittnummer statt Icon: zeigt die Reihenfolge, die sonst niemand kennt.
              Container(
                width: 22, height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kAccent.withOpacity(.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(number,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: kAccentGlow)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              Text(value, style: const TextStyle(color: kAccentGlow, fontSize: 13)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 2),
            child: Text(hint,
                style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ),
          Row(
            children: [
              IconButton(
                onPressed: locked ? null : onMinus,
                icon: const Icon(Icons.remove),
                tooltip: 'Feiner: 2 weniger',
              ),
              Expanded(
                child: Slider(
                  min: min, max: max,
                  value: sliderValue.clamp(min, max),
                  activeColor: kAccent,
                  onChanged: locked ? null : onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
              IconButton(
                onPressed: locked ? null : onPlus,
                icon: const Icon(Icons.add),
                tooltip: 'Feiner: 2 mehr',
              ),
              SizedBox(
                width: 46,
                child: Text(raw,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: Colors.white30)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Schematische Vorschau des Auges: Kreis = Display, dunkle Balken = vom Holz verdeckt,
/// Punkt = Pupillenlage. Ersetzt die Vorstellungskraft, die zwei Pixelwerte sonst
/// verlangen würden.
class _EyePreview extends CustomPainter {
  final int yOff;
  final int visH;
  final int xOff;
  final int zoom;      // Prozent
  const _EyePreview({required this.yOff, required this.visH,
                     required this.xOff, required this.zoom});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final scale = size.width / 240.0;      // Display ist 240 px breit

    // Displayfläche
    canvas.drawCircle(c, r, Paint()..color = kSurfaceHi);

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));

    // Auge: heller Kreis, um yOff und xOff verschoben, mit zoom skaliert.
    // xOff kommt vom Aufrufer schon geklemmt an, damit die Vorschau das Gerät
    // abbildet und nicht die Reglerstellung.
    final z = zoom / 100.0;
    final eyeC = Offset(r + xOff * scale, r + yOff * scale);
    canvas.drawCircle(eyeC, r * 0.62 * z, Paint()..color = const Color(0xFFDCE3F0));
    canvas.drawCircle(eyeC, r * 0.26 * z, Paint()..color = kAccent);

    // Abdeckung oben und unten - genau die Balken, die auch das Gerät zeichnet
    final half = visH / 2.0;
    final topH    = ((120 + yOff - half) * scale).clamp(0.0, size.height);
    final bottomH = ((120 - yOff - half) * scale).clamp(0.0, size.height);
    final cover = Paint()..color = const Color(0xEE07080C);
    if (topH > 0)    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, topH), cover);
    if (bottomH > 0) {
      canvas.drawRect(
          Rect.fromLTWH(0, size.height - bottomH, size.width, bottomH), cover);
    }

    // Kanten des sichtbaren Bandes markieren
    final edge = Paint()
      ..color = kGood
      ..strokeWidth = 1.5;
    if (topH > 0)    canvas.drawLine(Offset(0, topH), Offset(size.width, topH), edge);
    if (bottomH > 0) {
      canvas.drawLine(Offset(0, size.height - bottomH),
                      Offset(size.width, size.height - bottomH), edge);
    }
    canvas.restore();

    canvas.drawCircle(c, r,
        Paint()..color = Colors.white10..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _EyePreview old) =>
      old.yOff != yOff || old.visH != visH ||
      old.xOff != xOff || old.zoom != zoom;
}
