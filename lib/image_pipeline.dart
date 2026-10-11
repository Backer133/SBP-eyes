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

/// JPEG-Qualitaet. 92 mit 4:4:4-Chroma. Gemessen gegen das Rohbild lag die
/// groesste Abweichung damit bei 2-3 von 31 Helligkeitsstufen, also auf dem
/// Quantisierungsboden des 16-Bit-Ziels selbst. Hoehere Qualitaet half kaum,
/// Chroma-Subsampling dagegen kostete sichtbar: damit lag die Spitze bei 6 und
/// zeigte sich als feiner Saum am Pupillenrand.
const int kEyeJpegQuality = 92;

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

  // Leinwand mit fortgesetztem Rand: jedes Pixel ausserhalb des Inhalts uebernimmt
  // den naechstgelegenen Inhaltsrand (Clamp). Bei den Augen ist das die gleichmaessige
  // helle Sklera, der Uebergang faellt deshalb nicht auf. Genau dieses Layout haben
  // auch die eingebauten Augen - dort nachgemessen: 280x280 Inhalt, 40 px Clamp.
  final pad = (kEyeWidth - kEyeContent) ~/ 2;
  final canvas = img.Image(width: kEyeWidth, height: kEyeHeight);
  for (int y = 0; y < kEyeHeight; y++) {
    final sy = (y - pad).clamp(0, kEyeContent - 1);
    for (int x = 0; x < kEyeWidth; x++) {
      final sx = (x - pad).clamp(0, kEyeContent - 1);
      canvas.setPixel(x, y, content.getPixel(sx, sy));
    }
  }

  final jpg = Uint8List.fromList(
      img.encodeJpg(canvas, quality: kEyeJpegQuality, chroma: img.JpegChroma.yuv444));

  if (jpg.length > kEyeJpegMax) {
    throw Exception('JPEG zu gross: ${jpg.length} Bytes, erlaubt sind $kEyeJpegMax. '
                    'Bild mit weniger Details verwenden.');
  }
  return jpg;
}

/// Prueft die Rahmen-Marker. Ein abgeschnittenes JPEG faengt richtig an, endet aber
/// nicht mit FFD9 - die Firmware prueft genauso, damit ein abgebrochener Upload
/// nicht als belegter Slot zurueckbleibt.
bool isCompleteJpeg(Uint8List d) {
  if (d.length < 4) return false;
  return d[0] == 0xFF && d[1] == 0xD8 &&
         d[d.length - 2] == 0xFF && d[d.length - 1] == 0xD9;
}
