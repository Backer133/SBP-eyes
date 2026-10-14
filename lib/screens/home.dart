import 'package:flutter/material.dart';
import '../ble_service.dart';
import '../slot_metadata.dart';
import '../theme.dart';
import 'settings.dart';
import 'diagnostics.dart';
import 'cloud_eyes_screen.dart';
import 'lock_gate.dart';

class HomeScreen extends StatefulWidget {
  final EyeBle ble;
  const HomeScreen({super.key, required this.ble});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  /// Welches Auge die Auswahl im Raster betrifft.
  ///
  /// Liegt bewusst HIER und nicht im Raster selbst: der Reiterwechsel ersetzt den
  /// Bildschirm komplett (body: screens[_tab]), der Umschalter sprang dadurch bei
  /// jeder Rueckkehr auf "Beide" zurueck. Wer dann eine Kachel antippte, setzte
  /// unbeabsichtigt beide Augen.
  int _eyeTarget = EyeBle.kBeide;
  // Slot-Metadata Cache: [slot_idx] -> SlotMeta? (null = leer)
  final List<SlotMeta?> _slotMeta = List<SlotMeta?>.filled(kCloudSlotCount, null);

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBleUpdate);
    _loadSlotMetaAndClean();
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBleUpdate);
    super.dispose();
  }

  void _onBleUpdate() {
    // Wenn sich pair_id geaendert hat (Reconnect anderer Geraet) -> neu laden
    _loadSlotMeta();
    if (mounted) setState(() {});
  }

  /// Nimmt das Brennen zurueck, wo der Name es nicht mehr hergibt.
  ///
  /// Sonst entsteht eine Sackgasse: wer ein anderes Auge in einen Slot laedt,
  /// dessen Bit gesetzt war, haette ein flackerndes Auge ohne Schalter, um es
  /// abzustellen. Die Pruefung gehoert hierher und nicht in den Dienst - nur der
  /// Bildschirm kennt die Slot-Namen.
  Future<void> _flickerAufraeumen() async {
    final ble = widget.ble;
    int sauber = ble.flickerMask;
    for (int slot = 0; slot < kCloudSlotCount; slot++) {
      final id = kHardcodedEyeCount + slot;
      if (!ble.flickerBurns(id)) continue;
      final name = slot < _slotMeta.length ? _slotMeta[slot]?.name : null;
      // Kein Name bekannt -> nichts anruehren. Lieber ein Bit zu viel stehen
      // lassen als eine Einstellung wegwerfen, weil die Metadaten fehlen.
      if (name == null) continue;
      if (!EyeBle.flickerNameOk(name)) sauber &= ~(1 << id);
    }
    if (sauber != ble.flickerMask) await ble.setFlickerMask(sauber);
  }

  Future<void> _loadSlotMetaAndClean() async {
    await _loadSlotMeta();
    await _flickerAufraeumen();
  }

  Future<void> _loadSlotMeta() async {
    final pid = widget.ble.deviceId;
    for (int s = 0; s < kCloudSlotCount; s++) {
      _slotMeta[s] = await SlotMetadataStore.get(pid, s);
    }
    if (mounted) setState(() {});
  }

  /// Auswahl beim langen Druck auf einen Cloud-Slot.
  ///
  /// Frueher loeschte der lange Druck sofort. Dazu kommt jetzt "erneut senden": Bricht
  /// die Funkuebertragung ab - etwa weil eines der Augen neu startet - hat der Master das
  /// Bild vollstaendig, der Slave aber nicht. Ohne diesen Weg muesste man die 200 KB
  /// noch einmal komplett vom Handy hochladen, nur um eine Uebertragung anzustossen,
  /// die der Master allein erledigen kann.
  // ===== Vorlagen =====

  /// Sperre gegen Doppeltippen. Ein zweites Antippen waehrend des Ladens wuerde
  /// mitten in die Werte des ersten hineinschreiben.
  bool _templateBusy = false;

  String _templateLabel(int slot) {
    final t = widget.ble.templates[slot];
    return t.name.isNotEmpty ? '"${t.name}"' : 'Vorlage ${slot + 1}';
  }

  Future<void> _templateTap(int slot) async {
    if (_templateBusy) return;
    final t = widget.ble.templates[slot];
    if (!t.belegt) {
      await _templateSave(slot);
      return;
    }

    setState(() => _templateBusy = true);
    try {
      // Was die Vorlage gespeichert hat - vor dem Laden merken, um danach zu
      // erkennen, ob das Auge ersetzt werden musste.
      final gewuenscht = t.eyeId;
      final ok = await widget.ble.loadTemplate(slot);
      if (!mounted) return;
      if (!ok) {
        _snack(widget.ble.lastError ?? 'Vorlage konnte nicht geladen werden.',
            fehler: true);
        return;
      }
      // Die Firmware ersetzt eine tote Cloud-Nummer durch A7. Das sagen wir,
      // statt den Nutzer raetseln zu lassen - die Vorlage hat ja gewirkt.
      final tatsaechlich = widget.ble.eyeId[EyeBle.kMaster];
      if (gewuenscht != null && gewuenscht != tatsaechlich) {
        _snack('Das gespeicherte Auge ist nicht mehr vorhanden - '
            '${kEyeLabels[0]} wird gezeigt. Alle uebrigen Einstellungen wurden '
            'uebernommen.');
      } else {
        _snack('${_templateLabel(slot)} geladen.');
      }
    } finally {
      if (mounted) setState(() => _templateBusy = false);
    }
  }

  Future<void> _templateSave(int slot) async {
    final ok = await widget.ble.saveTemplate(slot);
    if (!mounted) return;
    _snack(ok
            ? 'Aktuelle Einstellungen in ${_templateLabel(slot)} gesichert.'
            : (widget.ble.lastError ?? 'Speichern fehlgeschlagen.'),
        fehler: !ok);
  }

  Future<void> _templateActions(int slot) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: Text(_templateLabel(slot),
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Umbenennen'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.save_outlined),
              title: const Text('Mit aktuellen Einstellungen ueberschreiben'),
              onTap: () => Navigator.pop(ctx, 'save'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Vorlage loeschen'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') await _templateRename(slot);
    if (action == 'save')   await _templateOverwrite(slot);
    if (action == 'delete') await _templateDelete(slot);
  }

  Future<void> _templateRename(int slot) async {
    final ctrl = TextEditingController(text: widget.ble.templates[slot].name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vorlage umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: kTemplateNameLen,
          decoration: const InputDecoration(hintText: 'z. B. Abend, Buehne, Ruhig'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (!mounted || name == null) return;
    final ok = await widget.ble.renameTemplate(slot, name);
    if (!mounted) return;
    _snack(ok ? 'Umbenannt.' : (widget.ble.lastError ?? 'Umbenennen fehlgeschlagen.'),
        fehler: !ok);
  }

  Future<void> _templateOverwrite(int slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_templateLabel(slot)} ueberschreiben?'),
        content: const Text(
            'Die gespeicherten Einstellungen werden durch die aktuellen ersetzt. '
            'Der Name bleibt.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ueberschreiben')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _templateSave(slot);
  }

  Future<void> _templateDelete(int slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_templateLabel(slot)} loeschen?'),
        content: const Text('Der Platz wird frei. Die Augen selbst bleiben, '
            'wie sie gerade eingestellt sind.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Loeschen')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final weg = await widget.ble.clearTemplate(slot);
    if (!mounted) return;
    _snack(weg ? 'Vorlage geloescht.' : (widget.ble.lastError ?? 'Loeschen fehlgeschlagen.'),
        fehler: !weg);
  }

  void _snack(String text, {bool fehler = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: fehler ? kBad : null,
      duration: Duration(seconds: fehler ? 6 : 3),
      content: Text(text),
    ));
  }

  Future<void> _slotActions(int slot) async {
    final name = _slotMeta[slot]?.name;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: Text(name != null ? '"$name"' : 'Cloud-Slot ${slot + 1}',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.cast_connected),
              title: const Text('Erneut ans zweite Auge senden'),
              subtitle: const Text('Wenn nur das erste Auge das Bild zeigt'),
              onTap: () => Navigator.pop(ctx, 'reforward'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Slot loeschen'),
              subtitle: const Text('Entfernt das Bild von beiden Augen'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete')    await _deleteSlot(slot);
    if (action == 'reforward') await _reforwardSlot(slot);
  }

  Future<void> _reforwardSlot(int slot) async {
    try {
      await widget.ble.reforwardEye(slot);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Wird ans zweite Auge gesendet. Das dauert etwa 10 Sekunden - '
                      'bitte die Verbindung so lange nicht trennen.'),
        duration: Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Konnte nicht senden: $e')),
      );
    }
  }

  Future<void> _deleteSlot(int slot) async {
    final pid = widget.ble.deviceId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cloud-Slot ${slot + 1} loeschen?'),
        content: Text(_slotMeta[slot] != null
            ? '"${_slotMeta[slot]!.name}" wird von beiden Augen entfernt.'
            : 'Slot wird auf beiden Augen geleert.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Loeschen')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.ble.deleteEye(slot);
      await SlotMetadataStore.clear(pid, slot);
      _slotMeta[slot] = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Slot ${slot + 1} geleert')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loesch-Fehler: $e')),
      );
    }
  }

  /// Hinweis, wenn das Auge nicht mehr antwortet, mit dem einzigen Weg heraus.
  ///
  /// Neu verbinden hilft wirklich: ein abgebrochener Vorgang bleibt im Browser
  /// anhaengig und belegt den Kanal, bis die Verbindung selbst neu aufgebaut wird.
  Widget _deadBanner(EyeBle ble) => Material(
        color: kBad.withOpacity(.18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.link_off, color: kBad, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Das Auge antwortet nicht mehr. Neu verbinden.',
                    style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () async {
                  await ble.disconnect(forget: true);
                  if (mounted) Navigator.of(context).pop();
                },
                child: const Text('Neu verbinden'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    final locked = ble.locked;
    final title = ble.deviceName.isNotEmpty
        ? ble.deviceName
        : (ble.device?.platformName.isNotEmpty == true
            ? ble.device!.platformName
            : 'Augenpaar');

    final screens = [
      _EyeGrid(
        ble: ble,
        slotMeta: _slotMeta,
        onSlotActions: _slotActions,
        target: _eyeTarget,
        onTargetChanged: (t) => setState(() => _eyeTarget = t),
        onTemplateTap: _templateTap,
        onTemplateActions: _templateActions,
      ),
      CloudEyesScreen(ble: ble, onSlotMetaChanged: _loadSlotMeta),
      SettingsScreen(ble: ble),
      DiagnosticsScreen(ble: ble),
    ];

    // Verbindungs-/Sperr-Indikator oben rechts.
    final Widget statusIcon;
    if (!ble.connected) {
      statusIcon = const _StatusDot(icon: Icons.bluetooth_disabled, color: kBad);
    } else if (locked) {
      statusIcon = const _StatusDot(icon: Icons.lock, color: kWarn);
    } else {
      statusIcon = const _StatusDot(icon: Icons.bluetooth_connected, color: kGood);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          statusIcon,
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Trennen',
            onPressed: () async {
              await ble.disconnect(forget: true);
              if (mounted) Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: locked
          ? LockGate(ble: ble)
          : Column(
              children: [
                // Ist der Kanal tot, scheitert ALLES Weitere - und zwar jedes Mal
                // mit derselben Frist. Das gehoert oben hin, nicht in eine
                // Meldung, die nach sechs Sekunden verschwindet.
                if (ble.channelDead) _deadBanner(ble),
                Expanded(child: screens[_tab]),
              ],
            ),
      bottomNavigationBar: locked
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) {
                setState(() => _tab = i);
                // Die Werte dieser Bildschirme werden erst beim Oeffnen geholt.
                // Beim Verbinden fielen sie weg, damit das Anmelden nicht auf
                // Daten wartet, die nur hier zu sehen sind (EyeBle.ensure*).
                if (i == 1) ble.ensureUpload();
                if (i == 3) ble.ensureDiag();
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.grid_view), label: 'Augen'),
                NavigationDestination(icon: Icon(Icons.cloud_download), label: 'Cloud'),
                NavigationDestination(icon: Icon(Icons.settings), label: 'Einstellungen'),
                NavigationDestination(icon: Icon(Icons.analytics), label: 'Diagnose'),
              ],
            ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _StatusDot({required this.icon, required this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

/// Augen-Grid: hardcoded Augen (Asset-Vorschau) + Cloud-Slots mit echter Bild-Vorschau.
class _EyeGrid extends StatelessWidget {
  final EyeBle ble;
  final List<SlotMeta?> slotMeta;
  final Future<void> Function(int slot) onSlotActions;
  /// Zustand liegt im Eltern-Bildschirm, damit er den Reiterwechsel ueberlebt.
  final int target;
  final void Function(int) onTargetChanged;
  /// Vorlage antippen: belegt = laden, leer = aktuellen Zustand speichern.
  final Future<void> Function(int slot) onTemplateTap;
  /// Langer Druck auf eine belegte Vorlage.
  final Future<void> Function(int slot) onTemplateActions;
  const _EyeGrid({
    required this.ble,
    required this.slotMeta,
    required this.onSlotActions,
    required this.target,
    required this.onTargetChanged,
    required this.onTemplateTap,
    required this.onTemplateActions,
  });

  /// Metadaten eines Cloud-Slots, oder null. Eigene Funktion, weil die
  /// Vorlagen-Kacheln dasselbe brauchen wie das Raster.
  SlotMeta? _slotMetaFor(int slot) =>
      (slot >= 0 && slot < slotMeta.length) ? slotMeta[slot] : null;

  int get _target => target;

  int get _totalCount => kHardcodedEyeCount + kCloudSlotCount;

  /// Klarname eines Augen-Index - fuer die Hinweiszeile, wenn die Augen verschieden sind.
  String _eyeName(int id) {
    if (id < kHardcodedEyeCount) return kEyeLabels[id];
    final slot = id - kHardcodedEyeCount;
    final meta = slot < slotMeta.length ? slotMeta[slot] : null;
    return meta?.name ?? 'Cloud ${slot + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final idMaster = ble.eyeId[EyeBle.kMaster];
    final idSlave  = ble.eyeId[EyeBle.kSlave];
    final gleich   = idMaster == idSlave;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: EyeBle.kBeide,  label: Text('Beide')),
              ButtonSegment(value: EyeBle.kMaster, label: Text('Auge 1')),
              ButtonSegment(value: EyeBle.kSlave,  label: Text('Auge 2')),
            ],
            selected: {_target},
            showSelectedIcon: false,
            onSelectionChanged: (s) => onTargetChanged(s.first),
          ),
        ),
        // IMMER sagen, was ein Tipp bewirkt. Ohne diese Zeile sieht man dem Raster
        // nicht an, ob die Auswahl ein Auge oder beide trifft - und setzt dann
        // versehentlich beide, obwohl man eines meinte.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            switch (_target) {
              EyeBle.kMaster => 'Tippen setzt nur Auge 1',
              EyeBle.kSlave  => 'Tippen setzt nur Auge 2',
              _              => 'Tippen setzt BEIDE Augen',
            },
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: _target == EyeBle.kBeide ? FontWeight.w400 : FontWeight.w700,
              color: _target == EyeBle.kBeide
                  ? Colors.white.withOpacity(.45)
                  : kAccent,
            ),
          ),
        ),
        // Bei "Beide" und unterschiedlichen Augen waere jede Markierung im Raster
        // gelogen - deshalb wird dort nichts markiert und stattdessen hier im Klartext
        // gesagt, was wo laeuft.
        if (_target == EyeBle.kBeide && !gleich)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Aktuell verschieden -  Auge 1: ${_eyeName(idMaster)}'
              '  -  Auge 2: ${_eyeName(idSlave)}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(.55)),
            ),
          ),
        Expanded(child: _grid(context)),
        _templateRow(context),
        _flickerRow(context, idMaster),
      ],
    );
  }

  /// Vier Vorlagen-Plaetze unter dem Raster.
  ///
  /// Tippen auf einen belegten Platz holt die Einstellungen zurueck - ein Klick,
  /// ohne Rueckfrage. Ein leerer Platz speichert den aktuellen Zustand. Alles
  /// Weitere (umbenennen, ueberschreiben, loeschen) liegt auf dem langen Druck,
  /// genau wie bei den Cloud-Slots.
  Widget _templateRow(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(.03),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Vorlagen',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                    color: Colors.white.withOpacity(.45))),
            const SizedBox(height: 6),
            Row(
              children: [
                for (int i = 0; i < kTemplateCount; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _templateTile(context, i)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _templateTile(BuildContext context, int slot) {
    final t = slot < ble.templates.length
        ? ble.templates[slot]
        : const EyeTemplateInfo(null, '');
    final beschriftung = t.name.isNotEmpty ? t.name : 'Vorlage ${slot + 1}';

    // Vorschaubild des gespeicherten Motivs. Macht die Plaetze unterscheidbar,
    // auch wenn noch kein Name vergeben wurde.
    Widget inhalt;
    if (!t.belegt) {
      inhalt = Icon(Icons.add, size: 20, color: Colors.white.withOpacity(.35));
    } else if (t.eyeId! < kHardcodedEyeCount) {
      inhalt = Image.asset(kEyeAssets[t.eyeId!], fit: BoxFit.cover);
    } else {
      final meta = _slotMetaFor(t.eyeId! - kHardcodedEyeCount);
      inhalt = meta != null
          ? Image.network(meta.tileUrl, fit: BoxFit.cover, cacheWidth: 120,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.cloud, size: 18, color: Colors.white.withOpacity(.4)))
          : Icon(Icons.cloud, size: 18, color: Colors.white.withOpacity(.4));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: Material(
            color: kSurface,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onTemplateTap(slot),
              onLongPress: t.belegt ? () => onTemplateActions(slot) : null,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: t.belegt
                          ? Colors.white.withOpacity(.10)
                          : Colors.white.withOpacity(.06)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Center(child: inhalt),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(beschriftung,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 10,
                color: Colors.white.withOpacity(t.belegt ? .75 : .35))),
      ],
    );
  }

  /// Schalter "brennt" fuer das Motiv, das Auge 1 gerade zeigt.
  ///
  /// Die Einstellung haengt am MOTIV, nicht am Geraet: beide Augen pruefen
  /// dieselbe Maske gegen das, was sie gerade zeigen. Zeigen sie verschiedene
  /// Motive, gilt sie entsprechend getrennt - deshalb steht der Name im Text und
  /// nicht nur "dieses Auge".
  Widget _flickerRow(BuildContext context, int id) {
    // Nur fuer Cloud-Augen, und dort nur fuer die Feuer-Motive: der Schalter
    // erscheint, wenn "Tot" im Namen steht. Siehe EyeBle.flickerNameOk.
    if (!EyeBle.flickerAllowed(id)) return const SizedBox.shrink();
    if (!EyeBle.flickerNameOk(_eyeName(id))) return const SizedBox.shrink();
    final an = ble.flickerBurns(id);
    return Material(
      color: Colors.white.withOpacity(.03),
      child: SwitchListTile(
        value: an,
        dense: true,
        secondary: Icon(Icons.local_fire_department,
            color: an ? kWarn : Colors.white.withOpacity(.30)),
        title: Text('"${_eyeName(id)}" brennt',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text('Helligkeit flackert wie ein Feuer',
            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(.5))),
        onChanged: (v) async {
          final ok = await ble.setFlicker(id, v);
          if (ok || !context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kBad,
            content: Text(ble.lastError ?? 'Konnte nicht gesetzt werden.'),
          ));
        },
      ),
    );
  }

  Widget _grid(BuildContext context) {
    final idMaster = ble.eyeId[EyeBle.kMaster];
    final idSlave  = ble.eyeId[EyeBle.kSlave];

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _totalCount,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemBuilder: (_, i) {
        final isCloud  = i >= kHardcodedEyeCount;
        final cloudSlot = isCloud ? (i - kHardcodedEyeCount) : -1;
        final meta = isCloud ? slotMeta[cloudSlot] : null;
        // Master meldet via CHR_SLOT_STATUS welche Slots auf der LittleFS belegt sind.
        // Wichtig nach Reinstall: lokale Metadaten weg, aber Master hat die Bilder noch.
        final occupied = isCloud && (ble.slotOccupiedMask & (1 << cloudSlot)) != 0;
        final selected = switch (_target) {
          EyeBle.kMaster => i == idMaster,
          EyeBle.kSlave  => i == idSlave,
          _              => i == idMaster && i == idSlave,   // "Beide": nur wenn gleich
        };
        return Container(
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? kAccent : Colors.white.withOpacity(.06),
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [BoxShadow(color: kAccent.withOpacity(.35), blurRadius: 16, spreadRadius: -2)]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                // Ergebnis ABWARTEN und einen Fehlschlag auch sagen. Vorher war
                // das ein blankes `() => ble.setEyeId(...)`: ging der Befehl
                // nicht durch, passierte nichts und niemand erfuhr warum.
                final ok = await ble.setEyeId(_target, i);
                if (ok || !context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  backgroundColor: kBad,
                  duration: const Duration(seconds: 6),
                  content: Text(ble.lastError ??
                      'Das Auge hat den Befehl nicht angenommen.'),
                ));
              },
              onLongPress: isCloud ? () => onSlotActions(cloudSlot) : null,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: isCloud
                          // tileUrl statt url: das kleine Vorschaubild (~5 KB) statt des
                          // vollen Auges (~1,5 MB). Bei vier belegten Slots waren das
                          // sonst rund 6 MB bei jedem Oeffnen - fuer vier Kacheln von
                          // 56 dp Kantenlaenge. Aeltere Eintraege ohne Vorschau liefern
                          // weiterhin das volle Bild.
                          ? (meta != null
                              ? Image.network(
                                  meta.tileUrl,
                                  fit: BoxFit.cover,
                                  cacheWidth: 200,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.broken_image),
                                )
                              : Container(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  child: Center(
                                    child: occupied
                                        // Reinstall-Fall: Master kennt den Slot noch, App nicht.
                                        // Reiner Text, kein Icon - User weiss "da ist was".
                                        ? Text('belegt',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context).colorScheme.onSurfaceVariant))
                                        // Echt leer: Cloud-Icon + Text (Originalverhalten).
                                        : Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.cloud,
                                                  size: 32,
                                                  color: Theme.of(context).colorScheme.outline),
                                              const SizedBox(height: 4),
                                              Text('leer',
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: Theme.of(context).colorScheme.outline)),
                                            ],
                                          ),
                                  ),
                                ))
                          : Image.asset(kEyeAssets[i], fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isCloud
                        ? (meta != null ? meta.name : 'Cloud ${cloudSlot + 1}')
                        : kEyeLabels[i],
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
              ),
            ),
          ),
        );
      },
    );
  }
}
