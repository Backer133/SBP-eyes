import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../ble_service.dart';
import '../theme.dart';
import 'pairing_screen.dart';
import 'eye_align_screen.dart';
import 'motion_screen.dart';

class SettingsScreen extends StatefulWidget {
  final EyeBle ble;
  const SettingsScreen({super.key, required this.ble});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // App-Version (aus dem Paket -> folgt automatisch der pubspec-Version).
  String _version = '';

  // Waehrend des Slider-Ziehens: lokaler Vorschauwert, bis losgelassen wird.
  // Je Auge einer, sonst wuerde das Ziehen am einen Regler den anderen mitbewegen.
  final List<int?> _brightnessPreview = [null, null];
  int _brightness(EyeBle ble, int target) =>
      _brightnessPreview[target] ?? ble.brightness[target];

  @override
  void initState() {
    super.initState();
    // Der Kopplungs-Zustand wird nicht mehr beim Verbinden mitgelesen (siehe
    // EyeBle.loadAll). Ohne diesen Aufruf stuende hier "Nicht gekoppelt",
    // obwohl das Paar gebunden ist.
    widget.ble.ensurePairState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = 'Version ${info.version} (Build ${info.buildNumber})');
      }
    } catch (_) {}
  }

  // Dialog fuer 6-stellige Code-Eingabe. Gibt die Zahl zurueck oder null.
  Future<int?> _promptCode(String title, String hint) async {
    final ctrl = TextEditingController();
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: hint, counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              Navigator.pop(ctx, (v != null && v >= 0 && v <= 999999) ? v : null);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeKey() async {
    final code = await _promptCode('Neuen Zugangscode setzen', '6-stellig, z.B. 123456');
    if (code == null) return;
    final ok = await widget.ble.changeDeviceKey(code);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Zugangscode geaendert und geprueft - gilt ab sofort'
          : 'Code NICHT geaendert - der alte gilt weiter'),
    ));
  }

  Future<void> _renameDevice() async {
    final ctrl = TextEditingController(text: widget.ble.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Augenpaar benennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 23,
          decoration: const InputDecoration(hintText: 'z.B. Augen Thomas'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final ok = await widget.ble.setDeviceName(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Name geaendert - beim naechsten Scan sichtbar'
          : 'Konnte Name nicht setzen (nicht autorisiert?)'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ble,
      builder: (context, _) {
        final ble = widget.ble;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ---- Augenpaar ----
            const SectionHeader('Augenpaar', icon: Icons.remove_red_eye),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: _iconBox(Icons.badge_outlined, kAccentGlow),
                title: Text(ble.deviceName.isEmpty ? 'Augenpaar' : ble.deviceName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Bluetooth-Name in der Geraeteliste'),
                trailing: FilledButton.tonalIcon(
                  onPressed: _renameDevice,
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Umbenennen'),
                ),
              ),
            ),

            // ---- Anzeige ----
            // Animation und Helligkeit gelten je Auge. Bei nur zwei Geraeten sind zwei
            // Schalter uebersichtlicher als ein Umschalter: man sieht beide Zustaende
            // gleichzeitig und muss zum Vergleichen nicht hin- und herwechseln.
            const SectionHeader('Anzeige', icon: Icons.tune),
            Card(
              child: Column(children: [
                _animSchalter(ble, EyeBle.kMaster, 'Animation Auge 1'),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _animSchalter(ble, EyeBle.kSlave, 'Animation Auge 2'),
              ]),
            ),
            Card(
              child: Column(children: [
                _helligkeit(ble, EyeBle.kMaster, 'Helligkeit Auge 1'),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _helligkeit(ble, EyeBle.kSlave, 'Helligkeit Auge 2'),
              ]),
            ),

            // ---- Einbau & Bewegung ----
            const SectionHeader('Einbau & Bewegung', icon: Icons.animation),
            Card(
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: _iconBox(Icons.crop_free, kAccentGlow),
                    title: const Text('Augen ausrichten',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Je Auge auf seine Maskenoeffnung einstellen'),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                    enabled: !ble.locked,
                    onTap: ble.locked ? null : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => EyeAlignScreen(ble: ble)),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: _iconBox(Icons.animation, kAccentGlow),
                    title: const Text('Bewegung & Blinzeln',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Gilt fuer beide Augen gemeinsam'),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                    enabled: !ble.locked,
                    onTap: ble.locked ? null : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => MotionScreen(ble: ble)),
                    ),
                  ),
                ],
              ),
            ),

            // ---- Zugangsschutz ----
            if (ble.authSupported) ...[
              const SectionHeader('Zugangsschutz', icon: Icons.shield_outlined),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: _iconBox(
                          ble.authorized ? Icons.lock_open : Icons.lock,
                          ble.authorized ? kGood : kWarn),
                      title: const Text('Status',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(ble.authorized
                          ? 'Steuerung freigeschaltet'
                          : 'Nicht autorisiert'),
                      trailing: StatusPill(
                        ble.authorized ? 'Autorisiert' : 'Gesperrt',
                        color: ble.authorized ? kGood : kWarn,
                        icon: ble.authorized ? Icons.check : Icons.lock,
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: _iconBox(Icons.password, kAccentGlow),
                      title: const Text('Zugangscode aendern',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: const Text('Neuen 6-stelligen Code fuer dieses Augenpaar'),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      onTap: _changeKey,
                    ),
                  ],
                ),
              ),
            ],

            // ---- Paar-Kopplung ----
            const SectionHeader('Augenpaar koppeln', icon: Icons.cable),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: _iconBox(ble.isBound ? Icons.link : Icons.link_off,
                                  ble.isBound ? kGood : kWarn),
                title: const Text('Slave koppeln',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(ble.isBound
                    ? 'Gekoppelt mit ${ble.boundMacStr}'
                    : 'Noch kein zweites Auge gekoppelt'),
                trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                enabled: !ble.locked,
                onTap: ble.locked
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PairingScreen(ble: ble),
                          ),
                        ),
              ),
            ),

            const SizedBox(height: 36),
            Center(
              child: Text(
                'Created by Thomas Paul for\nSchafberg-Pass Sankt Gilgen',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(.35),
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _version.isEmpty ? '' : _version,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(.30),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Ein Animations-Schalter fuer genau ein Auge.
  Widget _animSchalter(EyeBle ble, int target, String titel) {
    final an = ble.animEnabled[target] == 1;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: _iconBox(Icons.movie_filter_outlined, kAccentGlow),
      title: Text(titel, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(an ? 'Animation laeuft' : 'Auge zentriert (pausiert)'),
      value: an,
      activeColor: kAccent,
      onChanged: ble.locked ? null : (v) => ble.setAnimEnabled(target, v),
    );
  }

  /// Ein Helligkeitsregler fuer genau ein Auge.
  Widget _helligkeit(EyeBle ble, int target, String titel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconBox(Icons.brightness_6_outlined, kAccentGlow),
              const SizedBox(width: 12),
              Expanded(
                child: Text(titel,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text('${(_brightness(ble, target) * 100 / 255).round()} %',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
          Slider(
            // Untergrenze 10 statt 0: bei 0 waere das Display komplett dunkel und
            // der Regler kaum wiederzufinden.
            min: 10, max: 255,
            value: _brightness(ble, target).toDouble().clamp(10, 255),
            activeColor: kAccent,
            // Waehrend des Ziehens nur lokal anzeigen; gesendet wird beim Loslassen.
            // Jeder Write schreibt am Master NVS und schickt eine ConfigMsg an den
            // Slave - das soll nicht pro Pixel passieren.
            onChanged: ble.locked
                ? null
                : (v) => setState(() => _brightnessPreview[target] = v.round()),
            onChangeEnd: (v) {
              setState(() => _brightnessPreview[target] = null);
              ble.setBrightness(target, v.round());
            },
          ),
        ],
      ),
    );
  }

  Widget _iconBox(IconData icon, Color color) {
    return Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: color.withOpacity(.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}
