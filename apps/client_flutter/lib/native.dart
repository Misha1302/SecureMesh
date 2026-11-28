import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'src/rust/api.dart';
import 'local_client.dart';
import 'session.dart';
import 'session_inactivity.dart';
import 'security_email_tile.dart';
import 'delivery_client.dart';
import 'conversation_drafts.dart';
import 'chat_background.dart';
import 'conversation_composer.dart';
import 'conversation_timeline.dart';
import 'attachment_transfer.dart';
import 'attachment_selection.dart';
import 'clipboard_photo.dart';
import 'desktop_file_drop.dart';
import 'voice_note.dart';
import 'private_call.dart';
import 'voice_wave.dart';
import 'video_message.dart';
import 'linux_notifications.dart';
import 'android_notifications.dart';
import 'notification_preferences.dart';
import 'message_markup.dart';
import 'history_search.dart';
import 'earlier_history.dart';
import 'saved_messages.dart';
import 'onboarding.dart';
import 'profile_files.dart';
import 'official_help.dart';
import 'profile_archive.dart';
import 'profile_biometrics.dart';
import 'desktop_profile_keyring.dart';
import 'account_removal.dart';
import 'account_credentials.dart';
import 'account_reauthentication.dart';
import 'account_setup.dart';
import 'account_hub.dart';
import 'identity_comparison.dart';
import 'messenger_theme.dart';
import 'linked_roster.dart';
import 'display_name.dart';
import 'device_tile.dart';
import 'other_sessions.dart';
import 'settings_hierarchy.dart';
import 'profile_photo.dart';
import 'profile_text.dart';
import 'transport.dart';

class CryptoFailure implements Exception {}

class ClientApp extends StatefulWidget {
  const ClientApp({super.key});
  @override
  State<ClientApp> createState() => _ClientAppState();
}

