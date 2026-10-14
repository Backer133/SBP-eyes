// PNG/JPG -> 360x360 JPEG fuer den Cloud-Eye-Upload via BLE.
//
// Zielgeraet: ESP32-S3-LCD-1.28 (GC9A01, 240x240-Display). Die Bilder sind bewusst
// oversized: zentriert ragen sie ueber den Displayrand, damit weder Ausrichtung noch
// Blickbewegung einen leeren Rand erzeugen - 1:1 wie die eingebauten Augen.
//
// WARUM 360 UND NICHT MEHR 320: Der Ueberhang betraegt (360-240)/2 = 60 px je Seite.
// Davon verbraucht die Blickbewegung 40 px (amp_x), die restlichen 20 px stehen fuer
// den seitlichen Versatz zur Verfuegung. Mit 320 px waren es nur 40 px Ueberhang -
// die Bewegung brauchte sie komplett, fuer einen Versatz blieb kein Pixel.
//
// WARUM JPEG UND NICHT MEHR RGB565: Rohdaten waren 259200 Byte je Bild, ein JPEG ist
// rund 45 KB. Der Upload wird damit etwa fuenfmal kuerzer, die Weitergabe per
// ESP-NOW an das zweite Auge ebenso - und es wird fuenfmal seltener in den Flash
// geschrieben. Letzteres ist der eigentliche Gewinn: Flash-Schreiben haelt auf dem
// ESP den zweiten Kern an, und daran ist schon einmal ein Cloud-Auge zerbrochen.
// Die Wandlung nach RGB565 (big-endian, LV_COLOR_16_SWAP=1) macht jetzt der Decoder
// auf dem Geraet.

import 'dart:typed_data';
import 'package:image/image.dart' as img;

const int kEyeWidth  = 360;
const int kEyeHeight = 360;

/// So gross wird das Auge selbst gezeichnet. Der Rest der Leinwand ist
/// fortgesetzter Rand. UNVERAENDERT 280, obwohl die Leinwand von 320 auf 360
/// gewachsen ist - nur so bleibt das Auge auf dem Display genau so gross wie
/// vorher. Wuerde man mitwachsen lassen, waeren alle Augen ploetzlich 29 %
/// groesser und jede einmal gemachte Ausrichtung waere falsch.
const int kEyeContent = 280;

/// Obergrenze je Slot. Muss zu CLOUD_JPEG_MAX in Pairing.h passen: die Firmware
/// bricht einen groesseren Upload ab, und an dieser Grenze haengt zugleich die
/// Groesse der Fehlend-Bitmaske in der Empfangsquittung.
const int kEyeJpegMax = 80000;

/// Wie stark der Rand entlang der Kante verwischt wird, je Schritt nach aussen.
/// MUSS zu BORDER_BLUR in tools/eye_assets.py passen.
const double kBorderBlur = 1.6;

/// JPEG-Qualitaet. 92 mit 4:4:4-Chroma. Gemessen gegen das Rohbild lag die
/// groesste Abweichung damit bei 2-3 von 31 Helligkeitsstufen, also auf dem
/// Quantisierungsboden des 16-Bit-Ziels selbst. Hoehere Qualitaet half kaum,
/// Chroma-Subsampling dagegen kostete sichtbar: damit lag die Spitze bei 6 und
/// zeigte sich als feiner Saum am Pupillenrand.
const int kEyeJpegQuality = 92;

/// Unterste Qualitaet, auf die heruntergegangen wird, bevor abgebrochen wird.
/// Darunter wird die Struktur sichtbar matschig - und ein Bild, das selbst bei
/// 64 nicht passt, ist fuer diesen Zweck schlicht zu detailreich.
const int kEyeJpegQualityMin = 64;

/// Mit welcher Qualitaet das zuletzt erzeugte Auge kodiert wurde. Nur fuer die
/// Anzeige: wenn ein Bild heruntergerechnet werden musste, soll man das sehen und
/// nicht raetseln, warum es weicher aussieht als am Bildschirm.
int lastJpegQuality = kEyeJpegQuality;

