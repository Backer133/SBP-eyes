// GitHub-API Client fuer cloud-eyes/ Ordner.
// Manueller Workflow: PNG ins Repo pushen, App listet via GitHub Contents API.

import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CloudEye {
  final String name;        // Dateiname ohne Extension, z.B. "Maus"
  final String fileName;    // Originaler Dateiname inkl. Extension
  final String downloadUrl; // raw.githubusercontent.com URL, volles Bild (~1,5 MB)
  final int    sizeBytes;

  /// Kleines Vorschaubild (192 px WebP, ~5 KB) in cloud-eyes/thumbs/.
  ///
  /// Ohne das lud die Liste die vollen Bilder herunter, nur um daraus 56x56 grosse
  /// Vorschauen zu zeichnen: elf Augen mal 1,5 MB sind 16,3 MB bei JEDEM Oeffnen des
  /// Bildschirms. GitHub hat den Zugriff daraufhin gedrosselt (HTTP 429/503), womit
  /// Vorschau UND Download ausfielen - beide haengen an derselben URL.
  final String thumbUrl;

  CloudEye({
    required this.name,
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.thumbUrl,
  });
}

class GithubCloudEyes {
  // Neues, vom alten eye-pair-app abgeschottetes Repo (oeffentlich, damit die App
  // die Augen ohne Login ueber die GitHub-API laden kann).
  // Umbenannt am 11.10.2026 (vorher eye_pair_app_new_screens_cheaper).
  // GitHub leitet alte Namen zwar dauerhaft um, sodass bereits installierte
  // Apps weiterlaufen - verlassen sollte man sich darauf aber nicht: die
  // Umleitung bricht, sobald jemand ein neues Repo mit dem alten Namen anlegt.
  static const String repo = 'Backer133/SBP-eyes';
  static const String path = 'cloud-eyes';
  static const String branch = 'main';

  /// Liest Ordner-Inhalt via GitHub Contents API.
  /// Filtert auf .png/.jpg/.jpeg Dateien.
  Future<List<CloudEye>> list() async {
    final url = Uri.parse('https://api.github.com/repos/$repo/contents/$path?ref=$branch');
    final r = await http.get(url, headers: {
      'Accept': 'application/vnd.github.v3+json',
    });
    if (r.statusCode != 200) {
      throw Exception('GitHub API ${r.statusCode}: ${r.body}');
    }
    final List<dynamic> items = json.decode(r.body);
    final eyes = <CloudEye>[];
    for (final it in items) {
      final n = it['name'] as String;
      final lower = n.toLowerCase();
      // Der Unterordner "thumbs" faellt hier bereits raus (kein Bild-Suffix). Wichtig,
      // denn Verzeichniseintraege haben kein download_url.
      if (!lower.endsWith('.png') && !lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) continue;
      final base = n.split('.').first;
      eyes.add(CloudEye(
        name: base,
        fileName: n,
        downloadUrl: it['download_url'] as String,
        sizeBytes: it['size'] as int,
        // Aus dem Namen gebildet statt aus einer zweiten Verzeichnisabfrage - das
        // spart einen API-Aufruf. Fehlt eine Datei (neues Auge, Vorschau noch nicht
        // erzeugt), faellt die Anzeige auf das volle Bild zurueck.
        thumbUrl: 'https://raw.githubusercontent.com/$repo/$branch/$path/thumbs/'
                  '${Uri.encodeComponent(base)}.webp',
      ));
    }
    eyes.sort((a, b) => a.name.compareTo(b.name));
    return eyes;
  }

  /// Laedt das PNG/JPG als Bytes runter.
  Future<Uint8List> download(CloudEye e) async {
    final r = await http.get(Uri.parse(e.downloadUrl));
    if (r.statusCode != 200) {
      throw Exception('Download fehlgeschlagen: ${r.statusCode}');
    }
    return r.bodyBytes;
  }
}