class _ClientAppState extends State<ClientApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  bool savingBackgroundLock = false;
  bool backgroundLockSaveFailed = false;
  bool? notificationBackend;
  bool changingNotifications = false;
  bool notificationSaveFailed = false;
  final androidNotifications = const AndroidNotifications();
  late final desktopNotifications = LinuxNotifications(
    bridge: Platform.isAndroid ? androidNotifications : null,
    allowsGroup: (group) =>
        NotificationPreferences.fromProfile(profile)
            .allows(group, DateTime.now()),
    allowed: () {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      return (Platform.isLinux || Platform.isAndroid) &&
          mounted &&
          store != null &&
          profile?['desktopNotifications'] == true &&
          !changingNotifications &&
          (lifecycle == AppLifecycleState.inactive ||
              lifecycle == AppLifecycleState.hidden ||
              lifecycle == AppLifecycleState.paused);
    },
    russian: () => ru,
    availability: (available) {
      if (mounted && store != null && notificationBackend != available) {
        setState(() => notificationBackend = available);
      }
    },
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(restoreAppearance());
    if (supportsVideoMessages) {
      unawaited(
        VideoScratch.root().then<void>((_) {}).catchError((Object _) {}),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      closeInlineMedia();
      if (directCall?.active == true) unawaited(directCall!.end());
    }
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused) &&
        store != null &&
        profile?['lockWhenHidden'] == true) {
      lock();
    }
    if (state == AppLifecycleState.resumed) unawaited(refreshPeerLabel());
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.detached) {
      desktopNotifications.cancel();
    }
  }

  final path = TextEditingController(
    text: Platform.environment['SECUREMESH_PROFILE'] ?? '',
  );
  final pass = TextEditingController();
  bool showUnlockPassword = false;
  ProfileFileInfo? selectedProfile;
  final composer = TextEditingController();
  ConversationDrafts? drafts;
  PrivateAttachments? attachments;
  VoicePlaybackPositions? voicePlaybackPositions;
  ({String id, Uint8List bytes})? inlineMedia;
  int mediaView = 0;
  void closeInlineMedia() {
    mediaView++;
    if (inlineMedia != null && mounted) setState(() => inlineMedia = null);
  }

  bool draftLoadFailed = false;
  int chatView = 0;
  Future<void> closingStore = Future.value();
  final chatScroll = ScrollController();
  bool showLocalUnlock = (Platform.environment['SECUREMESH_PROFILE'] ?? '')
      .trim()
      .isNotEmpty;
  bool sending = false;
  int generation = 0;
  int directoryRevision = 0;
  final directoryLabels = <(Object?, Object?, Object?), String>{};

  String get currentPeerLabel =>
      directoryLabels[(
        profile?['group'],
        profile?['peerDevice'],
        profile?['peerKey'],
      )] ??
      profile!['peerName'] as String;

  void updateDirectoryLabels(List<dynamic> rows) {
    if (!mounted || profile == null) return;
    final previous = profile?['group'] == null ? null : currentPeerLabel;
    directoryRevision++;
    directoryLabels.clear();
    for (final row in rows.whereType<Map>()) {
      final name = peerDisplayName(row['peerDisplayName']);
      if (name != null) {
        directoryLabels[(row['id'], row['peerDevice'], row['peerKey'])] = name;
      }
    }
    if (previous != null && previous != currentPeerLabel) setState(() {});
  }

  Future<void> refreshPeerLabel() async {
    final active = session;
    if (active == null || profile?['group'] == null) return;
    final revision = ++directoryRevision;
    try {
      final rows = await active.request('/v1/conversations') as List;
      if (mounted &&
          identical(active, session) &&
          revision == directoryRevision) {
        updateDirectoryLabels(rows);
      }
    } catch (_) {
      // The verified conversation remains usable with its stored username offline.
    }
  }

  String connectionState = "offline";
  String? sendError, deviceError;
  bool revokingDevice = false,
      labRemovalAvailable = false,
      removingLocal = false;
  int deviceLoad = 0;
  NativeClient? store;
  HttpClient? http;
  MeshTransport? transport;
  AccountSession? session;
  bool reauthenticating = false;
  SessionInactivity? sessionInactivity;
  NativeDelivery? delivery;
  Map<String, dynamic>? profile;
  List<dynamic> messages = [];
  Map<String, dynamic>? olderHistory, pinnedMessage;
  List<dynamic> devices = [];
  Timer? timer;
  bool busy = false,
      loading = false,
      choosing = false,
      online = false,
      lite = false,
      ru = true;
  String? error;
  int tab = 0, failures = 0;
  Future<void> profileWrites = Future.value();
  ThemeMode theme = ThemeMode.system;
  String tr(String a, String b) => ru ? a : b;
  int get queued => messages.where((m) => m['status'] == 'queued').length;
  Future<Map<String, dynamic>> crypto(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final epoch = generation;
    final current = store;
    if (current == null) throw CryptoFailure();
    try {
      final result = jsonDecode(
        await current.execute(request: jsonEncode({...args, 'op': op})),
      ) as Map<String, dynamic>;
      if (epoch != generation) throw CryptoFailure();
      return result;
    } catch (_) {
      throw CryptoFailure();
    }
  }

  PrivateCall? directCall;
  bool get callsForeground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  PrivateCall? bindCall(String group) {
    if (store == null || !callsForeground) return null;
    final verified = profile?['verifiedChats'] as Map?;
    final entry = verified?[group] as Map?;
    final selected =
        profile?['group'] == group && profile?['trustConfirmed'] == true;
    final peer = selected ? profile!['peerDevice'] : entry?['device'];
    final name = selected ? profile!['peerName'] : entry?['name'];
    if (peer is! String || name is! String) return null;
    final previous = directCall;
    if (previous?.group == group && previous?.peer == peer) return previous;
    if (previous?.active == true) return null;
    previous?.dispose();
    final next = PrivateCall(
      group,
      peer,
      name,
      (op, args) => crypto(op, args),
      () => unawaited(pump()),
    );
    directCall = next;
    next.addListener(() {
      if (mounted && identical(next, directCall)) setState(() {});
    });
    return next;
  }

  void releaseLocalStore() {
    directCall?.dispose();
    directCall = null;
    attachments?.dispose();
    attachments = null;
    voicePlaybackPositions = null;
    final current = store;
    final pending = drafts?.close();
    drafts = null;
    store = null;
    if (pending == null) {
      current?.dispose();
    } else {
      closingStore = pending.whenComplete(() => current?.dispose());
    }
  }

  Future<void> restoreDraft(String? group) async {
    closeInlineMedia();
    final active = drafts;
    if (active == null) return;
    if (directCall != null && directCall!.group != group) {
      directCall!.dispose();
      directCall = null;
    }
    attachments?.dispose();
    attachments = null;
    final currentSession = session;
    if (group != null && currentSession != null) {
      final current = PrivateAttachments(
        group,
        (op, args) => crypto(op, args),
        SessionBlobs(currentSession, group, (op, args) => crypto(op, args)),
        () {
          if (mounted && profile?['group'] == group) {
            unawaited(pump());
            unawaited(reload(follow: true).catchError((_) {}));
          }
        },
      );
      attachments = current;
      current.addListener(() {
        if (mounted && identical(current, attachments)) setState(() {});
      });
      unawaited(current.load());
    }
    final view = ++chatView;
    final restoring = active.select(group);
    if (mounted) {
      setState(() {
        messages = [];
        draftLoadFailed = false;
        sendError = null;
      });
    }
    try {
      await restoring;
    } catch (_) {
      if (mounted && identical(active, drafts) && chatView == view) {
        setState(() => draftLoadFailed = true);
      }
    }
    if (mounted && identical(active, drafts)) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    desktopNotifications.cancel();
    timer?.cancel();
    delivery?.close();
    transport?.close();
    session?.close();
    http?.close(force: true);
    releaseLocalStore();
    path.dispose();
    pass.dispose();
    composer.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  Future<void> unlock(
    BuildContext pageContext, {
    BiometricAction? biometric,
  }) async {
    if (loading || store != null || removingLocal) return;
    NativeClient? opening;
    final selectedPath = path.text.trim();
    var secret = pass.text;
    String? boundDevice;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await closingStore;
      if (!mounted) return;
      if (selectedPath.isEmpty || !await File(selectedPath).exists()) {
        throw const FileSystemException('PROFILE_FILE_MISSING');
      }
      final args = {'path': selectedPath, 'russian': ru};
      if (biometric == BiometricAction.forget) {
        if (DesktopProfileKeyring.supported) {
          await DesktopProfileKeyring.forget(selectedPath);
        } else {
          await profileBiometrics.invokeMethod<void>('forget', args);
        }
        return;
      }
      if (biometric == BiometricAction.unlock) {
        final wrapped = DesktopProfileKeyring.supported
            ? await DesktopProfileKeyring.unlock(selectedPath)
            : await profileBiometrics.invokeMapMethod<String, String>(
                'unlock',
                args,
              );
        boundDevice = wrapped?['deviceId'];
        secret = wrapped?['passphrase'] ?? '';
        if (boundDevice == null || secret.isEmpty) throw CryptoFailure();
      }
      if (!mounted || selectedPath != path.text.trim()) return;
      await initializeNativeBridge();
      opening = await NativeClient.open(path: selectedPath, passphrase: secret);
      if (!mounted) {
        opening.dispose();
        opening = null;
        return;
      }
      final setup = jsonDecode(
        await opening.execute(request: jsonEncode({'op': 'onboarding_state'})),
      ) as Map;
      if (setup['stage'] == 'prepared' || setup['stage'] == 'authenticated') {
        if (boundDevice != null) throw CryptoFailure();
        final originalPath = selectedPath;
        opening.dispose();
        opening = null;
        pass.clear();
        if (!mounted || !pageContext.mounted) return;
        setState(() => loading = false);
        await showAccount(
          pageContext,
          resumePath: originalPath,
          resumePassphrase: secret,
        );
        return;
      }
      final saved = jsonDecode(
        await opening.execute(request: jsonEncode({'op': 'profile'})),
      ) as Map<String, dynamic>;
      if (!mounted) {
        opening.dispose();
        opening = null;
        return;
      }
      if (boundDevice != null && saved['deviceId'] != boundDevice) {
        throw CryptoFailure();
      }
      if (biometric == BiometricAction.enable) {
        // The encrypted profile was successfully opened with the manually entered secret.
        if (DesktopProfileKeyring.supported) {
          await DesktopProfileKeyring.enable(
            selectedPath,
            saved['deviceId'] as String,
            secret,
          );
        } else {
          await profileBiometrics.invokeMethod<void>('enable', {
            ...args,
            'passphrase': secret,
            'deviceId': saved['deviceId'] as String,
          });
        }
      }
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          selectedPath != path.text.trim() ||
          (biometric != null &&
              (lifecycle == AppLifecycleState.paused ||
                  lifecycle == AppLifecycleState.hidden ||
                  lifecycle == AppLifecycleState.detached))) {
        opening.dispose();
        opening = null;
        return;
      }
      profile = saved;
      final unlocked = opening;
      store = unlocked;
      voicePlaybackPositions = VoicePlaybackPositions();
      opening = null;
      drafts = ConversationDrafts(
        composer,
        (operation, args) async {
          return jsonDecode(
            await unlocked.execute(
              request: jsonEncode({...args, 'op': operation}),
            ),
          ) as Map<String, dynamic>;
        },
        () {
          if (mounted) {
            setState(
              () => sendError = tr(
                'Не удалось сохранить черновик на устройстве.',
                'Could not save this draft on your device.',
              ),
            );
          }
        },
      );
      http = nativeHttpClient();
      session = AccountSession(
        http: http!,
        endpoint: Uri.parse(profile!['endpoint'] as String),
        profile: () => profile!,
        persist: (value) => persistProfile(value, sessionOnly: true),
      );
      sessionInactivity = SessionInactivity(session!.request);
      transport = MeshTransport(
        endpoint: Uri.parse(profile!['endpoint'] as String),
        device: profile!['deviceId'] as String,
        token: () => profile!['accessToken'] as String,
        http: http!,
        https: (route, {data}) => api(route, data: data),
      );
      delivery = NativeDelivery(
        crypto: crypto,
        transport: transport!,
        onRosterChange: approveIncomingRoster,
        onCallSignal: (group) {
          unawaited(bindCall(group)?.poll());
        },
        onIncomingText: (Platform.isLinux || Platform.isAndroid)
            ? desktopNotifications.incoming
            : null,
      );
      if ((Platform.isLinux || Platform.isAndroid) &&
          saved['desktopNotifications'] == true) {
        unawaited(desktopNotifications.probe());
      }
      pass.clear();
      await restoreDraft(saved['group'] as String?);
      if (!mounted || !identical(unlocked, store)) return;
      unawaited(refreshPeerLabel());
      await reload();
      timer?.cancel();
      unawaited(pump());
    } catch (cause) {
      opening?.dispose();
      transport?.close();
      session?.close();
      sessionInactivity = null;
      delivery?.close();
      transport = null;
      http?.close(force: true);
      releaseLocalStore();
      store = null;
      profile = null;
      error =
          cause is FileSystemException &&
              cause.message == 'PROFILE_FILE_MISSING'
          ? tr(
              'Файл профиля не найден. Выберите существующее хранилище.',
              'Profile file not found. Select an existing profile.',
            )
          : biometric == null
          ? tr(
              'Не удалось открыть профиль. Проверьте путь и пароль.',
              'Could not unlock this profile. Check the path and passphrase.',
            )
          : DesktopProfileKeyring.supported
          ? tr(
              'Связка ключей недоступна. Введите пароль локального профиля.',
              'Keyring unlock did not complete. Enter your local profile passphrase.',
            )
          : tr(
              'Действие с биометрией не завершено. Введите пароль хранилища и нажмите «Открыть профиль».',
              'Biometric action did not complete. Enter the store passphrase and choose Unlock profile.',
            );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> showAccount(
    BuildContext pageContext, {
    bool signIn = false,
    String? resumePath,
    String? resumePassphrase,
  }) => Navigator.of(pageContext).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AccountOnboarding(
        russian: ru,
        signIn: signIn,
        resumePath: resumePath,
        resumePassphrase: resumePassphrase,
        onReady: (created, secret) async {
          selectedProfile = null;
          path.text = created;
          pass.text = secret;
          await unlock(pageContext);
          if (store == null) throw CryptoFailure();
        },
      ),
    ),
  );

  int profileSelection = 0;
  void backToWelcome() {
    profileSelection++;
    setState(() {
      pass.clear();
      error = null;
      choosing = false;
      showUnlockPassword = false;
      showLocalUnlock = false;
    });
  }

  Future<void> openSavedProfile(BuildContext context) async {
    setState(() {
      showLocalUnlock = true;
      error = null;
    });
    if (path.text.isEmpty) {
      await chooseProfile(context, autoSelectOne: true);
    } else {
      final value = path.text;
      final info = await inspectProfile(
        File(value),
        await localProfileDirectory(),
      );
      if (mounted && path.text == value) setState(() => selectedProfile = info);
    }
  }

  Future<void> pickOriginalProfile(BuildContext pageContext) async {
    if (loading || choosing) return;
    setState(() => choosing = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'SecureMesh (.db)', extensions: ['db']),
        ],
      );
      if (!mounted || file == null) return;
      final info = await inspectProfile(
        File(file.path),
        await localProfileDirectory(),
      );
      if (!mounted) return;
      if (info == null) throw const FormatException('Invalid profile');
      setState(() {
        selectedProfile = info;
        path.text = info.file.path;
        pass.clear();
        showUnlockPassword = false;
        error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'Не удалось открыть выбранный файл профиля.',
            'Could not open the selected profile file.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> editProfileLabel(BuildContext pageContext) async {
    final info = selectedProfile;
    if (info == null) return;
    var name = info.alias ?? '';
    final value = await showDialog<String>(
      context: pageContext,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Метка на этом устройстве', 'Label on this device')),
        content: TextFormField(
          initialValue: name,
          maxLength: 48,
          onChanged: (v) => name = v,
          decoration: InputDecoration(
            helperMaxLines: 3,
            helperText: tr(
              'Метка видна до ввода пароля. Пример: «Рабочий».',
              'The label is visible before unlocking. For example, “Work”.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name),
            child: Text(tr('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (value == null || !mounted || path.text != info.file.path) return;
    try {
      final dir = await localProfileDirectory();
      await setProfileLabel(info.file, dir, value);
      final updated = await inspectProfile(info.file, dir);
      if (mounted && path.text == info.file.path) {
        setState(() => selectedProfile = updated);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'Не удалось сохранить метку.',
            'Could not save the label.',
          ),
        );
      }
    }
  }

  Future<void> chooseProfile(
    BuildContext pageContext, {
    bool autoSelectOne = false,
  }) async {
    if (loading || choosing) return;
    final selection = ++profileSelection;
    setState(() => choosing = true);
    try {
      final files = await localProfiles();
      if (!mounted || selection != profileSelection || !pageContext.mounted) {
        return;
      }
      if (files.isEmpty) {
        setState(
          () => error = tr(
            'Сохранённых профилей пока нет. Создайте аккаунт или войдите.',
            'There are no saved profiles yet. Create an account or sign in.',
          ),
        );
        return;
      }
      if (autoSelectOne && files.length == 1) {
        setState(() {
          selectedProfile = files.single;
          showUnlockPassword = false;
          path.text = files.single.file.path;
          pass.clear();
          error = null;
        });
        return;
      }
      final selected = await showDialog<ProfileFileInfo>(
        context: pageContext,
        builder: (context) => SimpleDialog(
          title: Text(tr('Сохранённые профили', 'Saved profiles')),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text(
                tr(
                  'Это закрытые хранилища переписки на этом устройстве. Выберите своё по метке и дате изменения, затем введите пароль.',
                  'These profiles hold encrypted chats on this device. Choose yours by its label and modification date, then enter the password.',
                ),
              ),
            ),
            for (final info in files)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(info.title(ru)),
                subtitle: Text(info.details(context, ru)),
                onTap: () => Navigator.pop(context, info),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('Отмена', 'Cancel')),
            ),
          ],
        ),
      );
      if (mounted && selection == profileSelection && selected != null) {
        setState(() {
          selectedProfile = selected;
          path.text = selected.file.path;
          pass.clear();
          showUnlockPassword = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted && selection == profileSelection) {
        setState(
          () => error = tr(
            'Не удалось прочитать список профилей. Проверьте доступ к папке или укажите файл вручную.',
            'Could not list profiles. Check folder access or enter the file path manually.',
          ),
        );
      }
    } finally {
      if (mounted && selection == profileSelection) {
        setState(() => choosing = false);
      }
    }
  }

  Future<void> reload({bool follow = false}) async {
    if (profile?['group'] == null) {
      if (mounted) setState(() => messages = []);
      return;
    }
    final group = profile!['group'];
    final view = chatView;
    final epoch = generation;
    final nearEnd =
        follow ||
        !chatScroll.hasClients ||
        chatScroll.position.extentAfter < 96;
    final previous = messages.isEmpty ? null : messages.last["id"];
    final result = await crypto('timeline', {'group': group, 'limit': 64});
    if (mounted && epoch == generation && view == chatView) {
      pinnedMessage = result['pinned'] as Map<String, dynamic>?;
      olderHistory = result['older'] as Map<String, dynamic>?;
      unseenId = result['unseenThrough'] as String?;
      unseenGroup = group as String;
      setState(() => messages = result['messages'] as List<dynamic>);
      final changed = messages.isNotEmpty && messages.last['id'] != previous;
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              epoch != generation ||
              view != chatView ||
              !chatScroll.hasClients) {
            return;
          }
          if (nearEnd) {
            chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
          }
        });
      }
    }
  }

  Future<void> persistProfile(
    Map<String, dynamic> value, {
    bool sessionOnly = false,
    Set<String>? removedFields,
    bool? notificationPreference,
    NotificationPreferences Function(NotificationPreferences)?
    updateNotificationPolicy,
    bool? backgroundLockPreference,
    bool? autoTranscribe,
    ({String? group, bool dark, String? color})? wallpaper,
    ({String? group, bool dark, int? value})? dimming,
  }) {
    final epoch = generation;
    final write = profileWrites.then((_) async {
      if (epoch != generation || profile == null) throw CryptoFailure();
      final updated = removedFields != null
          ? ({...profile!, ...value}
              ..removeWhere((key, _) => removedFields.contains(key)))
          : sessionOnly
          ? {...profile!, ...value}
          : {
              ...value,
              for (final key in [
                'accessToken',
                'refreshToken',
                'deviceId',
                'expiresIn',
              ])
                key: profile![key],
            };
      updated['transcribeOnOpen'] =
          autoTranscribe ?? (profile!['transcribeOnOpen'] == true);
      if (wallpaper != null) {
        updated['chatBackgrounds'] = updateChatBackground(
          profile,
          wallpaper.group,
          wallpaper.dark,
          wallpaper.color,
        );
      } else if (profile!.containsKey('chatBackgrounds')) {
        updated['chatBackgrounds'] = profile!['chatBackgrounds'];
      }
      if (dimming != null) {
        updated['chatDimming'] = updateChatDimming(
          profile,
          dimming.group,
          dimming.dark,
          dimming.value,
        );
      } else if (profile!.containsKey('chatDimming')) {
        updated['chatDimming'] = profile!['chatDimming'];
      }
      // Preserve a newer privacy choice across concurrent profile/session writes.
      if (updateNotificationPolicy != null) {
        updated[NotificationPreferences.key] = updateNotificationPolicy(
          NotificationPreferences.fromProfile(profile),
        ).toJson();
      } else if (profile!.containsKey(NotificationPreferences.key)) {
        updated[NotificationPreferences.key] =
            profile![NotificationPreferences.key];
      }
      updated['desktopNotifications'] =
          notificationPreference ?? (profile!['desktopNotifications'] == true);
      updated['lockWhenHidden'] =
          backgroundLockPreference ?? (profile!['lockWhenHidden'] == true);
      await crypto('profile_put', {'profile': updated});
      if (epoch != generation) throw CryptoFailure();
      final previousGroup = profile?['group'];
      profile = updated;
      if (previousGroup != updated['group']) {
        await restoreDraft(updated['group'] as String?);
      }
    });
    // Preserve the queue after a failed write; this caller still receives the failure.
    profileWrites = write.catchError((_) {});
    return write;
  }

  Future<dynamic> api(
    String route, {
    Map<String, dynamic>? data,
    String? method,
  }) async {
    final owner = session!;
    final epoch = generation;
    final access = profile?['accessToken'];
    try {
      return await owner.request(route, data: data, method: method);
    } on ApiFailure catch (failure) {
      if (failure.status == 401 &&
          mounted &&
          epoch == generation &&
          store != null &&
          profile?['accessToken'] == access &&
          connectionState != 'auth') {
        setState(requireSignIn);
      }
      rethrow;
    }
  }

  void requireSignIn() {
    online = false;
    connectionState = 'auth';
    error = null;
  }

  Future<void> signInAgain(BuildContext context) async {
    final owner = session;
    final original = profile;
    final epoch = generation;
    if (reauthenticating ||
        owner == null ||
        original == null ||
        !canReauthenticate(original)) {
      return;
    }
    void checkOwner() {
      if (!mounted ||
          epoch != generation ||
          store == null ||
          !identical(session, owner)) {
        throw CryptoFailure();
      }
    }

    final request = bindLoginRequest(owner.http, owner.endpoint);
    setState(() => reauthenticating = true);
    var signedIn = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AccountReauthenticationDialog(
          russian: ru,
          legacy: original['credentialVersion'] == 1,
          username: original['username'] as String,
          confirm: (password) async {
            checkOwner();
            final tokens = await reauthenticateDevice(
              profile: Map.of(profile!),
              endpoint: owner.endpoint,
              identity: await crypto('identity'),
              password: password,
              request: (route, {data, token, notFoundCode}) {
                checkOwner();
                return request(
                  route,
                  data: data,
                  token: token,
                  notFoundCode: notFoundCode,
                );
              },
              sign: (payload) => crypto('sign', {'payload': payload}),
            );
            checkOwner();
            await owner.replaceTokens(tokens);
            checkOwner();
            setState(() {
              sessionInactivity = SessionInactivity(owner.request);
              connectionState = 'offline';
              error = null;
              deviceError = null;
              failures = 0;
            });
            signedIn = true;
          },
        ),
      );
    } finally {
      if (mounted && epoch == generation) {
        setState(() => reauthenticating = false);
        if (signedIn && tab == 1) unawaited(loadDevices());
        unawaited(pump());
      }
    }
  }

  List<String> get deliveryGroups {
    final active = profile?['group'];
    final verified = profile?['verifiedChats'];
    return {
      if (active is String) active,
      if (verified is Map) ...verified.keys.whereType<String>(),
      if (profile?['lastDeliveryGroup'] case final String previous) previous,
    }.toList();
  }

  final declinedRoster = <String>{};

  Future<void> approveIncomingRoster(String group, Map change) async {
    final context = navigator.currentContext;
    final epoch = generation;
    final t = change['transition'] as Map;
    if (context == null ||
        !callsForeground ||
        t['group'] != group ||
        declinedRoster.contains(t['id'])) {
      throw CryptoFailure();
    }
    final certificate = Map<String, dynamic>.from(
      change['certificate'] as Map? ?? {},
    );
    final local = await crypto('roster_state', {'group': group});
    String? key;
    if (t['action'] == 'add') {
      final parts = utf8
          .decode(base64Decode(certificate['payload'] as String))
          .split('\n');
      if (parts.length != 8 || parts[2] != t['device']) throw CryptoFailure();
      key = parts[3];
    } else {
      key =
          (local['members'] as List)
                  .where((m) => m['device'] == t['device'])
                  .firstOrNull?['key']
              as String?;
    }
    if (key == null ||
        t['epoch'] != local['epoch'] ||
        epoch != generation ||
        !context.mounted) {
      throw CryptoFailure();
    }
    final description =
        "${t['action']} ${t['device']}\n$key\n${t['committer']}";
    if (!await confirmRosterChange(
          context,
          group: group,
          description: description,
          tr: tr,
        ) ||
        epoch != generation) {
      if (epoch == generation) declinedRoster.add(t['id'] as String);
      throw CryptoFailure();
    }
    await crypto('roster_approve', {
      'group': group,
      'device': t['device'],
      'epoch': t['epoch'],
      'action': t['action'],
      'approver': t['committer'],
      ...certificate,
      'confirmed': true,
    });
  }

  Future<void> pump() async {
    final groups = deliveryGroups;
    if (busy ||
        reauthenticating ||
        connectionState == 'auth' ||
        store == null ||
        !mounted ||
        groups.isEmpty) {
      return;
    }
    final epoch = generation;
    busy = true;
    timer?.cancel();
    var nextDelay = const Duration(seconds: 3);
    try {
      final progress = await delivery!.tick(
        groups.first,
        listedGroups: groups.length > 1 ? groups : const [],
      );
      if (!mounted || epoch != generation) return;
      nextDelay = progress.delay;
      failures = 0;
      online = progress.connected;
      connectionState = online ? 'connected' : 'offline';
      lite = progress.weak || delivery!.receiptError != null;
      if (callsForeground) unawaited(directCall?.poll());
      if (online && profile?['trustConfirmed'] == true) {
        unawaited(attachments?.resume(explicit: false, weak: lite));
      }
      error = null;
    } catch (failure) {
      if (epoch != generation) return;
      online = false;
      failures++;
      if (failure is CryptoFailure) {
        connectionState = 'keys';
        error = tr(
          'Ошибка ключей или хранилища. Событие не подтверждено; проверьте профиль.',
          'Key or storage error. The event was not acknowledged; check this profile.',
        );
      } else if (failure is ApiFailure && failure.status == 401) {
        requireSignIn();
      } else if (failure is ApiFailure) {
        connectionState = 'server';
        error = tr(
          'Сервер отклонил запрос. Очередь сохранена; повторите соединение.',
          'Server rejected the request. Your queue is saved; reconnect to retry.',
        );
      } else {
        connectionState = 'offline';
        error = tr(
          'Нет связи с сервером. Очередь сохранена.',
          'Cannot reach the server. Your queue is saved.',
        );
      }
    } finally {
      if (epoch == generation) {
        if (store != null && profile != null) {
          try {
            await reload();
          } catch (_) {
            online = false;
            connectionState = 'keys';
            failures++;
            error = tr(
              'Локальное хранилище недоступно. Заблокируйте профиль и откройте его снова.',
              'Local store is unavailable. Lock and reopen this profile.',
            );
          }
        }
        busy = false;
        if (mounted && store != null && deliveryGroups.isNotEmpty) {
          setState(() {});
          if (connectionState != 'auth') {
            final delay = failures == 0
                ? nextDelay
                : Duration(seconds: min(30, 1 << min(failures, 5)));
            timer = Timer(
              delay +
                  Duration(
                    milliseconds: Random().nextInt(
                      delay.inMilliseconds < 1000 ? 100 : 600,
                    ),
                  ),
              () => unawaited(pump()),
            );
          }
        }
      }
    }
  }

  String messageId() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> send() async {
    final text = composer.text.trim();
    final epoch = generation;
    final group = profile?['group'] as String?;
    final active = drafts;
    if (sending ||
        text.isEmpty ||
        group == null ||
        active == null ||
        !active.readyFor(group) ||
        profile?['trustConfirmed'] != true) {
      return;
    }
    bool persisted = false;
    setState(() {
      sending = true;
      sendError = null;
    });
    try {
      await active.enqueue(group, messageId());
      persisted = true;
      if (epoch != generation || profile?['group'] != group) return;
      unawaited(pump());
      await reload(follow: true);
    } catch (_) {
      if (mounted && epoch == generation && profile?['group'] == group) {
        setState(
          () => sendError = persisted
              ? tr(
                  'Сообщение в очереди. Экран не обновился; откройте профиль снова.',
                  'Message is queued. The view could not refresh; reopen this profile.',
                )
              : tr(
                  'Сообщение не сохранено. Проверьте ключи и повторите отправку.',
                  'Message was not saved. Check your keys and send again.',
                ),
        );
      }
    } finally {
      if (mounted && epoch == generation) setState(() => sending = false);
    }
  }

  void lock() {
    closeInlineMedia();
    generation++;
    directoryLabels.clear();
    declinedRoster.clear();
    navigator.currentState?.popUntil((route) => route.isFirst);
    savingBackgroundLock = backgroundLockSaveFailed = false;
    desktopNotifications.cancel();
    changingNotifications = notificationSaveFailed = false;
    notificationBackend = null;
    timer?.cancel();
    delivery?.close();
    transport?.close();
    session?.close();
    sessionInactivity = null;
    transport = null;
    http?.close(force: true);
    releaseLocalStore();
    setState(() {
      store = null;
      showLocalUnlock = true;
      profile = null;
      messages = [];
      devices = [];
      composer.clear();
      showUnlockPassword = false;
      pass.clear();
      error = null;
      sendError = null;
      deviceError = null;
      revokingDevice = false;
      labRemovalAvailable = false;
      online = false;
      lite = false;
      busy = false;
      sending = false;
      reauthenticating = false;
      failures = 0;
      connectionState = "offline";
    });
  }

  Future<void> verifyKeys(BuildContext context) async {
    final selected = profile;
    final group = selected?['group'];
    final peer = selected?['peerDevice'];
    final key = selected?['peerKey'];
    if (group is! String || peer is! String || key is! String) return;
    final view = chatView;
    final epoch = generation;
    bool current() =>
        mounted &&
        generation == epoch &&
        chatView == view &&
        profile?['peerDevice'] == peer &&
        profile?['peerKey'] == key &&
        profile?['group'] == group;
    try {
      final me = await crypto('identity');
      if (!context.mounted || !current()) return;
      if (!await compareDeviceKey(
            context,
            me['public_key'] as String,
            key,
            tr,
          ) ||
          !current()) {
        return;
      }
      await crypto('pin', {
        'identity': peer,
        'public_key': key,
        'confirmed': true,
      });
      if (!current()) return;
      await persistProfile({...profile!, 'trustConfirmed': true});
      if (current()) setState(() {});
    } catch (_) {
      if (context.mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Не удалось подтвердить ключ. Попробуйте ещё раз.',
                'Key verification failed. Try again.',
              ),
            ),
          ),
        );
      }
    }
  }

  String? unseenId, unseenGroup;
  bool markingSeen = false;

  void markConversationSeen(BuildContext context) {
    final id = unseenId;
    final group = unseenGroup;
    if (markingSeen ||
        id == null ||
        group == null ||
        profile?['group'] != group ||
        tab != 0 ||
        !callsForeground ||
        ModalRoute.of(context)?.isCurrent != true ||
        !chatScroll.hasClients ||
        chatScroll.position.extentAfter > 2) {
      return;
    }
    markingSeen = true;
    unawaited(
      crypto('conversation_seen', {'group': group, 'id': id})
          .then((_) {
            if (unseenGroup == group && unseenId == id) unseenId = null;
          })
          .catchError((_) {})
          .whenComplete(() => markingSeen = false),
    );
  }

  Future<void> leaveConversation() async {
    if (busy || sending || profile?['group'] == null) return;
    timer?.cancel();
    await persistProfile(
      {
        ...profile!,
        if (profile!['trustConfirmed'] == true)
          'lastDeliveryGroup': profile!['group'],
      }..remove('group'),
    );
    if (mounted) {
      setState(() => messages = []);
      unawaited(pump());
    }
  }

  Widget directory() => AccountHub(
    russian: ru,
    profile: profile!,
    crypto: crypto,
    api: (route, {data}) => api(route, data: data),
    channelApi: session!.request,
    onDirectory: updateDirectoryLabels,
    onMute: (Platform.isAndroid || Platform.isLinux)
        ? (group, muted) =>
              changeNotificationPolicy((prefs) => prefs.setMute(group, muted))
        : null,
    mediaAttachments: (group) {
      final activeSession = session!;
      final activeGeneration = generation;
      Future<Map<String, dynamic>> command(
        String op,
        Map<String, dynamic> args,
      ) {
        if (activeGeneration != generation ||
            !identical(activeSession, session)) {
          throw CryptoFailure();
        }
        return crypto(op, args);
      }

      return PrivateAttachments(
        group,
        command,
        SessionBlobs(activeSession, group, command),
        () {},
      );
    },
    saveProfile: persistProfile,
    saveChanges: (changes, removed) =>
        persistProfile(changes, removedFields: removed),
    openChat: (group, peer, name, key) async {
      if (profile?['group'] == group &&
          profile?['peerDevice'] == peer &&
          profile?['peerKey'] == key &&
          profile?['trustConfirmed'] == true) {
        return;
      }
      if (sending || attachments?.busy == true || directCall?.active == true) {
        throw StateError('Conversation operation in progress');
      }
      await persistProfile({
        ...profile!,
        'group': group,
        'peerDevice': peer,
        'peerName': name,
        'peerKey': key,
        'trustConfirmed': true,
        'verifiedChats': {
          ...?profile!['verifiedChats'] as Map?,
          group: {'device': peer, 'key': key, 'name': name},
        },
      });
      unawaited(refreshPeerLabel());
      await reload();
      if (mounted) setState(() {});
      unawaited(pump());
    },
  );

  Future<void> setChatStyle(String key, Object value) async {
    final epoch = generation;
    try {
      await persistProfile({key: value}, removedFields: {});
      if (mounted && generation == epoch) setState(() {});
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() => appearanceSaveFailed = true);
      }
    }
  }

  Widget conversationPane(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) markConversationSeen(context);
    });
    final scheme = Theme.of(context).colorScheme;
    final background = chatBackgroundColor(
      scheme,
      chatBackground(
        profile,
        profile?['group'] as String?,
        scheme.brightness == Brightness.dark,
      ),
      dimming: chatDimming(
        profile,
        profile?['group'] as String?,
        scheme.brightness == Brightness.dark,
      ),
    );
    final factor = switch (profile?['chatTextSize']) {
      'larger' => 1.15,
      'largest' => 1.3,
      _ => 1.0,
    };
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        markConversationSeen(context);
        return false;
      },
      child: ColoredBox(
        color: background,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: ChatTextScaler(
              MediaQuery.textScalerOf(context),
              factor,
            ),
          ),
          child: Builder(builder: chat),
        ),
      ),
    );
  }

  void selectTab(int value) {
    setState(() => tab = value);
    if (value == 1) unawaited(loadDevices());
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    title: 'SecureMesh',
    debugShowCheckedModeBanner: false,
    themeMode: theme,
    theme: messengerTheme(Brightness.light),
    darkTheme: messengerTheme(Brightness.dark),
    builder: (context, child) => SessionActivityBoundary(
      onActivity: () {
        if (store != null &&
            connectionState != 'auth' &&
            profile?['trustState'] != 'DEVICE_PENDING_TRUST') {
          unawaited(sessionInactivity?.recordActivity());
        }
      },
      child: child!,
    ),
    home: Builder(
      builder: (ctx) {
        final width = MediaQuery.sizeOf(ctx).width;
        final inChat = store != null && profile?['group'] != null && tab == 0;
        final wide = width >= 980;
        final rail = width >= 760 && store != null;
        final compactChat = inChat && !rail;
        return PopScope(
          canPop:
              !compactChat && tab == 0 && (store != null || !showLocalUnlock),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (compactChat) {
              unawaited(leaveConversation());
            } else if (tab != 0) {
              if (settingsNavigation.currentState?.backToMenu() == true) return;
              selectTab(0);
            } else if (store == null) {
              backToWelcome();
            }
          },
          child: Scaffold(
            appBar: compactChat
                ? null
                : AppBar(
                    title: const Text('SecureMesh'),
                    actions: [
                      if (store == null)
                        TextButton(
                          onPressed: loading
                              ? null
                              : () => changeAppearance(russian: !ru),
                          child: const Text('RU / EN'),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Center(
                            child: Text(tr('Локальная альфа', 'Local alpha')),
                          ),
                        ),
                    ],
                  ),
            body: SafeArea(
              child: store == null
                  ? (showLocalUnlock ? unlockScreen(ctx) : welcomeScreen(ctx))
                  : Row(
                      children: [
                        if (rail)
                          NavigationRail(
                            selectedIndex: tab,
                            onDestinationSelected: selectTab,
                            labelType: NavigationRailLabelType.all,
                            destinations: [
                              NavigationRailDestination(
                                icon: const Icon(Icons.forum_outlined),
                                label: Text(tr('Чаты', 'Chats')),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.settings_outlined),
                                label: Text(tr('Настройки', 'Settings')),
                              ),
                            ],
                          ),
                        Expanded(
                          child: Column(
                            children: [
                              if (connectionState == 'auth')
                                ListTile(
                                  title: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      tr(
                                        'Сеанс завершён. Очередь сообщений сохранена.',
                                        'Your session ended. Your message queue is saved.',
                                      ),
                                    ),
                                  ),
                                  trailing: canReauthenticate(profile!)
                                      ? TextButton(
                                          onPressed: reauthenticating
                                              ? null
                                              : () => signInAgain(ctx),
                                          child: Text(
                                            tr('Войти снова', 'Sign in again'),
                                          ),
                                        )
                                      : null,
                                  subtitle: canReauthenticate(profile!)
                                      ? null
                                      : Text(
                                          tr(
                                            'Для повторного входа этому профилю не хватает данных аккаунта.',
                                            'This profile is missing the account details required to sign in again.',
                                          ),
                                        ),
                                ),
                              if (directCall case final PrivateCall current)
                                CallPanel(current, tr),
                              Expanded(
                                child: tab == 1
                                    ? settings(ctx)
                                    : wide
                                    ? Row(
                                        children: [
                                          SizedBox(
                                            width: (width * .31)
                                                .clamp(310.0, 410.0)
                                                .toDouble(),
                                            child: directory(),
                                          ),
                                          const VerticalDivider(width: 1),
                                          Expanded(
                                            child: inChat
                                                ? conversationPane(ctx)
                                                : Center(
                                                    child: Text(
                                                      tr(
                                                        'Выберите переписку',
                                                        'Select a conversation',
                                                      ),
                                                    ),
                                                  ),
                                          ),
                                        ],
                                      )
                                    : inChat
                                    ? conversationPane(ctx)
                                    : directory(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
            bottomNavigationBar: store != null && !rail && !compactChat
                ? NavigationBar(
                    selectedIndex: tab,
                    onDestinationSelected: selectTab,
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(Icons.forum_outlined),
                        label: tr('Чаты', 'Chats'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.settings_outlined),
                        label: tr('Настройки', 'Settings'),
                      ),
                    ],
                  )
                : null,
          ),
        );
      },
    ),
  );
  Widget welcomeScreen(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Icon(
                    Icons.forum_rounded,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    size: 34,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              tr('Добро пожаловать в SecureMesh', 'Welcome to SecureMesh'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'Личные сообщения защищены сквозным шифрованием.',
                'Personal messages use end-to-end encryption.',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => showAccount(context),
              child: Text(tr('Создать аккаунт', 'Create account')),
            ),
            OutlinedButton(
              onPressed: () => showAccount(context, signIn: true),
              child: Text(
                tr('Войти на этом устройстве', 'Sign in on this device'),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add_to_home_screen_outlined),
              label: Text(
                tr('Подключить новое устройство', 'Link a new device'),
              ),
              onPressed: () => showAccount(context, signIn: true),
            ),
            TextButton(
              onPressed: () => openSavedProfile(context),
              child: Text(
                tr('Открыть сохранённый профиль', 'Open a saved profile'),
              ),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(tr('Как вернуть доступ', 'Regain access')),
                  content: SingleChildScrollView(
                    child: Text(
                      tr(
                        'Если профиль сохранился, откройте его с паролем хранилища. На новом устройстве войдите в аккаунт и подтвердите подключение со старого устройства. Старая история при подключении не переносится. Если все ключи потеряны, сервер не сможет восстановить переписку.',
                        'If you still have your profile, open it with its store passphrase. To link a new device, sign in and approve it from your existing device. Linking does not transfer earlier messages. If all keys are lost, the server cannot recover your conversations.',
                      ),
                    ),
                  ),
                  actions: [
                    ProfileArchiveAction(russian: ru),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(tr('Закрыть', 'Close')),
                    ),
                  ],
                ),
              ),
              child: Text(tr('Как вернуть доступ', 'Regain access')),
            ),
            OfficialHelp(russian: ru),
          ],
        ),
      ),
    ),
  );

  Widget unlockScreen(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.lock_outline,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                tr('Откройте свой профиль', 'Unlock your profile'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Ключи и очередь хранятся на этом устройстве в зашифрованной базе.',
                  'Keys and your queue stay in an encrypted database on this device.',
                ),
              ),
              const SizedBox(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(
                  path.text.isEmpty
                      ? tr('Выбрать профиль', 'Choose a profile')
                      : (selectedProfile?.title(ru) ??
                            File(path.text).uri.pathSegments.last),
                ),
                subtitle: selectedProfile == null
                    ? null
                    : Text(selectedProfile!.details(context, ru)),
                trailing: const Icon(Icons.expand_more),
                onTap: loading || choosing
                    ? null
                    : () => chooseProfile(context),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  tr('Файл и метка профиля', 'Profile file and label'),
                ),
                children: [
                  ProfileArchiveAction(russian: ru),
                  if (selectedProfile != null)
                    TextButton.icon(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: loading || choosing
                          ? null
                          : () => editProfileLabel(context),
                      label: Text(
                        tr('Изменить местную метку', 'Edit local label'),
                      ),
                    ),
                  if (Platform.isLinux ||
                      Platform.isWindows ||
                      Platform.isMacOS)
                    TextButton.icon(
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: loading || choosing
                          ? null
                          : () => pickOriginalProfile(context),
                      label: Text(
                        tr(
                          'Найти файл профиля на диске',
                          'Browse for the original profile file',
                        ),
                      ),
                    ),
                  TextField(
                    controller: path,
                    onChanged: (_) => setState(() {
                      selectedProfile = null;
                      pass.clear();
                      showUnlockPassword = false;
                      error = null;
                    }),
                    enabled: !loading && !choosing,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr('Файл профиля', 'Profile file'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                enabled: !loading && !choosing,
                controller: pass,
                obscureText: !showUnlockPassword,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => unlock(context),
                decoration: InputDecoration(
                  labelText: tr('Пароль хранилища', 'Store passphrase'),
                  suffixIcon: IconButton(
                    tooltip: showUnlockPassword
                        ? tr('Скрыть пароль', 'Hide password')
                        : tr('Показать пароль', 'Show password'),
                    icon: Icon(
                      showUnlockPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(
                      () => showUnlockPassword = !showUnlockPassword,
                    ),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: loading ? null : () => unlock(context),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    loading
                        ? tr('Открываем…', 'Unlocking…')
                        : tr('Открыть профиль', 'Unlock profile'),
                  ),
                ),
              ),
              if (Platform.isAndroid ||
                  Platform.isIOS ||
                  DesktopProfileKeyring.supported)
                ProfileBiometricActions(
                  desktopKeyring: DesktopProfileKeyring.supported,
                  path: path,
                  disabled: loading || choosing,
                  russian: ru,
                  perform: (action) => unlock(context, biometric: action),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: loading ? null : backToWelcome,
                child: Text(tr('К выбору способа входа', 'Back to welcome')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> chooseAttachment(
    BuildContext context, {
    bool clipboardPhoto = false,
    List<dynamic>? droppedPaths,
  }) async {
    final current = attachments;
    if (current == null || current.busy || profile?['trustConfirmed'] != true) {
      return;
    }
    await current.stageSelection(() async {
      bool active() =>
          context.mounted &&
          identical(attachments, current) &&
          profile?['trustConfirmed'] == true;
      Uint8List? preview;
      final List<XFile> files;
      if (clipboardPhoto) {
        try {
          preview = await readClipboardPhoto();
        } catch (_) {
          if (context.mounted && active()) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tr(
                    'Не удалось вставить изображение (PNG или JPEG до 4 МиБ).',
                    'Could not paste the image (PNG or JPEG up to 4 MiB).',
                  ),
                ),
              ),
            );
          }
          return null;
        }
        if (!context.mounted || !active()) return null;
        if (preview == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'В буфере нет поддерживаемого изображения.',
                  'No supported image in the clipboard.',
                ),
              ),
            ),
          );
          return null;
        }
        files = [
          XFile.fromData(
            preview,
            path: 'clipboard-image.png',
            mimeType: 'image/png',
          ),
        ];
      } else if (droppedPaths != null) {
        files = await localDroppedFiles(droppedPaths);
        if (files.isEmpty && context.mounted && active()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'Перетащите от одного до восьми локальных файлов.',
                  'Drop one to eight local files.',
                ),
              ),
            ),
          );
        }
      } else {
        files = await openFiles();
      }
      if (files.isEmpty || !active()) return null;
      if (!context.mounted) return null;
      final selection = await showDialog<({List<XFile> files, String caption})>(
        context: context,
        builder: (_) => AttachmentSelection(files, tr, preview: preview),
      );
      return active() ? selection : null;
    });
    if (context.mounted &&
        identical(current, attachments) &&
        current.selectionRemaining > 0 &&
        current.status != null) {
      final count = current.selectionRemaining;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Не добавлено файлов в очередь: $count. Выберите их повторно.',
              'Files left out of the queue: $count. Select them again.',
            ),
          ),
        ),
      );
      current.selectionRemaining = 0;
    }
    if (identical(current, attachments) && online && !lite) {
      unawaited(current.resume(explicit: false, weak: false));
    }
  }

  final microphoneButtonKey = GlobalKey();

  Future<void> recordVoice(
    BuildContext context, [
    ValueNotifier<VoiceHold>? hold,
  ]) async {
    final current = attachments;
    if (current == null || current.busy || profile?['trustConfirmed'] != true) {
      return;
    }
    await current.stageMedia('voice', 'voice-note.wav', () async {
      final clip = hold == null
          ? await showDialog<Uint8List>(
              context: context,
              builder: (_) => VoiceDialog(tr),
            )
          : await showHeldVoice(context, tr, hold);
      return identical(attachments, current) &&
              profile?['trustConfirmed'] == true
          ? clip
          : null;
    });
    if (identical(current, attachments) && online && !lite) {
      unawaited(current.resume(explicit: false, weak: false));
    }
  }

  Future<void> captureVideo(BuildContext context) async {
    final current = attachments;
    if (current == null || current.busy || profile?['trustConfirmed'] != true) {
      return;
    }
    await current.stageMedia('video', 'video-message.mp4', () async {
      final clip = await showDialog<Uint8List>(
        context: context,
        builder: (_) => VideoMessageDialog(tr: tr),
      );
      return identical(attachments, current) &&
              profile?['trustConfirmed'] == true
          ? clip
          : null;
    });
    if (identical(attachments, current) && online && !lite) {
      unawaited(current.resume(explicit: false, weak: false));
    }
  }

  Widget attachmentMessage(
    BuildContext context,
    String id,
    Map<String, dynamic> meta,
  ) {
    final name = attachmentName(meta['name'] as String);
    final current = attachments;
    final enabled = current != null && !current.busy;
    final voicePositions = voicePlaybackPositions;
    final group = profile?['group'] as String?;
    final voiceBlob = meta['blobId'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$name · ${((meta['size'] as int) / 1024).ceil()} KiB'),
        if (meta['caption'] case final String caption)
          MessageMarkup(caption, tr: tr),
        Wrap(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.download_outlined),
              label: Text(
                tr('Сохранить', 'Save'),
                semanticsLabel: tr('Сохранить $name', 'Save $name'),
              ),
              onPressed: enabled
                  ? () => current.download(id, meta, exportAttachment)
                  : null,
            ),
            if (meta['media'] == 'voice' ||
                (supportsVideoMessages && meta['media'] == 'video'))
              TextButton.icon(
                icon: Icon(
                  inlineMedia?.id == id
                      ? Icons.close
                      : Icons.play_circle_outline,
                ),
                label: Text(
                  inlineMedia?.id == id
                      ? tr('Закрыть', 'Close')
                      : meta['media'] == 'voice'
                      ? tr('Прослушать', 'Listen')
                      : tr('Смотреть видео', 'Play video'),
                ),
                onPressed: inlineMedia?.id == id
                    ? closeInlineMedia
                    : !enabled
                    ? null
                    : () {
                        closeInlineMedia();
                        final request = mediaView;
                        unawaited(
                          current.download(id, meta, (_, bytes) async {
                            if (meta['media'] == 'voice') {
                              voiceDuration(bytes);
                            } else if (!isLocalVideo(bytes)) {
                              throw const FormatException();
                            }
                            if (context.mounted &&
                                identical(current, attachments) &&
                                request == mediaView &&
                                callsForeground) {
                              setState(
                                () => inlineMedia = (id: id, bytes: bytes),
                              );
                            }
                            return false;
                          }),
                        );
                      },
              ),
            if (meta['media'] == 'photo')
              TextButton.icon(
                icon: const Icon(Icons.image_outlined),
                label: Text(tr('Посмотреть', 'View')),
                onPressed: enabled
                    ? () => current.download(id, meta, (name, bytes) async {
                        final image = await attachmentPreview(bytes);
                        if (!context.mounted ||
                            !identical(attachments, current)) {
                          image.dispose();
                          return false;
                        }
                        // The dialog's reverse transition may outlive showDialog's result.
                        final route = DialogRoute<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(name),
                            content: RawImage(
                              image: image,
                              fit: BoxFit.contain,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: Text(tr('Закрыть', 'Close')),
                              ),
                            ],
                          ),
                        );
                        try {
                          await Navigator.of(context).push(route);
                          await route.completed;
                        } finally {
                          image.dispose();
                        }
                        return false;
                      })
                    : null,
              ),
          ],
        ),
        if (inlineMedia case (id: final playing, bytes: final bytes)
            when playing == id)
          if (meta['media'] == 'voice')
            VoicePlayer(
              bytes,
              tr,
              key: ValueKey((group, voiceBlob)),
              transcribeOnOpen: profile?['transcribeOnOpen'] == true,
              resumeAt: group == null || voiceBlob == null
                  ? Duration.zero
                  : voicePositions?.read(group, voiceBlob) ?? Duration.zero,
              onPosition: group == null || voiceBlob == null
                  ? null
                  : (position) =>
                        voicePositions?.save(group, voiceBlob, position),
            )
          else if (supportsVideoMessages && meta['media'] == 'video')
            VideoMessageDialog(
              key: ValueKey(id),
              tr: tr,
              received: bytes,
              inline: true,
              onClose: closeInlineMedia,
            ),
      ],
    );
  }

  Widget attachmentStatus(PrivateAttachments current) {
    final status = current.status;
    final label = switch (status) {
      'size' => tr(
        'Выберите файл размером от 1 байта до 4 МиБ.',
        'Choose a file between 1 byte and 4 MiB.',
      ),
      'failed' => tr(
        'Операция с файлом не удалась. Повторите попытку.',
        'File transfer failed. Try again.',
      ),
      'paused' => tr(
        'Сначала отправляются сообщения. Вложение можно продолжить с сохранённого места.',
        'Messages are sent first. The attachment can resume from its saved position.',
      ),
      'saved' => tr('Файл сохранён', 'File saved'),
      'upload' => tr('Отправка вложения', 'Uploading attachment'),
      'download' => tr('Получение вложения', 'Downloading attachment'),
      _ => '',
    };
    return Column(
      children: [
        if (label.isNotEmpty) Text(label),
        if (current.busy && current.progress != null)
          LinearProgressIndicator(value: current.progress),
        if (current.pending.isNotEmpty)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                tr(
                  'Вложений в очереди: ${current.pending.length}',
                  'Attachments queued: ${current.pending.length}',
                ),
              ),
              TextButton(
                onPressed: current.busy || !online
                    ? null
                    : () => current.resume(explicit: true, weak: lite),
                child: Text(tr('Отправить сейчас', 'Send now')),
              ),
              IconButton(
                tooltip: tr(
                  'Убрать первое вложение из очереди',
                  'Remove first queued attachment',
                ),
                icon: const Icon(Icons.close),
                onPressed: current.busy ? null : current.cancelFirst,
              ),
            ],
          ),
      ],
    );
  }

  Widget chat(BuildContext context) {
    final bySenderAndId = {
      for (final message in messages)
        (message['sender'], message['id']): message,
    };
    String replyPreview(String id, String sender) {
      final original = bySenderAndId[(sender, id)];
      if (original == null) {
        return tr(
          'Исходное сообщение недоступно',
          'Original message unavailable',
        );
      }
      final text = original['text'] as String;
      if (text.contains('||')) {
        return tr('Сообщение со спойлером', 'Message with a spoiler');
      }
      return text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return chatBody(context, replyPreview, drafts?.reply);
  }

  Widget chatBody(
    BuildContext context,
    String Function(String, String) replyPreview,
    ({String id, String sender})? selectedReply,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConversationHeader(
        peerName: currentPeerLabel,
        verified: profile!['trustConfirmed'] == true,
        canCall:
            online &&
            profile?['trustConfirmed'] == true &&
            directCall?.active != true,
        tr: tr,
        onBack: busy || sending ? null : leaveConversation,
        onCall: (video) async {
          final group = profile!['group'] as String;
          final name = profile!['peerName'] as String;
          final view = chatView;
          if (await confirmDirectCall(context, video, name, tr) &&
              context.mounted &&
              view == chatView &&
              profile?['group'] == group) {
            await bindCall(group)?.invite(video);
          }
        },
        onSearch: () {
          final group = profile!['group'] as String;
          final view = chatView;
          final peerName = profile!['peerName'] as String;
          Future<Map<String, dynamic>> searchMessages(
            String query, [
            DateTime? day,
          ]) async {
            if (view != chatView || profile?['group'] != group) {
              throw CryptoFailure();
            }
            final result = await crypto('search_history', {
              'group': group,
              'query': query,
              if (day != null) ...{
                'fromMs': day.millisecondsSinceEpoch,
                'untilMs': DateTime(
                  day.year,
                  day.month,
                  day.day + 1,
                ).millisecondsSinceEpoch,
              },
            });
            if (view != chatView || profile?['group'] != group) {
              throw CryptoFailure();
            }
            return result;
          }

          Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => HistorySearch(
                tr: tr,
                peerName: peerName,
                search: (query) => searchMessages(query),
                searchDay: (query, day) => searchMessages(query, day),
              ),
            ),
          );
        },
        onSaved: () {
          final epoch = generation;
          final ownProfile = profile!;
          Future<Map<String, dynamic>> local(
            String op,
            Map<String, dynamic> args,
          ) async {
            if (epoch != generation) throw CryptoFailure();
            final result = await crypto(op, args);
            if (epoch != generation) throw CryptoFailure();
            return result;
          }

          Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SavedMessages(
                tr: tr,
                read: (before) => local('favorites_list', {'before': ?before}),
                remove: (entry) async {
                  await local('favorites_set', {
                    'group': entry['group'],
                    'saved': false,
                    'items': [
                      {'id': entry['id'], 'own': entry['own']},
                    ],
                  });
                },
                peerName: (group) {
                  if (group == ownProfile['group']) {
                    return ownProfile['peerName'] as String;
                  }
                  final known = ownProfile['verifiedChats'] as Map?;
                  final entry = known?[group];
                  return entry is Map && entry['name'] is String
                      ? entry['name'] as String
                      : tr('Личный чат', 'Private chat');
                },
              ),
            ),
          );
        },
        onVerify: () => verifyKeys(context),
      ),
      if (!online || lite || queued > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              Icon(
                online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  online
                      ? (lite
                            ? tr('Слабая сеть', 'Weak connection')
                            : tr('Связь с сервером', 'Connected to server'))
                      : connectionState == 'keys'
                      ? tr('Проверьте ключи', 'Check keys')
                      : connectionState == 'auth'
                      ? tr('Нужен вход', 'Sign in required')
                      : connectionState == 'server'
                      ? tr('Ошибка сервера', 'Server error')
                      : tr('Офлайн', 'Offline'),
                ),
              ),
              if (queued > 0)
                Semantics(
                  liveRegion: true,
                  child: Text(tr('В очереди: $queued', 'Queued: $queued')),
                ),
              IconButton(
                tooltip: tr('Повторить соединение', 'Reconnect'),
                onPressed: () {
                  declinedRoster.clear();
                  unawaited(pump());
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      if (profile!['trustConfirmed'] != true)
        MaterialBanner(
          content: Text(
            tr(
              'Перед отправкой сравните ключи собеседника.',
              'Compare your contact’s keys before sending.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => verifyKeys(context),
              child: Text(tr('Сравнить ключи', 'Compare keys')),
            ),
          ],
        ),
      if (error != null && connectionState != 'auth')
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const Divider(height: 1),
      Expanded(
        child: messages.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr(
                      'Переписка пока пуста. Текст можно поставить в очередь даже без сети.',
                      'No messages yet. You can queue text while offline.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ConversationTimeline(
                key: ValueKey(profile!['group']),
                messages: messages,
                scroll: chatScroll,
                replyPreview: replyPreview,
                onRetryQueue: () => unawaited(pump()),
                pin: pinnedMessage?['group'] == profile?['group']
                    ? pinnedMessage
                    : null,
                onPin: (item, pinned) async {
                  final group = profile!['group'];
                  await crypto('pin_message_local', {
                    'group': group,
                    'id': item['id'],
                    'own': item['own'],
                    'pinned': pinned,
                  });
                  if (mounted && profile?['group'] == group) await reload();
                },
                onSave: (rows) async {
                  final group = profile!['group'];
                  await crypto('favorites_set', {
                    'group': group,
                    'saved': true,
                    'items': [
                      for (final m in rows) {'id': m['id'], 'own': m['own']},
                    ],
                  });
                },
                onOlder: olderHistory?['group'] == profile?['group']
                    ? () {
                        final group = profile!['group'] as String;
                        final epoch = generation;
                        final view = chatView;
                        final cursor = olderHistory!;
                        final peer = profile!['peerName'] as String;
                        Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => EarlierHistory(
                              initial: cursor,
                              peer: peer,
                              tr: tr,
                              read: (cursor) async {
                                if (generation != epoch ||
                                    view != chatView ||
                                    profile?['group'] != group) {
                                  throw CryptoFailure();
                                }
                                final result = await crypto('history_page', {
                                  'group': group,
                                  'cursor': cursor,
                                });
                                if (generation != epoch ||
                                    view != chatView ||
                                    profile?['group'] != group) {
                                  throw CryptoFailure();
                                }
                                return result;
                              },
                            ),
                          ),
                        );
                      }
                    : null,
                attachment: attachmentMessage,
                onReply:
                    !sending &&
                        drafts?.readyFor(profile?['group'] as String?) == true
                    ? (id, sender) => setState(
                        () => drafts!.setReply((id: id, sender: sender)),
                      )
                    : null,
                tr: tr,
              ),
      ),
      if (attachments case final PrivateAttachments current)
        attachmentStatus(current),
      if (selectedReply != null)
        ListTile(
          dense: true,
          leading: const Icon(Icons.reply),
          title: Text(tr('Ответ на сообщение', 'Replying to message')),
          subtitle: Text(
            replyPreview(selectedReply.id, selectedReply.sender),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: tr('Отменить ответ', 'Cancel reply'),
            onPressed: sending
                ? null
                : () => setState(() => drafts?.setReply(null)),
            icon: const Icon(Icons.close),
          ),
        ),
      if (sendError != null)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              sendError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      DesktopFileDrop(
        onFiles:
            attachments?.busy == false && profile?['trustConfirmed'] == true
            ? (paths) => chooseAttachment(context, droppedPaths: paths)
            : null,
        child: ConversationComposer(
          editor: draftLoadFailed
              ? TextButton(
                  onPressed: () => restoreDraft(profile?['group'] as String?),
                  child: Text(
                    tr('Повторить загрузку черновика', 'Retry loading draft'),
                  ),
                )
              : drafts?.readyFor(profile?['group'] as String?) != true
              ? const LinearProgressIndicator()
              : MessageComposer(
                  controller: composer,
                  tr: tr,
                  onSubmitted: (_) => send(),
                ),
          tr: tr,
          videoSupported: supportsVideoMessages,
          onVideo:
              attachments?.busy == false && profile?['trustConfirmed'] == true
              ? () => captureVideo(context)
              : null,
          onFile:
              attachments?.busy == false && profile?['trustConfirmed'] == true
              ? () => chooseAttachment(context)
              : null,
          onPastePhoto:
              clipboardPhotoSupported &&
                  attachments?.busy == false &&
                  profile?['trustConfirmed'] == true
              ? () => chooseAttachment(context, clipboardPhoto: true)
              : null,
          microphoneKey: microphoneButtonKey,
          onVoiceHold:
              attachments?.busy == false && profile?['trustConfirmed'] == true
              ? (hold) => recordVoice(context, hold)
              : null,
          onVoice:
              attachments?.busy == false && profile?['trustConfirmed'] == true
              ? () => recordVoice(context)
              : null,
          onSend:
              profile!['trustConfirmed'] == true &&
                  drafts?.readyFor(profile?['group'] as String?) == true &&
                  !sending
              ? send
              : null,
        ),
      ),
    ],
  );
  Future<void> loadDevices() async {
    final epoch = generation;
    final request = ++deviceLoad;
    try {
      final result = await api('/v1/devices') as List<dynamic>;
      final self = await api('/v1/users/me') as Map;
      final current = self['deviceId'];
      if (current is! String ||
          current != profile?['deviceId'] ||
          result.where((d) => d['id'] == current).length != 1 ||
          result.any(
            (d) =>
                d.containsKey('isCurrent') &&
                d['isCurrent'] != (d['id'] == current),
          )) {
        throw const FormatException('Inconsistent active device');
      }
      final available = self['labAccountRemoval'] == true;
      if (available &&
          mounted &&
          epoch == generation &&
          profile?['labAccountRemoval'] != true) {
        await persistProfile({...profile!, 'labAccountRemoval': true});
      }
      if (mounted && epoch == generation && request == deviceLoad) {
        setState(() {
          devices = result;
          labRemovalAvailable = available;
          deviceError = null;
        });
      }
    } catch (_) {
      if (mounted && epoch == generation && request == deviceLoad) {
        setState(
          () => deviceError = tr(
            'Не удалось загрузить устройства.',
            'Could not load devices.',
          ),
        );
      }
    }
  }

  Future<int> revokeOthers(Set<String> ids) async {
    final owner = session;
    final epoch = generation;
    final me = profile?['deviceId'];
    if (owner == null ||
        me is! String ||
        revokingDevice ||
        deviceError != null ||
        ids.contains(me)) {
      return -1;
    }
    bool active() =>
        mounted && epoch == generation && identical(session, owner);
    setState(() => revokingDevice = true);
    try {
      final count = await revokeListedDevices(
        ids,
        active: active,
        revoke: (id) async {
          await owner.request(
            '/v1/devices/${Uri.encodeComponent(id)}',
            method: 'DELETE',
          );
        },
        refresh: () async {
          await loadDevices();
          return active() && deviceError == null ? devices : null;
        },
      );
      return active() ? count : -1;
    } finally {
      if (active()) setState(() => revokingDevice = false);
    }
  }

  Future<void> revokeDevice(String id) async {
    if (revokingDevice || store == null || id == profile?['deviceId']) return;
    final epoch = generation;
    setState(() => revokingDevice = true);
    try {
      await api('/v1/devices/${Uri.encodeComponent(id)}', method: 'DELETE');
      if (!mounted || generation != epoch) return;
      ++deviceLoad;
      setState(() {
        devices = [
          for (final d in devices)
            if (d['id'] == id) {...d as Map, 'revoked': true} else d,
        ];
        deviceError = null;
      });
      await loadDevices();
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(
          () => deviceError = tr(
            'Отзыв доступа не подтверждён. Обновите список устройств.',
            'Revocation was not confirmed. Refresh the device list.',
          ),
        );
      }
    } finally {
      if (mounted && generation == epoch) {
        setState(() => revokingDevice = false);
      }
    }
  }

  Future<void> setBackgroundLock(bool enabled) async {
    if (savingBackgroundLock || store == null) return;
    final epoch = generation;
    setState(() {
      savingBackgroundLock = true;
      backgroundLockSaveFailed = false;
    });
    try {
      await persistProfile(
        {},
        sessionOnly: true,
        backgroundLockPreference: enabled,
      );
      if (!mounted || epoch != generation) return;
      final state = WidgetsBinding.instance.lifecycleState;
      if (enabled &&
          (state == AppLifecycleState.hidden ||
              state == AppLifecycleState.paused)) {
        lock();
      }
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(() => backgroundLockSaveFailed = true);
      }
    } finally {
      if (mounted && epoch == generation) {
        setState(() => savingBackgroundLock = false);
      }
    }
  }

  Future<void> changeNotificationPolicy(
    NotificationPreferences Function(NotificationPreferences) update,
  ) async {
    final epoch = generation;
    if (changingNotifications || store == null) return;
    desktopNotifications.cancel();
    setState(() {
      changingNotifications = true;
      notificationSaveFailed = false;
    });
    try {
      await persistProfile(
        {},
        sessionOnly: true,
        updateNotificationPolicy: update,
      );
    } catch (_) {
      if (mounted && generation == epoch) notificationSaveFailed = true;
      rethrow;
    } finally {
      if (mounted && generation == epoch) {
        setState(() => changingNotifications = false);
      }
    }
  }

  Future<void> setNotifications(bool enabled) async {
    final epoch = generation;
    if (changingNotifications || store == null) return;
    desktopNotifications.cancel();
    setState(() {
      changingNotifications = true;
      notificationSaveFailed = false;
    });
    try {
      if (Platform.isAndroid &&
          enabled &&
          !await androidNotifications.requestPermission()) {
        if (mounted && generation == epoch) {
          setState(() => notificationBackend = false);
        }
        return;
      }
      if (!mounted || generation != epoch) return;
      await persistProfile(
        {},
        sessionOnly: true,
        notificationPreference: enabled,
      );
      if (generation == epoch && enabled) await desktopNotifications.probe();
    } catch (_) {
      if (mounted && generation == epoch) notificationSaveFailed = true;
    } finally {
      if (mounted && generation == epoch) {
        setState(() => changingNotifications = false);
      }
    }
  }

  Future<void> removeLabAccount(BuildContext context) async {
    final owner = session;
    final device = profile?['deviceId'];
    final file = path.text.trim();
    if (owner == null || device is! String || file.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AccountRemovalDialog(
        russian: ru,
        remove: (password) async {
          final account = profile;
          if (account == null || !identical(session, owner)) {
            throw CryptoFailure();
          }
          final int version = account['credentialVersion'] as int? ?? 1;
          final fields = version == 1
              ? <String, dynamic>{'password': password}
              : await accountCredentialFields(
                  version: version,
                  endpoint: Uri.parse(account['endpoint'] as String),
                  username: account['username'] as String,
                  password: password,
                );
          if (!identical(session, owner) || profile?['deviceId'] != device) {
            throw CryptoFailure();
          }
          await owner.request(
            '/v1/users/me/removal',
            data: {'requestId': device, ...fields},
          );
        },
      ),
    );
    if (confirmed != true || !mounted || !identical(session, owner)) return;
    removingLocal = true;
    lock();
    var localCleanupFailed = false;
    try {
      await closingStore;
      if (Platform.isAndroid ||
          Platform.isIOS ||
          DesktopProfileKeyring.supported) {
        try {
          if (DesktopProfileKeyring.supported) {
            await DesktopProfileKeyring.forget(file);
          } else {
            await profileBiometrics.invokeMethod<void>('forget', {
              'path': file,
              'russian': ru,
            });
          }
        } catch (_) {
          localCleanupFailed = true;
        }
      }
      try {
        await setProfileLabel(File(file), await localProfileDirectory(), '');
      } catch (_) {
        localCleanupFailed = true;
      }
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final target = File(file + suffix);
        if (await target.exists()) await target.delete();
      }
    } catch (_) {
      localCleanupFailed = true;
    } finally {
      removingLocal = false;
    }
    if (!mounted) return;
    setState(() {
      selectedProfile = null;
      path.clear();
      showUnlockPassword = false;
      showLocalUnlock = false;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          localCleanupFailed
              ? tr(
                  'Аккаунт удалён. Проверьте локальный файл и сохранённый способ входа на этом устройстве.',
                  'Account removed. Check the local profile file and saved unlock method on this device.',
                )
              : tr(
                  'Тестовый аккаунт и локальный профиль удалены.',
                  'Lab account and local profile removed.',
                ),
        ),
      ),
    );
  }

  final settingsNavigation = GlobalKey<SettingsHierarchyState>();
  final appearancePreferences = AppearancePreferences();
  Future<void> appearanceWrites = Future.value();
  bool languageChanged = false, themeChanged = false;
  bool appearanceSaveFailed = false;

  Future<void> restoreAppearance() async {
    try {
      final (mode, russian) = await appearancePreferences.read();
      if (!mounted) return;
      setState(() {
        if (!themeChanged && mode != null) theme = mode;
        if (!languageChanged && russian != null) ru = russian;
      });
    } catch (_) {
      // Platform storage may be unavailable on first startup.
    }
  }

  Future<void> changeAppearance({bool? russian, ThemeMode? mode}) {
    setState(() {
      if (russian != null) {
        ru = russian;
        languageChanged = true;
      }
      if (mode != null) {
        theme = mode;
        themeChanged = true;
      }
      appearanceSaveFailed = false;
    });
    appearanceWrites = appearanceWrites.then((_) async {
      try {
        if (russian != null) await appearancePreferences.saveLanguage(russian);
        if (mode != null) await appearancePreferences.saveTheme(mode);
      } catch (_) {
        if (mounted) setState(() => appearanceSaveFailed = true);
      }
    });
    return appearanceWrites;
  }

  Widget settings(BuildContext context) {
    final ownerSession = session!;
    final trusted = profile?['trustState'] == 'DEVICE_TRUSTED';
    final modeLabels = {
      ThemeMode.system: tr('Системная', 'System'),
      ThemeMode.light: tr('Светлая', 'Light'),
      ThemeMode.dark: tr('Тёмная', 'Dark'),
    };
    ListTile choice(String label, bool selected, VoidCallback select) =>
        ListTile(
          title: Text(label),
          selected: selected,
          trailing: selected ? const Icon(Icons.check) : null,
          onTap: select,
        );
    final saveError = ListTile(
      title: Text(
        tr(
          'Выбор действует до выхода. Нажмите ещё раз, чтобы сохранить.',
          'This choice applies until you exit. Select it again to save.',
        ),
      ),
    );
    return SettingsHierarchy(
      key: settingsNavigation,
      russian: ru,
      sections: [
        for (final section in SettingsSection.values)
          if ((section != SettingsSection.profile || trusted) &&
              (section != SettingsSection.notifications ||
                  Platform.isLinux ||
                  Platform.isAndroid))
            section,
      ],
      summary: (section) => switch (section) {
        SettingsSection.profile => '@${profile?['username'] ?? ''}',
        SettingsSection.appearance => modeLabels[theme],
        SettingsSection.language => ru ? 'Русский' : 'English',
        _ => null,
      },
      content: (section) => switch (section) {
        SettingsSection.profile => [
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: Text(tr('О себе и статус', 'Bio and status')),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  ProfileTextEditor(api: ownerSession.request, russian: ru),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(tr('Отображаемое имя', 'Display name')),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  DisplayNameEditor(api: ownerSession.request, russian: ru),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(tr('Фото профиля', 'Profile photo')),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  ProfilePhotoEditor(api: ownerSession.request, russian: ru),
            ),
          ),
        ],
        SettingsSection.notifications => [
          SwitchListTile(
            title: Text(
              tr('Уведомления о сообщениях', 'Message notifications'),
            ),
            subtitle: Text(
              notificationSaveFailed
                  ? tr(
                      'Не удалось сохранить настройку. Повторите попытку.',
                      'Could not save this setting. Try again.',
                    )
                  : notificationBackend == false
                  ? tr(
                      'Системные уведомления недоступны.',
                      'System notifications are unavailable.',
                    )
                  : tr(
                      'Пока окно в фоне и профиль открыт. Имя и текст скрыты.',
                      'While the profile is unlocked and the window is in the background. Names and message text stay hidden.',
                    ),
            ),
            value: profile?['desktopNotifications'] == true,
            onChanged: changingNotifications ? null : setNotifications,
          ),
          QuietHoursTile(
            preferences: NotificationPreferences.fromProfile(profile),
            russian: ru,
            onChanged: changingNotifications
                ? null
                : (duration) {
                    final end = duration == Duration.zero
                        ? null
                        : DateTime.now().add(duration);
                    // The settings panel displays notificationSaveFailed on a write error.
                    unawaited(
                      changeNotificationPolicy((prefs) => prefs.quietUntil(end))
                          .catchError((_) {}),
                    );
                  },
          ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(
                tr(
                  'Звук и разрешения в Android',
                  'Android sound and permissions',
                ),
              ),
              onTap: () async {
                try {
                  await androidNotifications.systemSettings();
                } catch (_) {
                  if (mounted) setState(() => notificationSaveFailed = true);
                }
              },
            ),
        ],
        SettingsSection.privacy => [
          SwitchListTile(
            title: Text(
              tr(
                'Блокировать при скрытии приложения',
                'Lock when the app is hidden',
              ),
            ),
            subtitle: Text(
              backgroundLockSaveFailed
                  ? tr(
                      'Не удалось сохранить настройку.',
                      'Could not save this setting.',
                    )
                  : tr(
                      'Обмен продолжится после разблокировки профиля.',
                      'Delivery resumes after you unlock your profile.',
                    ),
            ),
            value: profile?['lockWhenHidden'] == true,
            onChanged: savingBackgroundLock ? null : setBackgroundLock,
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(tr('Заблокировать профиль', 'Lock profile')),
            onTap: lock,
          ),
        ],
        SettingsSection.devices => [
          if (canReauthenticate(profile!))
            ListTile(
              leading: const Icon(Icons.login),
              title: Text(tr('Войти снова', 'Sign in again')),
              onTap: reauthenticating ? null : () => signInAgain(context),
            ),
          if (session case final AccountSession active when trusted)
            SecurityEmailTile(
              key: ObjectKey(active),
              russian: ru,
              request: active.request,
            ),
          if (sessionInactivity case final SessionInactivity policy
              when profile?['trustState'] != 'DEVICE_PENDING_TRUST')
            SessionInactivityTile(
              key: ObjectKey(policy),
              policy: policy,
              russian: ru,
            ),
          if (deviceError != null)
            ListTile(
              title: Text(deviceError!),
              trailing: TextButton(
                onPressed: loadDevices,
                child: Text(tr('Повторить', 'Retry')),
              ),
            ),
          if (deviceError == null && devices.isEmpty)
            ListTile(
              title: Text(tr('Загрузка устройств…', 'Loading devices…')),
            ),
          OtherSessionsAction(
            key: ValueKey(profile!['deviceId']),
            devices: devices,
            current: profile!['deviceId'] as String,
            russian: ru,
            run: revokingDevice || deviceError != null ? null : revokeOthers,
          ),
          for (final d in devices)
            DeviceTile(
              key: ValueKey(d['id']),
              device: d as Map,
              current: d['id'] == profile!['deviceId'],
              russian: ru,
              localOs: d['id'] == profile!['deviceId']
                  ? Platform.operatingSystem
                  : null,
              onRename:
                  d['id'] == profile!['deviceId'] &&
                      d.containsKey('name') &&
                      deviceError == null
                  ? (name) async {
                      await api(
                        '/v1/devices/me/name',
                        method: 'PUT',
                        data: {'name': name},
                      );
                      if (mounted) await loadDevices();
                    }
                  : null,
              onRevoke: revokingDevice || deviceError != null
                  ? null
                  : () => revokeDevice(d['id'] as String),
            ),
        ],
        SettingsSection.storage => [
          if (Platform.isLinux)
            SwitchListTile(
              title: Text(
                tr(
                  'Распознавать открытые голосовые',
                  'Transcribe opened voice messages',
                ),
              ),
              subtitle: Text(
                tr(
                  'На этом устройстве, если установлена модель Whisper.',
                  'On this device when a Whisper model is installed.',
                ),
              ),
              value: profile?['transcribeOnOpen'] == true,
              onChanged: (enabled) async {
                final epoch = generation;
                try {
                  await persistProfile(
                    {},
                    removedFields: {},
                    autoTranscribe: enabled,
                  );
                  if (mounted && epoch == generation) setState(() {});
                } catch (_) {
                  if (mounted && epoch == generation) {
                    setState(() => appearanceSaveFailed = true);
                  }
                }
              },
            ),
          if (appearanceSaveFailed) saveError,
          ProfileStorageSize(path: path.text.trim(), russian: ru),
        ],
        SettingsSection.appearance => [
          for (final entry in modeLabels.entries)
            choice(
              entry.value,
              theme == entry.key,
              () => changeAppearance(mode: entry.key),
            ),
          ListTile(
            title: Text(tr('Размер текста в чате', 'Chat text size')),
            subtitle: Wrap(
              spacing: 8,
              children: [
                for (final opt in [
                  ('system', tr('Системный', 'System size')),
                  ('larger', '115%'),
                  ('largest', '130%'),
                ])
                  ChoiceChip(
                    label: Text(opt.$2),
                    selected: (profile?['chatTextSize'] ?? 'system') == opt.$1,
                    onSelected: (_) => setChatStyle('chatTextSize', opt.$1),
                  ),
              ],
            ),
          ),
          ChatBackgroundSettings(
            profile: profile,
            group: profile?['group'] as String?,
            name: profile?['peerName'] as String?,
            tr: tr,
            saveDimming: (group, dark, value) async {
              final epoch = generation;
              try {
                await persistProfile(
                  {},
                  removedFields: {},
                  dimming: (group: group, dark: dark, value: value),
                );
                if (mounted && epoch == generation) setState(() {});
              } catch (_) {
                if (mounted && epoch == generation) {
                  setState(() => appearanceSaveFailed = true);
                }
              }
            },
            save: (group, dark, color) async {
              final epoch = generation;
              try {
                await persistProfile(
                  {},
                  removedFields: {},
                  wallpaper: (group: group, dark: dark, color: color),
                );
                if (mounted && epoch == generation) setState(() {});
              } catch (_) {
                if (mounted && epoch == generation) {
                  setState(() => appearanceSaveFailed = true);
                }
              }
            },
          ),
          if (appearanceSaveFailed) saveError,
        ],
        SettingsSection.language => [
          choice('Русский', ru, () => changeAppearance(russian: true)),
          choice('English', !ru, () => changeAppearance(russian: false)),
          if (appearanceSaveFailed) saveError,
        ],
        SettingsSection.advanced => [
          OfficialHelp(russian: ru),
          ListTile(
            title: const Text('SecureMesh'),
            subtitle: Text(
              tr(
                'Экспериментальная версия. Независимый аудит безопасности ещё не завершён.',
                'Experimental release. The independent security audit is pending.',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(tr('Лицензии', 'Licenses')),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'SecureMesh',
            ),
          ),
          if (trusted &&
              (labRemovalAvailable || profile?['labAccountRemoval'] == true))
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('Удалить тестовый аккаунт', 'Delete lab account')),
              onTap: () => removeLabAccount(context),
            ),
        ],
      },
    );
  }
}

