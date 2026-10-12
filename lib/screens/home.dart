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
    _loadSlotMeta();
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
      body: locked ? LockGate(ble: ble) : screens[_tab],
      bottomNavigationBar: locked
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
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
  const _EyeGrid({
    required this.ble,
    required this.slotMeta,
    required this.onSlotActions,
    required this.target,
    required this.onTargetChanged,
  });

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
      ],
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
