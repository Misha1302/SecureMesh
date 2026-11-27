import 'package:material_ui/material_ui.dart';

import 'account_credentials.dart';
import 'account_setup.dart';
import 'transport.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
const _trustStates = {'DEVICE_TRUSTED', 'DEVICE_PENDING_TRUST'};

bool canReauthenticate(Map<String, dynamic> profile) {
  final user = profile['userId'];
  final device = profile['deviceId'];
  final username = profile['username'];
  return user is String &&
      _uuid.hasMatch(user) &&
      device is String &&
      _uuid.hasMatch(device) &&
      username is String &&
      RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username) &&
      _trustStates.contains(profile['trustState']) &&
      profile['credentialVersion'] is int &&
      const {1, 2}.contains(profile['credentialVersion']);
}

Future<Map<String, dynamic>> reauthenticateDevice({
  required Map<String, dynamic> profile,
  required Uri endpoint,
  required Map<String, dynamic> identity,
  required String password,
  required DeviceLoginRequest request,
  required Future<Map<String, dynamic>> Function(String payload) sign,
  CredentialDerivation derive = accountCredentialFields,
}) async {
  if (!canReauthenticate(profile) ||
      identity['identity'] != profile['deviceId'] ||
      endpoint.scheme != 'https' ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      profile['endpoint'] != endpoint.origin) {
    throw ApiFailure(400, 'REAUTHENTICATION_MISMATCH');
  }
  final version = profile['credentialVersion'] as int;
  final login = await signedDeviceLogin(
    endpoint: endpoint,
    username: profile['username'] as String,
    identity: identity,
    version: version,
    password: password,
    request: request,
    sign: sign,
    derive: derive,
  );
  final session = await request(
    '/v$version/auth/reauthenticate',
    data: {
      ...login,
      'expectedUserId': profile['userId'],
      'expectedTrustState': profile['trustState'],
    },
    notFoundCode: 'REAUTHENTICATION_UNAVAILABLE',
  );
  final device = profile['deviceId'];
  final trust = profile['trustState'];
  bool validToken(Object? token) =>
      token is String && token.isNotEmpty && token.length <= 4096;
  if (session is! Map ||
      session['deviceId'] != device ||
      session['trustState'] != trust ||
      !validToken(session['accessToken']) ||
      !validToken(session['refreshToken']) ||
      session['expiresIn'] is! int ||
      (session['expiresIn'] as int) < 1 ||
      (session['expiresIn'] as int) > 86400) {
    throw ApiFailure(403, 'REAUTHENTICATION_MISMATCH');
  }
  final account = await request(
    '/v1/users/me',
    token: session['accessToken'] as String,
  );
  if (account is! Map ||
      account['userId'] != profile['userId'] ||
      account['deviceId'] != device ||
      account['trustState'] != trust) {
    throw ApiFailure(403, 'REAUTHENTICATION_MISMATCH');
  }
  // Only replace the three session fields. The local identity, trust, drafts
  // and queued messages remain owned by the open encrypted store.
  return {
    'accessToken': session['accessToken'],
    'refreshToken': session['refreshToken'],
    'expiresIn': session['expiresIn'],
  };
}

class AccountReauthenticationDialog extends StatefulWidget {
  const AccountReauthenticationDialog({
    super.key,
    required this.russian,
    required this.legacy,
    required this.username,
    required this.confirm,
  });

  final bool russian, legacy;
  final String username;
  final Future<void> Function(String password) confirm;

  @override
  State<AccountReauthenticationDialog> createState() =>
      _AccountReauthenticationDialogState();
}

class _AccountReauthenticationDialogState
    extends State<AccountReauthenticationDialog> {
  final _password = TextEditingController();
  bool _working = false;
  String? _error;
  String _tr(String ru, String en) => widget.russian ? ru : en;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_working || _password.text.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.confirm(_password.text);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = switch (failure) {
          ApiFailure(status: 404) => _tr(
            'Сервер не поддерживает повторный вход на том же устройстве.',
            'This server does not support signing in again on the same device.',
          ),
          ApiFailure(status: 403) => _tr(
            'Сервер не подтвердил прежний аккаунт, устройство или уровень доверия.',
            'The server could not confirm the same account, device, and trust state.',
          ),
          _ => _tr(
            'Вход не выполнен. Проверьте пароль аккаунта и подключение.',
            'Could not sign in. Check your account password and connection.',
          ),
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AlertDialog(
      title: Text(_tr('Войти снова', 'Sign in again')),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('@${widget.username}'),
            if (widget.legacy)
              Text(
                _tr(
                  'В старом аккаунте пароль аккаунта отправляется серверу по HTTPS. Не вводите пароль локального хранилища.',
                  'This legacy account sends its account password to the server over HTTPS. Enter only your account password.',
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              autofocus: true,
              enabled: !_working,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _tr('Пароль аккаунта', 'Account password'),
              ),
            ),
            if (_error case final String message)
              Semantics(liveRegion: true, child: Text(message)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: Text(_tr('Отмена', 'Cancel')),
        ),
        FilledButton(
          onPressed: _working || _password.text.isEmpty ? null : _submit,
          child: Text(_tr('Войти', 'Sign in')),
        ),
      ],
    ),
  );
}
