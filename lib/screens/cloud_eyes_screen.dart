import 'dart:async';

import 'package:flutter/material.dart';
import '../ble_service.dart';
import '../cloud_eyes.dart';
import '../image_pipeline.dart';
import '../slot_metadata.dart';
import '../theme.dart';

class CloudEyesScreen extends StatefulWidget {
  final EyeBle ble;
  final Future<void> Function()? onSlotMetaChanged;
  const CloudEyesScreen({super.key, required this.ble, this.onSlotMetaChanged});
  @override
  State<CloudEyesScreen> createState() => _CloudEyesScreenState();
}

class _CloudEyesScreenState extends State<CloudEyesScreen> {
  final _api = GithubCloudEyes();
  List<CloudEye>? _eyes;
  String? _error;
  bool _loading = false;

  // Download-Status
  bool   _downloading = false;
  int    _downloadDone = 0;
  int    _downloadTotal = 0;
  String _downloadName = '';

  @override
  void initState() {
    super.initState();
    // Quittungs-Abo des zweiten Auges holen. Es laeuft nicht mehr beim Verbinden
    // mit (siehe EyeBle.ensureUpload); ohne es steht der Upload-Fortschritt des
    // Slaves still.
    widget.ble.ensureUpload();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await _api.list();
      // Bereits installierte Bilder ausblenden - die User loescht sie via Long-press
      // im Eye-Grid, dann tauchen sie hier wieder auf.
      final installed = await SlotMetadataStore.getInstalledUrls(widget.ble.deviceId);
      final visible = list.where((e) => !installed.contains(e.downloadUrl)).toList();
      if (!mounted) return;
      setState(() { _eyes = visible; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _downloadToSlot(CloudEye eye, int slot) async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _downloadDone = 0;
      _downloadTotal = 0;
      _downloadName = '${eye.name} -> Slot ${slot + 1}';
    });
    try {
      final pngBytes = await _api.download(eye);
      final jpeg = pngToEyeJpeg(pngBytes);
      await widget.ble.uploadEye(slot, jpeg, onProgress: (sent, total) {
        if (!mounted) return;
        setState(() { _downloadDone = sent; _downloadTotal = total; });
      });
      // Slot-Metadata persistieren
      await SlotMetadataStore.set(widget.ble.deviceId, slot, eye.name,
                                  eye.downloadUrl, eye.thumbUrl);
      await widget.onSlotMetaChanged?.call();
      // Cloud-Tab Liste aktualisieren (Bild verschwindet weil installiert)
      await _refresh();
      if (!mounted) return;
      // Status-Dialog: zeigt Slave-Forward Progress + Auto-Reconnect zum Receipt-Read
      await _showSlaveForwardDialog(eye.name, slot);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download-Fehler: $e')),
      );
    } finally {
      if (mounted) setState(() { _downloading = false; });
    }
  }

  /// Zeigt einen Status-Dialog mit Countdown waehrend Master->Slave forwarded,
  /// disconnected die App fuer Coex-Schutz, reconnected dann fuer Receipt-Read.
  Future<void> _showSlaveForwardDialog(String eyeName, int slot) async {
    // App disconnecten - Master forwarded jetzt ohne BLE-Coex.
    // Mit Timeout: wenn disconnect haengt (Android-BT-State stuck), nicht ewig blockieren.
    try {
      await widget.ble.disconnect().timeout(const Duration(seconds: 5));
    } catch (_) {}

    if (!mounted) return;
    // Non-dismissable Dialog mit Countdown
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SlaveForwardDialog(ble: widget.ble, eyeName: eyeName, slot: slot),
    );

    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
    // Force-Refresh: stellt sicher dass die Screen nach Dialog-Close sauber neu rendert.
    // Falls BLE in einem komischen Zustand ist, vermeidet das einen schwarzen Frame.
    setState(() {});
  }

  Future<void> _pickSlotAndDownload(CloudEye eye) async {
    final slot = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('"${eye.name}" auf welchen Slot herunterladen?'),
        children: [
          for (int s = 0; s < kCloudSlotCount; s++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Row(children: [
                const Icon(Icons.cloud_download),
                const SizedBox(width: 8),
                Text('Slot ${s + 1}'),
              ]),
            ),
        ],
      ),
    );
    if (slot != null) await _downloadToSlot(eye, slot);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_downloading)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Lade auf Augen: $_downloadName',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _downloadTotal > 0 ? _downloadDone / _downloadTotal : null,
                    ),
                    const SizedBox(height: 4),
                    Text('$_downloadDone / $_downloadTotal Chunks',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        if (_error != null)
          Container(
            width: double.infinity,
            color: Colors.red.withOpacity(0.2),
            padding: const EdgeInsets.all(12),
            child: Text(_error!),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _eyes == null || _eyes!.isEmpty
                    ? ListView(
                        children: const [
                          SizedBox(height: 200),
                          Center(child: Text('Keine Augen in der Cloud gefunden.\n'
                              'Der Admin hat noch keine Augen bereit gestellt.',
                              textAlign: TextAlign.center)),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _eyes!.length,
                        itemBuilder: (_, i) {
                          final e = _eyes![i];
                          return Card(
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                // Kleines Vorschaubild (~5 KB) statt des vollen Auges
                                // (~1,5 MB). Fehlt es - etwa weil ein Auge neu ist und
                                // die Vorschau noch nicht erzeugt wurde - wird das volle
                                // Bild nachgeladen, damit die Liste trotzdem etwas zeigt.
                                child: Image.network(
                                  e.thumbUrl,
                                  width: 56, height: 56, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Image.network(
                                    e.downloadUrl,
                                    width: 56, height: 56, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.broken_image),
                                  ),
                                ),
                              ),
                              title: Text(e.name),
                              subtitle: Text('${(e.sizeBytes / 1024).toStringAsFixed(1)} KB'),
                              trailing: ElevatedButton.icon(
                                icon: const Icon(Icons.cloud_download),
                                label: const Text('Download'),
                                onPressed: _downloading ? null : () => _pickSlotAndDownload(e),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

/// Status-Dialog der waehrend Master->Slave-Forward angezeigt wird.
/// - Startet bei Dialog-Open einen Reconnect-Timer (15s)
/// - Nach Reconnect liest er CHR_SLAVE_RECEIPT, zeigt unique/total
/// - Bei Re-Request: wartet weiter, liest erneut

/// Zeigt den zweiten Teil der Übertragung: Master gibt das Bild per Funk an den
/// Slave weiter.
///
/// Die App **muss** dafür getrennt sein — BLE und WLAN teilen sich beim ESP32 die
/// Antenne, eine offene BLE-Verbindung kostet den Funk spürbar Durchsatz. Genau
/// deshalb kann hier kein echter Fortschritt abgefragt werden: Die Anzeige schätzt
/// anhand der vergangenen Zeit und bleibt bewusst bei 95 % stehen, bis das Auge die
/// Vollständigkeit bestätigt hat. Lieber ehrlich kurz vor dem Ziel warten als eine
/// 100 % anzeigen, die noch nichts bedeutet.
class _SlaveForwardDialog extends StatefulWidget {
  final EyeBle ble;
  final String eyeName;
  final int    slot;
  const _SlaveForwardDialog({required this.ble, required this.eyeName, required this.slot});
  @override
  State<_SlaveForwardDialog> createState() => _SlaveForwardDialogState();
}

enum _Phase { forwarding, confirming, done, failed }

class _SlaveForwardDialogState extends State<_SlaveForwardDialog> {
  _Phase _phase = _Phase.forwarding;
  String _note = '';
  bool   _closed = false;
  int    _elapsedMs = 0;
  int    _attempts = 0;
  Timer? _ticker;
  bool   _pendingRetry = false;

  // Schaetzung fuer die Weitergabe, am Seriellen Log gemessen: der Master schafft
  // rund 130 Haeppchen je Sekunde, also gut 7 s fuer 891 Stueck. Dazu etwa 1,5 s
  // Wartezeit, bis er nach dem Trennen der BLE-Verbindung anfaengt, und die Zeit,
  // die der Slave zum Schreiben der 200 KB braucht.
  // Grosszuegig gerechnet: eine zu frueh aufgebaute Verbindung kostet mehr, als ein
  // paar Sekunden laenger zu warten - der Master pausiert dann zwar nicht mehr,
  // aber BLE und WLAN teilen sich weiterhin dieselbe Antenne.
  static const int _forwardEstimateMs = 11000;
  static const int _maxAttempts = 6;
  static const Duration _emergency = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || _closed) return;
      setState(() => _elapsedMs += 100);
      // Erst nach der geschaetzten Weitergabe verbinden - frueher wuerde die
      // BLE-Verbindung dem Funk genau die Bandbreite nehmen, die er gerade braucht.
      if (_phase == _Phase.forwarding && _elapsedMs >= _forwardEstimateMs) {
        setState(() => _phase = _Phase.confirming);
        _tryConfirm();
      }
    });
    Future.delayed(_emergency, _giveUp);
    widget.ble.addListener(_onBleUpdate);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.ble.removeListener(_onBleUpdate);
    super.dispose();
  }

  void _safePop(String? result) {
    if (_closed || !mounted) return;
    _closed = true;
    _ticker?.cancel();
    Navigator.of(context).pop(result);
  }

  void _giveUp() {
    if (_closed || !mounted || _phase == _Phase.done) return;
    setState(() {
      _phase = _Phase.failed;
      _note  = 'Keine Bestaetigung erhalten. Das Bild ist sehr wahrscheinlich trotzdem '
               'auf beiden Augen - pruefe es einfach an der Augenauswahl.';
    });
    Future.delayed(const Duration(seconds: 3), () => _safePop(null));
  }

  void _onBleUpdate() {
    if (!mounted || _closed || _phase == _Phase.done) return;
    final got   = widget.ble.slaveUniqueReceived;
    final total = widget.ble.slaveTotalChunks;
    if (total <= 0) return;

    if (got >= total) {
      setState(() { _phase = _Phase.done; _note = ''; });
      Future.delayed(const Duration(milliseconds: 900), () {
        _safePop('"${widget.eyeName}" ist auf beiden Augen');
      });
    } else {
      // Unvollstaendig: der Master fordert die fehlenden Haeppchen selbst nach.
      setState(() => _note = 'Fehlende Teile werden nachgefordert ($got von $total)');
      if (!_pendingRetry) {
        _pendingRetry = true;
        Future.delayed(const Duration(seconds: 4), () {
          _pendingRetry = false;
          _tryConfirm();
        });
      }
    }
  }

  Future<void> _tryConfirm() async {
    if (!mounted || _closed || _phase == _Phase.done) return;
    if (++_attempts > _maxAttempts) return _giveUp();
    try {
      if (!widget.ble.connected) await widget.ble.reconnect();
    } catch (_) {
      Future.delayed(const Duration(seconds: 2), _tryConfirm);
    }
  }

  double get _progress {
    switch (_phase) {
      case _Phase.done:   return 1.0;
      case _Phase.failed: return 1.0;
      // Bis 95 % laufen lassen, den Rest erst bei echter Bestaetigung.
      default: return (_elapsedMs / _forwardEstimateMs * 0.95).clamp(0.05, 0.95);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _phase == _Phase.done;
    final failed = _phase == _Phase.failed;
    return AlertDialog(
      title: Text(done ? 'Fertig' : failed ? 'Ohne Bestaetigung' : 'Auge wird uebertragen'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _step(true, 'Auf das erste Auge', 'uebertragen'),
          _step(_phase != _Phase.forwarding, 'Weitergabe ans zweite Auge',
              _phase == _Phase.forwarding
                  ? 'laeuft - ${(_elapsedMs / 1000).toStringAsFixed(0)} s'
                  : 'uebertragen'),
          _step(done, 'Bestaetigung vom zweiten Auge',
              done ? 'vollstaendig' : failed ? 'ausgeblieben' : 'wird geholt'),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              backgroundColor: Colors.white12,
              color: failed ? kWarn : (done ? kGood : kAccent),
            ),
          ),
          if (_note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_note, style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ],
      ),
      actions: [
        if (!done)
          TextButton(
            onPressed: () => _safePop('Im Hintergrund weiter - das Auge macht fertig'),
            child: const Text('Schliessen'),
          ),
      ],
    );
  }

  Widget _step(bool complete, String title, String state) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 22, height: 22,
            child: complete
                ? const Icon(Icons.check_circle, size: 18, color: kGood)
                : const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
          Text(state, style: const TextStyle(fontSize: 12, color: Colors.white38)),
        ],
      ),
    );
  }
}
