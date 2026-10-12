import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_version.dart';
import '../eye_log.dart';
import '../theme.dart';

/// Zeigt die Mitschrift aus [EyeLog] und legt sie auf Wunsch in die Zwischenablage.
///
/// Erreichbar vom Suchbildschirm aus - also auch dann, wenn das Verbinden gar
/// nicht erst zustande kommt. Das ist der Punkt: ein Protokoll, das man nur nach
/// erfolgreichem Verbinden sieht, hilft genau im wichtigsten Fall nicht.
class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protokoll'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(18),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Fassung $kAppVersion',
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withOpacity(.45))),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Leeren',
            onPressed: () => EyeLog.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: EyeLog.revision,
        builder: (context, _, __) {
          final lines = EyeLog.lines;
          if (lines.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Noch nichts aufgezeichnet.\n\n'
                  'Verbinde dich mit einem Augenpaar - jeder Lese-, Schreib- und '
                  'Abo-Vorgang landet hier, mit Dauer und Ausgang.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            itemCount: lines.length,
            itemBuilder: (_, i) {
              final l = lines[i];
              final schlecht = l.contains('FEHLER');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(
                  l,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: schlecht ? kBad : Colors.white.withOpacity(.85),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.copy_all),
        label: const Text('Kopieren'),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: EyeLog.text));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Protokoll in der Zwischenablage'),
          ));
        },
      ),
    );
  }
}
