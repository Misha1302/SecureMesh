import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
import 'transport.dart';

final _unsafeProfileText = RegExp(
  r'[\x00-\x09\x0b-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
);

String? safeProfileText(Object? value, int limit, {bool multiline = false}) {
  if (value is! String ||
      value.runes.length > limit ||
      _unsafeProfileText.hasMatch(value) ||
      (!multiline && value.contains('\n'))) {
    return null;
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}

class ProfileTextEditor extends StatefulWidget {
  const ProfileTextEditor({
    super.key,
    required this.api,
    required this.russian,
  });
  final DisplayNameApi api;
  final bool russian;
  @override
  State<ProfileTextEditor> createState() => _ProfileTextEditorState();
}

class _ProfileTextEditorState extends State<ProfileTextEditor> {
  final bio = TextEditingController(), status = TextEditingController();
  int? revision;
  bool? visibleToPeers;
  bool busy = true, conflict = false;
  String? error;
  String tr(String ru, String en) => widget.russian ? ru : en;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    bio.dispose();
    status.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api('/v1/users/me/profile-text') as Map;
      if (!mounted) return;
      final version = result['revision'];
      if (version is! int || version < 0) throw const FormatException();
      bio.text = safeProfileText(result['bio'], 280, multiline: true) ?? '';
      status.text = safeProfileText(result['status'], 80) ?? '';
      final visibility = result['visibleToPeers'];
      if (visibility != null && visibility is! bool) {
        throw const FormatException();
      }
      visibleToPeers = visibility as bool?;
      revision = version;
      conflict = false;
    } catch (_) {
      if (mounted) {
        error = tr('Не удалось загрузить профиль.', 'Could not load profile.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final about = bio.text.trim(), note = status.text.trim();
    if ((about.isNotEmpty &&
            safeProfileText(about, 280, multiline: true) == null) ||
        (note.isNotEmpty && safeProfileText(note, 80) == null)) {
      setState(
        () => error = tr(
          'Проверьте длину и символы в полях.',
          'Check the length and characters in each field.',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = await widget.api(
        '/v1/users/me/profile-text',
        method: 'PUT',
        data: {
          'bio': about.isEmpty ? null : about,
          'status': note.isEmpty ? null : note,
          'revision': revision,
          if (visibleToPeers != null) 'visibleToPeers': visibleToPeers,
        },
      );
      if (visibleToPeers != null &&
          (response is! Map || response['visibleToPeers'] != visibleToPeers)) {
        throw const FormatException();
      }
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        conflict = failure is ApiFailure && failure.code == 'PROFILE_CHANGED';
        busy = false;
        error = conflict
            ? tr(
                'Профиль изменён на другом устройстве. Загрузите текущую версию перед редактированием.',
                'Another device changed this profile. Load the current version to edit it.',
              )
            : tr(
                'Не удалось сохранить профиль. Проверьте соединение и данные.',
                'Could not save profile. Check the connection and fields.',
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('О себе и статус', 'Bio and status')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const LinearProgressIndicator(),
          if (revision != null) ...[
            TextField(
              controller: bio,
              enabled: !busy,
              minLines: 2,
              maxLines: 4,
              maxLength: 280,
              decoration: InputDecoration(labelText: tr('О себе', 'Bio')),
            ),
            TextField(
              controller: status,
              enabled: !busy,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: tr('Текст статуса', 'Status message'),
              ),
            ),
            if (visibleToPeers != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  tr('Показывать собеседникам', 'Show to chat partners'),
                ),
                subtitle: Text(
                  tr(
                    'О себе и текст статуса в личных чатах.',
                    'Bio and status in private conversations.',
                  ),
                ),
                value: visibleToPeers!,
                onChanged: busy || conflict
                    ? null
                    : (value) => setState(() => visibleToPeers = value),
              ),
            Text(
              visibleToPeers != null
                  ? tr(
                      'Эти сведения хранятся на сервере. Уже просмотренный текст может остаться у собеседника.',
                      'These fields are stored on the server. Someone who has viewed them may have kept a copy.',
                    )
                  : tr(
                      'Эти поля видны серверу и участникам ваших подтверждённых личных чатов. Оставьте поле пустым, чтобы скрыть его.',
                      'Your server and the people in your established private chats can see these fields. Leave a field empty to hide it.',
                    ),
            ),
          ],
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(tr('Закрыть', 'Close')),
      ),
      if (!busy && (conflict || revision == null))
        TextButton(
          onPressed: load,
          child: Text(
            conflict
                ? tr('Загрузить текущую версию', 'Load current version')
                : tr('Повторить', 'Retry'),
          ),
        ),
      if (revision != null)
        FilledButton(
          onPressed: busy || conflict ? null : save,
          child: Text(tr('Сохранить', 'Save')),
        ),
    ],
  );
}

/// The profile request is made once per opening on a locally verified peer.
class PeerProfileText extends StatefulWidget {
  const PeerProfileText({super.key, required this.load, required this.russian});
  final Future<dynamic> Function() load;
  final bool russian;
  @override
  State<PeerProfileText> createState() => _PeerProfileTextState();
}

class _PeerProfileTextState extends State<PeerProfileText> {
  late Future<dynamic> response;
  @override
  void initState() {
    super.initState();
    response = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: response,
    builder: (context, snapshot) {
      String tr(String ru, String en) => widget.russian ? ru : en;
      if (snapshot.hasError) {
        return TextButton.icon(
          onPressed: () => setState(() => response = widget.load()),
          icon: const Icon(Icons.refresh),
          label: Text(
            tr('Повторить загрузку профиля', 'Retry profile details'),
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      if (snapshot.data is! Map) return const SizedBox.shrink();
      final result = snapshot.data as Map;
      final bio = safeProfileText(result['bio'], 280, multiline: true);
      final status = safeProfileText(result['status'], 80);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in [
            (tr('О себе', 'Bio'), bio),
            (tr('Текст статуса', 'Status message'), status),
          ])
            if (value != null) ...[
              const SizedBox(height: 12),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              SelectableText(value),
            ],
        ],
      );
    },
  );
}
