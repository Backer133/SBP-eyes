import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ble_service.dart';
import '../theme.dart';

/// Sperr-Bildschirm: erscheint, solange die Verbindung nicht autorisiert ist
/// (`ble.locked`). Blockiert die gesamte Steuerung, bis der richtige 6-stellige
/// Zugangscode eingegeben wurde. Der Auto-Login mit dem gespeicherten Code laeuft
/// bereits beim Connect - dieser Screen ist der Fallback bei falschem/fehlendem Code.
class LockGate extends StatefulWidget {
  final EyeBle ble;
  const LockGate({super.key, required this.ble});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = int.tryParse(_ctrl.text);
    if (code == null || _ctrl.text.length != 6) {
      setState(() => _error = 'Bitte 6-stelligen Code eingeben');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final ok = await widget.ble.authenticateWith(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        // Drei Faelle, die alle wie "falscher Code" aussehen koennen:
        //
        //   1. Der Code war wirklich falsch.
        //   2. Das Auge sperrt gerade. Die Firmware steigt dann STUMM aus
        //      (Master.ino, AuthCb::onWrite: return VOR auth_status_notify) -
        //      von aussen nicht von Fall 1 zu unterscheiden, also muss der Text
        //      beides nennen, sonst sucht man am falschen Ende.
        //   3. Der Code kam gar nicht erst an. Dann ist es kein Fehlversuch,
        //      die Firmware hat auch keinen gezaehlt, und der eigentliche Grund
        //      steht in lastError - der gehoert dazu.
        final grund = widget.ble.lastError;
        _error = widget.ble.authNoAnswer
            ? 'Keine Antwort vom Auge. Nochmal senden - im Browser hilft '
              'notfalls: Seite neu laden und erneut verbinden.'
              '${grund == null ? "" : "\n\n$grund"}'
            : 'Falscher Code - oder das Auge sperrt gerade.\n\n'
              'Nach 5 Fehlversuchen blockiert das Auge 30 Sekunden lang JEDEN '
              'Code, auch den richtigen, und meldet dabei nichts. Wenn der Code '
              'stimmt: 30 Sekunden warten, nichts antippen, dann einmal senden.';
        // Den Code stehen lassen: er kann richtig gewesen sein.
      }
    });
    // Bei Erfolg schaltet ble.authorized -> HomeScreen blendet das Gate aus.
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kWarn.withOpacity(.14),
                border: Border.all(color: kWarn.withOpacity(.4), width: 2),
              ),
              child: const Icon(Icons.lock_outline, size: 44, color: kWarn),
            ),
            const SizedBox(height: 24),
            const Text('Gesperrt',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Dieses Augenpaar ist geschuetzt. Der 6-stellige Zugangscode ist bei jedem Verbinden noetig - gib ihn ein, um die Steuerung freizuschalten.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(.6), height: 1.4),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _ctrl,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              obscureText: true,
              obscuringCharacter: '•',
              style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 12),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                counterText: '',
                hintText: '••••••',
                hintStyle: TextStyle(letterSpacing: 12, color: Colors.white24),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 16, color: kBad),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(_error!,
                        style: const TextStyle(color: kBad, fontSize: 13)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.lock_open),
                label: Text(_busy ? 'Pruefe...' : 'Entsperren'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
