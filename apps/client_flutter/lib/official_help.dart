import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

final _helpSite = Uri.https('misha1302.github.io', '/SecureMesh/');

class OfficialHelp extends StatelessWidget {
  const OfficialHelp({super.key, required this.russian});
  final bool russian;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.help_outline),
    label: Text(
      russian ? 'Помощь на сайте SecureMesh' : 'SecureMesh help website',
    ),
    onPressed: () async {
      try {
        if (await launchUrl(_helpSite, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (_) {
        // The URL remains available even without an installed browser.
      }
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(russian ? 'Сайт помощи' : 'Help website'),
          content: SelectableText(_helpSite.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(russian ? 'Закрыть' : 'Close'),
            ),
          ],
        ),
      );
    },
  );
}
