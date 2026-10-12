import 'package:flutter/material.dart';
import '../ble_service.dart';
import '../theme.dart';
import 'log_screen.dart';

class DiagnosticsScreen extends StatelessWidget {
  final EyeBle ble;
  const DiagnosticsScreen({super.key, required this.ble});

  @override
  Widget build(BuildContext context) {
    // Live aktualisieren, sobald der Master neue Funk-Diagnose meldet.
    return ListenableBuilder(
      listenable: ble,
      builder: (context, _) {
        final linked = ble.slaveLinked;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // Das Protokoll auch von hier aus erreichbar: wer in der Diagnose
            // steht, sucht ohnehin nach einer Ursache.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.article_outlined, size: 18),
                label: const Text('Protokoll'),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogScreen())),
              ),
            ),
            const SectionHeader('Funk-Verbindung (ESP-NOW)', icon: Icons.wifi),
            _bigCard(
              // Symbol und Farbe muessen aus derselben Quelle kommen wie der Text.
              // Vorher hing die Farbe an slaveLinked, der Text an isBound - dabei
              // konnte "nicht gekoppelt" in Gruen erscheinen.
              icon: !ble.isBound
                  ? Icons.link_off
                  : linked ? Icons.wifi : Icons.wifi_off,
              color: !ble.isBound ? kWarn : (linked ? kGood : kWarn),
              title: 'Zweiter Screen (Slave)',
              value: ble.linkStateName,
              // Ohne Kopplung ist "kein Funk-Kontakt" die falsche Erklaerung - es
              // fehlt kein Signal, sondern schlicht der Partner.
              sub: !ble.isBound
                  ? 'Noch kein zweites Auge gekoppelt - unter Einstellungen koppeln'
                  : linked
                      ? 'Slave ist per Funk verbunden und synchron'
                      : 'Kein Funk-Kontakt - Slave stromlos oder ausser Reichweite',
            ),
            if (ble.subscribeErrors.isNotEmpty)
              Card(
                color: kBad.withOpacity(0.15),
                child: ListTile(
                  leading: const Icon(Icons.error_outline, color: kBad),
                  title: const Text('Schritte beim Verbinden fehlgeschlagen'),
                  subtitle: Text(
                    '${ble.subscribeErrors.join("\n")}\n\n'
                    'Die Verbindung laeuft trotzdem - die genannten Werte sind '
                    'aber nicht aktuell. Die vier Ziffern sind die Kurzform der '
                    'Characteristic-UUID.',
                  ),
                ),
              ),
            const SectionHeader('Verbindungsqualitaet', icon: Icons.speed),
            _infoCard(
              rows: [
                _RowData(Icons.schedule, 'Letztes Signal', _silenceText(ble.silenceMs),
                    pillColor: _silenceColor(ble.silenceMs)),
                _RowData(Icons.leak_remove, 'Verlustrate', '${ble.lossPct} %',
                    pillColor: _lossColor(ble.lossPct)),
                _RowData(Icons.router, 'Kanal Master',
                    ble.masterChannel == 0 ? '-' : 'Ch ${ble.masterChannel}'),
                // Der Slave meldet seinen Kanal im Alive-Ping. Ohne Verbindung
                // steht hier der letzte bekannte Wert - genau dann ist er nuetzlich.
                _RowData(Icons.router_outlined,
                    ble.slaveLinked ? 'Kanal Slave' : 'Kanal Slave (zuletzt)',
                    ble.slaveChannel == 0 ? 'unbekannt' : 'Ch ${ble.slaveChannel}',
                    pillColor: (ble.slaveChannel != 0 &&
                                ble.masterChannel != 0 &&
                                ble.slaveChannel != ble.masterChannel)
                        ? kWarn
                        : null),
              ],
            ),
            const SectionHeader('Zustand', icon: Icons.info_outline),
            _infoCard(
              rows: [
                _RowData(Icons.remove_red_eye, 'Augenpaar',
                    ble.deviceName.isEmpty ? '--' : ble.deviceName),
                // Je Auge getrennt - nur wenn beide gleich stehen, reicht ein Wort.
                _RowData(Icons.animation, 'Animation',
                    ble.animEnabled[0] == ble.animEnabled[1]
                        ? (ble.animEnabled[0] == 1 ? 'An' : 'Aus')
                        : (ble.animEnabled[0] == 1
                            ? 'Auge 1 an, Auge 2 aus'
                            : 'Auge 1 aus, Auge 2 an')),
                if (ble.authSupported)
                  _RowData(
                    ble.authorized ? Icons.lock_open : Icons.lock,
                    'Zugang',
                    ble.authorized ? 'Autorisiert' : 'Gesperrt',
                    pillColor: ble.authorized ? kGood : kWarn,
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _silenceText(int ms) {
    if (ms <= 0) return 'gerade eben';
    if (ms < 1000) return 'vor $ms ms';
    return 'vor ${(ms / 1000).toStringAsFixed(1)} s';
  }

  static Color _silenceColor(int ms) {
    if (ms < 1500) return kGood;
    if (ms < 5000) return kWarn;
    return kBad;
  }

  static Color _lossColor(int pct) {
    if (pct <= 10) return kGood;
    if (pct <= 40) return kWarn;
    return kBad;
  }

  Widget _bigCard({required IconData icon, required Color color,
                    required String title, required String value, String? sub}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: color.withOpacity(.14),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, size: 32, color: color),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(.5))),
                  const SizedBox(height: 4),
                  Text(value,
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800, color: color)),
                  if (sub != null) ...[
                    const SizedBox(height: 4),
                    Text(sub,
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(.45))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoCard({required List<_RowData> rows}) {
    return Card(
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _row(rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(_RowData d) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(d.icon, color: Colors.white54, size: 22),
      title: Text(d.label, style: const TextStyle(fontSize: 15)),
      trailing: d.pillColor != null
          ? StatusPill(d.value, color: d.pillColor!)
          : Text(d.value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    );
  }
}

class _RowData {
  final IconData icon;
  final String label;
  final String value;
  final Color? pillColor;
  _RowData(this.icon, this.label, this.value, {this.pillColor});
}
