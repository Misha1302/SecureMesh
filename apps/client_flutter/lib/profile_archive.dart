import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'earlier_history.dart';
import 'local_client.dart' show initializeNativeBridge;
import 'src/rust/api.dart' as rust;

class ProfileArchiveAction extends StatelessWidget {
  const ProfileArchiveAction({super.key, required this.russian});
  final bool russian;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.history),
    label: Text(
      russian ? 'Посмотреть сохранённую историю' : 'View saved history',
    ),
    onPressed: () => Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => _ArchivePage(russian: russian)),
    ),
  );
}

class _ArchivePage extends StatefulWidget {
  const _ArchivePage({required this.russian});
  final bool russian;
  @override
  State<_ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<_ArchivePage>
    with WidgetsBindingObserver {
  final password = TextEditingController();
  Directory? scratch;
  String? snapshot, failure, account, archivePassword;
  List<dynamic>? chats;
  bool busy = false, reveal = false;
  String tr(String ru, String en) => widget.russian ? ru : en;
  static const limit = 512 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused || archivePassword == null) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((current) => current == route || current.isFirst);
    if (route.isCurrent && !route.isFirst) navigator.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    archivePassword = null;
    password.dispose();
    final directory = scratch;
    if (directory != null) _discard(directory);
    super.dispose();
  }

  Future<void> choose() async {
    setState(() {
      busy = true;
      failure = null;
    });
    Directory? work;
    XFile? picked;
    try {
      late final File copy;
      if (Platform.isAndroid) {
        const channel = MethodChannel('securemesh/profile-archive');
        final staged = await channel.invokeMethod<String>('pick');
        if (staged == null) return;
        copy = File(staged);
        work = copy.parent;
      } else {
        picked = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'SecureMesh (.db)',
              extensions: ['db'],
              mimeTypes: ['*/*'],
              uniformTypeIdentifiers: ['public.data'],
            ),
          ],
        );
        if (picked == null || !mounted) return;
        if (!picked.name.toLowerCase().endsWith('.db')) {
          throw const FormatException('extension');
        }
        for (final suffix in ['-wal', '-shm', '-journal']) {
          if (await File('${picked.path}$suffix').exists()) {
            throw const FormatException('sidecar');
          }
        }
        final length = await picked.length();
        if (length < 4096 || length > limit) {
          throw const FormatException('size');
        }
        work = await Directory.systemTemp.createTemp('securemesh-archive-');
        copy = File('${work.path}/snapshot.db');
        final output = copy.openWrite();
        var copied = 0;
        try {
          await for (final data in picked.openRead()) {
            copied += data.length;
            if (copied > length) throw const FormatException('size');
            await output.addStream(Stream.value(data));
          }
        } finally {
          await output.close();
        }
        if (copied != length) throw const FormatException('size');
      }
      if (!mounted) return;
      final previous = scratch;
      scratch = work;
      work = null;
      setState(() {
        snapshot = copy.path;
        password.clear();
        reveal = false;
      });
      if (previous != null) await previous.delete(recursive: true);
    } catch (e) {
      if (mounted) {
        setState(
          () => failure = e is FormatException && e.message == 'sidecar'
              ? tr(
                  'Рядом с базой найден журнал. Закройте приложение-источник и сделайте новую копию.',
                  'A journal exists beside this database. Close the source application and make a fresh copy.',
                )
              : tr(
                  'Не удалось прочитать файл. Выберите автономный файл .db размером до 512 МиБ.',
                  'Could not read this file. Select a standalone .db file up to 512 MiB.',
                ),
        );
      }
    } finally {
      if (work != null) await _discard(work);
      // UIDocumentPicker delivers an imported copy on iOS.
      // Desktop pickers return the original document, which must be preserved.
      if (picked != null && Platform.isIOS) {
        await _discard(File(picked.path));
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _discard(FileSystemEntity item) async {
    try {
      await item.delete(recursive: item is Directory);
    } on FileSystemException {
      // Application-private temporary storage is also eligible for OS cleanup.
    }
  }

  Future<Map<String, dynamic>> read([HistoryCursor? cursor]) async {
    final path = snapshot!;
    final request = jsonEncode({
      'op': 'archive_read',
      'passphrase': archivePassword ?? password.text,
      if (cursor != null) ...{'group': cursor['group'], 'cursor': cursor},
    });
    await initializeNativeBridge();
    return jsonDecode(await rust.command(path: path, request: request))
        as Map<String, dynamic>;
  }

  Future<void> unlock() async {
    if (busy || snapshot == null) return;
    setState(() {
      busy = true;
      failure = null;
      reveal = false;
    });
    try {
      final result = await read();
      if (mounted) {
        setState(() {
          chats = result['chats'] as List;
          account = result['username'] as String?;
          archivePassword = password.text;
          password.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => failure = tr(
            'Проверьте пароль и целостность файла SecureMesh.',
            'Check the password and the integrity of the SecureMesh file.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = chats;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Архив переписки', 'Conversation archive')),
      ),
      body: SafeArea(
        child: entries == null
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    tr(
                      'Выберите копию .db, сделанную после закрытия SecureMesh на исходном устройстве. Новые сообщения могут остаться в отдельном журнале WAL. По одному файлу полноту снимка проверить невозможно.',
                      'Choose a .db copy made after closing SecureMesh on the source device. Recent messages may still be in a separate WAL journal. One file alone cannot establish completeness.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy ? null : choose,
                    icon: const Icon(Icons.folder_open),
                    label: Text(tr('Выбрать файл .db', 'Choose .db file')),
                  ),
                  if (snapshot != null) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      enabled: !busy,
                      obscureText: !reveal,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (_) => unlock(),
                      decoration: InputDecoration(
                        labelText: tr('Пароль хранилища', 'Store passphrase'),
                        suffixIcon: IconButton(
                          tooltip: reveal
                              ? tr('Скрыть пароль', 'Hide password')
                              : tr('Показать пароль', 'Show password'),
                          icon: Icon(
                            reveal ? Icons.visibility_off : Icons.visibility,
                          ),
                          onPressed: () => setState(() => reveal = !reveal),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy ? null : unlock,
                      child: Text(tr('Открыть для чтения', 'Open read-only')),
                    ),
                  ],
                  if (busy) const LinearProgressIndicator(),
                  if (failure != null)
                    Text(
                      failure!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              )
            : ListView.builder(
                itemCount: entries.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return ListTile(
                      title: Text(
                        account ?? tr('Локальный профиль', 'Local profile'),
                      ),
                      subtitle: Text(
                        entries.isEmpty
                            ? tr(
                                'В снимке нет сохранённых сообщений.',
                                'This snapshot contains no saved messages.',
                              )
                            : tr(
                                'История на момент копирования · только чтение',
                                'History at the time of copying · read-only',
                              ),
                      ),
                    );
                  }
                  final entry = entries[i - 1] as Map;
                  final name =
                      entry['name'] as String? ??
                      tr('Переписка $i', 'Conversation $i');
                  return ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(name),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EarlierHistory(
                          initial: entry['cursor'] as HistoryCursor,
                          peer: name,
                          title: name,
                          read: read,
                          tr: tr,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