enum _ChatAction { audio, video, search, verify, saved }

class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    super.key,
    required this.peerName,
    required this.verified,
    required this.canCall,
    required this.tr,
    required this.onBack,
    required this.onCall,
    required this.onSearch,
    required this.onVerify,
    this.onSaved,
  });

  final String peerName;
  final bool verified, canCall;
  final String Function(String, String) tr;
  final VoidCallback? onBack, onSaved;
  final ValueChanged<bool> onCall;
  final VoidCallback onSearch, onVerify;

  @override
  Widget build(BuildContext context) {
    final status = verified
        ? tr('Приватный чат · ключи проверены', 'Private chat · keys verified')
        : tr('Приватный чат · OpenMLS', 'Private chat · OpenMLS');
    final audio = tr('Аудиозвонок', 'Audio call');
    final video = tr('Видеозвонок', 'Video call');
    final search = tr('Поиск в переписке', 'Search conversation');
    final verify = tr('Проверить ключи', 'Verify keys');
    final saved = tr('Избранное', 'Saved messages');
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        return ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: compact ? 4 : 16),
          horizontalTitleGap: compact ? 4 : 16,
          leading: IconButton(
            tooltip: tr('Все чаты', 'All chats'),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Tooltip(
            message: peerName,
            excludeFromSemantics: true,
            child: Text(peerName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          subtitle: compact && verified
              ? Tooltip(
                  message: status,
                  excludeFromSemantics: true,
                  child: Text(
                    tr('Ключи проверены', 'Keys verified'),
                    semanticsLabel: status,
                  ),
                )
              : Text(status),
          trailing: compact
              ? PopupMenuButton<_ChatAction>(
                  tooltip: tr('Действия чата', 'Chat actions'),
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (_) => [
                    if (onSaved != null)
                      PopupMenuItem(
                        value: _ChatAction.saved,
                        child: Text(saved),
                      ),
                    PopupMenuItem(
                      value: _ChatAction.search,
                      child: Text(search),
                    ),
                    PopupMenuItem(
                      value: _ChatAction.audio,
                      enabled: canCall,
                      child: Text(audio),
                    ),
                    PopupMenuItem(
                      value: _ChatAction.video,
                      enabled: canCall,
                      child: Text(video),
                    ),
                    PopupMenuItem(
                      value: _ChatAction.verify,
                      child: Text(verify),
                    ),
                  ],
                  onSelected: (action) {
                    switch (action) {
                      case _ChatAction.saved:
                        onSaved?.call();
                      case _ChatAction.search:
                        onSearch();
                      case _ChatAction.audio:
                        onCall(false);
                      case _ChatAction.video:
                        onCall(true);
                      case _ChatAction.verify:
                        onVerify();
                    }
                  },
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<bool>(
                      tooltip: tr('Позвонить', 'Call'),
                      icon: const Icon(Icons.call_outlined),
                      enabled: canCall,
                      itemBuilder: (_) => [
                        PopupMenuItem(value: false, child: Text(audio)),
                        PopupMenuItem(value: true, child: Text(video)),
                      ],
                      onSelected: onCall,
                    ),
                    if (onSaved != null)
                      IconButton(
                        tooltip: saved,
                        onPressed: onSaved,
                        icon: const Icon(Icons.bookmark_outline),
                      ),
                    IconButton(
                      tooltip: search,
                      icon: const Icon(Icons.search),
                      onPressed: onSearch,
                    ),
                    IconButton(
                      tooltip: verify,
                      icon: const Icon(Icons.key_outlined),
                      onPressed: onVerify,
                    ),
                  ],
                ),
        );
      },
    );
  }
}