/// Decodiert PNG/JPG, skaliert das Auge auf 280x280, legt es mittig auf eine
/// 360x360-Leinwand mit fortgesetztem Rand und gibt ein JPEG zurueck.
Uint8List pngToEyeJpeg(Uint8List pngBytes) {
  final src = img.decodeImage(pngBytes);
  if (src == null) {
    throw Exception('PNG/JPG konnte nicht dekodiert werden');
  }
  final content = (src.width != kEyeContent || src.height != kEyeContent)
      ? img.copyResize(src, width: kEyeContent, height: kEyeContent,
                       interpolation: img.Interpolation.linear)
      : src;

  // Leinwand mit VERWISCHTEM Rand.
  //
  // Zwei verworfene Wege stecken hier drin, beide am Geraet gesehen:
  //
  //   1. KLEMMEN - jedes Randpixel aus dem naechstgelegenen Inhaltspixel. Wo
  //      eine Ader die Inhaltskante kreuzt, wird sie ueber die ganze Randbreite
  //      zu einem waagrechten Strich gezogen: sichtbare rote Streifen, sobald
  //      das Auge seitlich am Anschlag steht.
  //   2. SPIEGELN - loeste die Streifen, holt aber den Bildinhalt zurueck ins
  //      Bild. Bei Motiven auf schwarzem Grund, deren Iris bis an die
  //      Inhaltskante reicht, erscheint am Anschlag eine zweite, gespiegelte
  //      Iris.
  //
  // Jetzt wird die Kante nach aussen fortgesetzt und dabei ENTLANG der Kante
  // gemittelt, mit wachsendem Fenster: am Inhaltsrand fast der Kantenpixel
  // (nahtlos), ganz aussen ein breiter Mittelwert. Eine Ader wird so zu einem
  // weichen Schleier statt zu einem Strich, eine schwarze Flaeche bleibt
  // schwarz - und gespiegelt wird gar nichts mehr.
  //
  // Dasselbe Verfahren benutzt tools/eye_assets.py fuer die eingebauten Augen -
  // beide muessen gleich aussehen, sonst faellt der Wechsel zwischen einem
  // Cloud-Auge und einem eingebauten auf. kBorderBlur muss dort ebenfalls
  // uebereinstimmen.
  final pad = (kEyeWidth - kEyeContent) ~/ 2;
  final canvas = img.Image(width: kEyeWidth, height: kEyeHeight);

  for (int y = 0; y < kEyeContent; y++) {
    for (int x = 0; x < kEyeContent; x++) {
      canvas.setPixel(x + pad, y + pad, content.getPixel(x, y));
    }
  }

  // Praefixsummen je Farbkanal - damit kostet ein Fenstermittel O(1) statt
  // einer Schleife je Pixel. Bei bis zu 129 Werten im Fenster ist das der
  // Unterschied zwischen Millisekunden und spuerbarem Warten auf dem Handy.
  List<List<int>> prefix(List<List<int>> werte) {
    final p = <List<int>>[[0, 0, 0]];
    for (final w in werte) {
      final l = p.last;
      p.add([l[0] + w[0], l[1] + w[1], l[2] + w[2]]);
    }
    return p;
  }

  List<int> fenster(List<List<int>> p, int i, int k, int n) {
    final a = (i - k) < 0 ? 0 : (i - k);
    final b = (i + k) > (n - 1) ? (n - 1) : (i + k);
    final anz = b - a + 1;
    return [
      (p[b + 1][0] - p[a][0]) ~/ anz,
      (p[b + 1][1] - p[a][1]) ~/ anz,
      (p[b + 1][2] - p[a][2]) ~/ anz,
    ];
  }

  List<int> rgbVon(img.Pixel px) =>
      [px.r.toInt(), px.g.toInt(), px.b.toInt()];

  // Links und rechts: die beiden Randspalten nach aussen verwischen.
  final pl = prefix([
    for (int y = 0; y < kEyeContent; y++) rgbVon(content.getPixel(0, y))
  ]);
  final pr = prefix([
    for (int y = 0; y < kEyeContent; y++)
      rgbVon(content.getPixel(kEyeContent - 1, y))
  ]);
  for (int y = 0; y < kEyeContent; y++) {
    for (int d = 1; d <= pad; d++) {
      final k = (d * kBorderBlur).toInt();
      final l = fenster(pl, y, k, kEyeContent);
      final r = fenster(pr, y, k, kEyeContent);
      canvas.setPixelRgb(pad - d, y + pad, l[0], l[1], l[2]);
      canvas.setPixelRgb(pad + kEyeContent - 1 + d, y + pad, r[0], r[1], r[2]);
    }
  }

  // Oben und unten ueber die GANZE Breite - damit sind auch die Ecken erledigt.
  final pt = prefix([
    for (int x = 0; x < kEyeWidth; x++) rgbVon(canvas.getPixel(x, pad))
  ]);
  final pb = prefix([
    for (int x = 0; x < kEyeWidth; x++)
      rgbVon(canvas.getPixel(x, pad + kEyeContent - 1))
  ]);
  for (int x = 0; x < kEyeWidth; x++) {
    for (int d = 1; d <= pad; d++) {
      final k = (d * kBorderBlur).toInt();
      final o = fenster(pt, x, k, kEyeWidth);
      final u = fenster(pb, x, k, kEyeWidth);
      canvas.setPixelRgb(x, pad - d, o[0], o[1], o[2]);
      canvas.setPixelRgb(x, pad + kEyeContent - 1 + d, u[0], u[1], u[2]);
    }
  }

  // Qualitaet so weit senken, bis es in den Slot passt.
  //
  // Anlass war ein Lava-Auge: feine, kontrastreiche Struktur ueber die ganze
  // Flaeche komprimiert JPEG schlecht, und bei Qualitaet 92 kamen 120 KB heraus -
  // 40 KB ueber der Grenze. Gemessen passte dasselbe Bild ab Qualitaet 84 mit
  // 73 KB; die glatten Augen liegen bei 92 ohnehin unter 50 KB und werden von
  // dieser Schleife gar nicht erst angefasst.
  //
  // Lieber hier ein paar Prozent Qualitaet als die Grenze anheben: an
  // CLOUD_JPEG_MAX haengt in der Firmware auch die Groesse der Fehlend-Bitmaske
  // in der Empfangsquittung, und vier Slots teilen sich 917.504 Byte LittleFS.
  //
  // 4:4:4 bleibt in jedem Fall. Das Chroma-Subsampling war der sichtbare Fehler
  // (Saum am Pupillenrand, Abweichung 6 statt 2-3 Stufen), nicht die Qualitaet.
  Uint8List? jpg;
  for (int q = kEyeJpegQuality; q >= kEyeJpegQualityMin; q -= 4) {
    jpg = Uint8List.fromList(
        img.encodeJpg(canvas, quality: q, chroma: img.JpegChroma.yuv444));
    if (jpg.length <= kEyeJpegMax) {
      lastJpegQuality = q;
      return jpg;
    }
  }

  // Auch bei der untersten Qualitaet zu gross: dann liegt es am Bild, nicht an
  // der Einstellung, und die Meldung soll das auch sagen.
  throw Exception('JPEG zu gross: ${jpg!.length} Bytes bei Qualitaet '
                  '$kEyeJpegQualityMin, erlaubt sind $kEyeJpegMax. '
                  'Bild mit weniger feiner Struktur verwenden.');
}

/// Prueft die Rahmen-Marker. Ein abgeschnittenes JPEG faengt richtig an, endet aber
/// nicht mit FFD9 - die Firmware prueft genauso, damit ein abgebrochener Upload
/// nicht als belegter Slot zurueckbleibt.
bool isCompleteJpeg(Uint8List d) {
  if (d.length < 4) return false;
  return d[0] == 0xFF && d[1] == 0xD8 &&
         d[d.length - 2] == 0xFF && d[d.length - 1] == 0xD9;
}
