"""Erzeugt die Vorschaubilder in cloud-eyes/thumbs/.

WICHTIG: Nach jedem neu hinzugefuegten Auge einmal ausfuehren und das Ergebnis
mit committen.

Warum es das gibt: Die App zeigt in der Cloud-Liste 56x56 grosse Vorschauen. Ohne
diese Dateien laedt sie dafuer die vollen Augen herunter - damals elf Stueck mal
rund 1,5 MB, also 16,3 MB bei JEDEM Oeffnen des Bildschirms. GitHub hat den Zugriff
auf raw.githubusercontent.com daraufhin gedrosselt (HTTP 429 bzw. 503), womit nicht
nur die Vorschau ausfiel, sondern auch der Download - beide nutzen dieselbe URL.

Mit den Vorschaubildern sind es rund 6 KB je Auge. Inzwischen stehen 33 Augen mit
47,7 MB nur 205 KB Vorschaubildern gegenueber; der Ordner waechst weiter, der
Abstand also auch.

WebP, weil es Transparenz kann (zwei der Augen haben transparente Bereiche, als JPEG
wuerden die schwarz) und trotzdem etwa zwoelfmal kleiner ist als PNG. Flutter
dekodiert WebP nativ, es ist keine zusaetzliche Abhaengigkeit noetig.

Normalerweise muss das NIEMAND von Hand aufrufen: .github/workflows/thumbs.yml
startet dieses Skript automatisch, sobald ein Bild in cloud-eyes/ dazukommt oder sich
aendert, und schreibt das Ergebnis zurueck ins Repo. Ein "bitte nicht vergessen"
waere genau die Absicherung, die irgendwann vergessen wird.

Von Hand nur noetig, wenn der Ablauf einmal fehlschlaegt:

    pip install pillow
    python cloud-eyes/make_thumbs.py
"""
import glob
import os

from PIL import Image

SIZE = 192      # angezeigt werden 56 dp - 192 px reicht auch auf 3x-Displays
QUALITY = 82

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "thumbs")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    sources = []
    for ext in ("*.png", "*.jpg", "*.jpeg"):
        sources.extend(glob.glob(os.path.join(HERE, ext)))

    src_total = dst_total = 0
    for path in sorted(sources):
        # Am ERSTEN Punkt trennen, nicht am letzten: genau so bildet die App den
        # Namen (n.split('.').first in cloud_eyes.dart). Wuerde hier splitext stehen,
        # liefen beide bei einem Punkt im Dateinamen auseinander und die App suchte
        # eine Vorschau, die es nicht gibt. Punkte im Augennamen daher vermeiden.
        base = os.path.basename(path).split(".")[0]
        out = os.path.join(OUT_DIR, base + ".webp")
        Image.open(path).convert("RGBA") \
             .resize((SIZE, SIZE), Image.LANCZOS) \
             .save(out, "WEBP", quality=QUALITY, method=6)
        src_total += os.path.getsize(path)
        dst_total += os.path.getsize(out)
        print("  %-30s %6.2f MB -> %5.1f KB"
              % (base, os.path.getsize(path) / 1024 / 1024,
                 os.path.getsize(out) / 1024))

    # Verwaiste Vorschauen entfernen, damit geloeschte Augen nicht als Leiche bleiben
    names = {os.path.basename(p).split(".")[0] for p in sources}
    for old in glob.glob(os.path.join(OUT_DIR, "*.webp")):
        if os.path.basename(old).split(".")[0] not in names:
            os.remove(old)
            print("  entfernt (Auge gibt es nicht mehr):", os.path.basename(old))

    if dst_total:
        print("\n%d Vorschaubilder: %.1f MB -> %.0f KB (Faktor %.0f)"
              % (len(sources), src_total / 1024 / 1024, dst_total / 1024,
                 src_total / dst_total))


if __name__ == "__main__":
    main()
