import 'package:flutter/material.dart';

import '../ble_service.dart';
import '../theme.dart';

/// Koppelt genau einen Slave an diesen Master.
///
/// Der Slave hat kein BLE - die App erreicht immer nur den Master. Die Suche
/// laeuft deshalb ueber den Master per ESP-NOW auf Kanal 6: er ruft, die
/// koppelbaren Augen antworten, und jeder Fund kommt als eigene Notify herein.
class PairingScreen extends StatefulWidget {
  final EyeBle ble;
  const PairingScreen({super.key, required this.ble});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Abos und Startwert der Kopplung holen, bevor gesucht wird: sie laufen
      // nicht mehr beim Verbinden mit, damit das Anmelden nicht auf Werte
      // wartet, die nur dieser Bildschirm anzeigt.
      await widget.ble.ensurePairing();
      if (!mounted) return;
      widget.ble.startPairingScan();
    });
  }

  @override
  void dispose() {
    widget.ble.stopPairingScan();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Antippen laesst das Auge blinken; erst nach Bestaetigung wird gebunden.
  Future<void> _tapSlave(FoundSlave f) async {
    if (f.boundToThisMaster) {
      _snack('Dieses Auge ist bereits mit diesem Master gekoppelt.');
      return;
    }
    if (f.alreadyBound) {
      _snack('Dieses Auge gehoert zu einem anderen Master.');
      return;
    }
    await widget.ble.identifySlave(f.mac);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Blinkt dieses Auge?'),
        content: Text('Das Auge ${f.shortId} sollte jetzt 5 Sekunden lang blinken.\n\n'
                      'Blinkt ein anderes, brich ab und tippe den richtigen Eintrag an.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nein')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ja, koppeln')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.ble.bindSlave(f.mac);
  }

  /// Wechselt den Zugangscode auf der LAUFENDEN Verbindung. Ohne das muesste man
  /// erst trennen und neu verbinden, nur um an eine Admin-Funktion zu kommen -
  /// und beim Trennen geht die Sitzung samt gemerktem Code verloren.
  Future<void> _loginAsAdmin() async {
    final ctrl = TextEditingController();
    final code = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin-Code eingeben'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '6-stelliger Code',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Anmelden'),
          ),
        ],
      ),
    );
    if (code == null || !mounted) return;
    await widget.ble.authenticateWith(code);
    if (!mounted) return;
    _snack(widget.ble.isAdmin
        ? 'Als Admin angemeldet'
        : 'Kein Admin-Code - Zwangsloesen bleibt gesperrt');
  }

  /// Nur mit Admin-Code: loest die Bindung eines fremden Slaves.
  Future<void> _forceUnbind(FoundSlave f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zwangsentkopplung'),
        content: Text(
          'Auge ${f.shortId} gehoert zu einem anderen Master. Die Kopplung wird '
          'geloest - gedacht fuer den Fall, dass dieser Master defekt ist.\n\n'
          'Der zugehoerige Master weiss davon nichts und muss seinerseits neu '
          'gekoppelt werden.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Loesen')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.ble.unbindAdmin(f.mac);
    // Der Master faehrt dafuer alle vier Kanaele ab - das dauert.
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) await widget.ble.startPairingScan();
  }

  Future<void> _unbindOwn() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kopplung loesen?'),
        content: const Text('Danach laufen die beiden Augen nicht mehr synchron, '
                            'bis du sie neu koppelst.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Loesen')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.ble.unbindOwn();
    if (mounted) await widget.ble.startPairingScan();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ble,
      builder: (context, _) {
        final ble = widget.ble;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Slave koppeln'),
            actions: [
              if (!ble.isAdmin)
                IconButton(
                  icon: const Icon(Icons.admin_panel_settings_outlined),
                  tooltip: 'Als Admin anmelden',
                  onPressed: _loginAsAdmin,
                ),
            ],
          ),
          body: Column(
            children: [
              if (ble.isBound)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: ListTile(
                    leading: const Icon(Icons.link, color: kGood),
                    title: Text('Gekoppelt mit ${ble.boundMacStr}'),
                    subtitle: Text('Paar-ID ${ble.boundPairId}'),
                    trailing: TextButton(
                      onPressed: _unbindOwn,
                      child: const Text('Loesen'),
                    ),
                  ),
                ),
              if (ble.pairingError != 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber, color: kWarn, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(ble.pairingErrorText,
                          style: const TextStyle(color: kWarn))),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: Builder(builder: (ctx) {
                  // Augen, die einem ANDEREN Master gehoeren, sind hier nur
                  // Rauschen - sie lassen sich ohnehin nicht koppeln. Sichtbar
                  // bleiben sie nur fuer Admins, die sie zwangsloesen duerfen.
                  final visible = ble.pairingFound
                      .where((f) => !f.boundToOther || ble.isAdmin)
                      .toList();
                  final hidden = ble.pairingFound.length - visible.length;

                  if (visible.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          const Text('Suche nach koppelbaren Augen ...'),
                          const SizedBox(height: 4),
                          const Text('Der Slave muss eingeschaltet sein.',
                              style: TextStyle(fontSize: 12)),
                          if (hidden > 0) ...[
                            const SizedBox(height: 16),
                            Text(
                              '$hidden Auge(n) in Reichweite gehoeren zu anderen '
                              'Mastern und werden ausgeblendet.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white38),
                            ),
                          ],
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: visible.length + (hidden > 0 ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i == visible.length) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                          child: Text(
                            '$hidden weiteres Auge / weitere Augen in Reichweite '
                            'gehoeren zu anderen Mastern und sind ausgeblendet.',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white38),
                          ),
                        );
                      }
                      final f = visible[i];
                      final canAdmin = f.boundToOther && ble.isAdmin;
                      return Card(
                        child: ListTile(
                          enabled: f.free || canAdmin,
                          leading: Icon(
                            f.boundToThisMaster
                                ? Icons.link
                                : f.alreadyBound
                                    ? Icons.lock
                                    : Icons.visibility,
                            color: f.boundToThisMaster
                                ? kGood
                                : f.alreadyBound
                                    ? kWarn
                                    : kAccentGlow,
                          ),
                          title: Text('Auge ${f.shortId}'),
                          subtitle: Text(f.boundToThisMaster
                              ? 'gehoert zu diesem Master'
                              : f.alreadyBound
                                  ? 'gehoert zu einem anderen Master'
                                  : '${f.rssi} dBm - antippen zum Blinken'),
                          trailing: canAdmin
                              ? TextButton(
                                  onPressed: () => _forceUnbind(f),
                                  child: const Text('Zwangsloesen'),
                                )
                              : null,
                          onTap: () => _tapSlave(f),
                        ),
                      );
                    },
                  );
                }),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => ble.startPairingScan(),
            icon: const Icon(Icons.refresh),
            label: const Text('Neu suchen'),
          ),
        );
      },
    );
  }
}
