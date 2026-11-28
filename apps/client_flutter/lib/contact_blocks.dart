import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
import 'identity_comparison.dart';
import 'transport.dart';

Future<void> showContactBlocks(
  BuildContext context, {
  required DisplayNameApi api,
  required IdentityTranslation tr,
  String? username,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ContactBlocks(api, tr, username),
);

class _ContactBlocks extends StatefulWidget {
  const _ContactBlocks(this.api, this.tr, this.username);
  final DisplayNameApi api;
  final IdentityTranslation tr;
  final String? username;

  @override
  State<_ContactBlocks> createState() => _ContactBlocksState();
}

class _ContactBlocksState extends State<_ContactBlocks> {
  static const route = '/v1/contact-blocks';
  late final username = TextEditingController(text: widget.username ?? '');
  List<String>? items;
  bool working = false;
  String? error;

  String tr(String ru, String en) => widget.tr(ru, en);

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final response = await widget.api(route) as Map;
      final list = (response['items'] as List).cast<String>();
      if (mounted) setState(() => items = list);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'Не удалось загрузить список.',
            'Could not load blocked accounts.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> change(String input, {required bool block}) async {
    if (working || items == null) return;
    final name = input.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(name)) {
      setState(
        () => error = tr('Проверьте имя аккаунта.', 'Check the username.'),
      );
      return;
    }
    setState(() {
      working = true;
      error = null;
    });
    try {
      await widget.api('$route/$name', method: block ? 'PUT' : 'DELETE');
      if (!mounted) return;
      final names = items!.toSet();
      if (block) {
        names.add(name);
        username.clear();
      } else {
        names.remove(name);
      }
      setState(() => items = names.toList()..sort());
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = switch (failure) {
          ApiFailure(code: 'USER_NOT_FOUND') => tr(
            'Аккаунт не найден.',
            'Account not found.',
          ),
          ApiFailure(code: 'SELF_BLOCK_NOT_SUPPORTED') => tr(
            'Нельзя заблокировать свой аккаунт.',
            'You cannot block your own account.',
          ),
          _ => tr(
            'Не удалось обновить список.',
            'Could not update blocked accounts.',
          ),
        };
      });
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Заблокированные аккаунты', 'Blocked accounts')),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              'Блокировка убирает ожидающие входящие запросы от этого аккаунта и предотвращает новые. Принятые запросы и существующие чаты остаются доступны.',
              'Blocking removes pending incoming invitations from this account and prevents new ones. Accepted invitations and existing chats remain available.',
            ),
          ),
          if (items == null && !working)
            TextButton(onPressed: load, child: Text(tr('Повторить', 'Retry'))),
          if (items != null) ...[
            const SizedBox(height: 12),
            TextField(
              controller: username,
              enabled: !working,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: tr('Имя аккаунта', 'Account username'),
              ),
              onSubmitted: (value) => change(value, block: true),
            ),
            TextButton(
              onPressed: working
                  ? null
                  : () => change(username.text, block: true),
              child: Text(tr('Заблокировать запросы', 'Block invitations')),
            ),
            for (final name in items!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('@$name'),
                trailing: TextButton(
                  onPressed: working ? null : () => change(name, block: false),
                  child: Text(tr('Разблокировать', 'Unblock')),
                ),
              ),
          ],
          if (working) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: working ? null : () => Navigator.pop(context),
        child: Text(tr('Закрыть', 'Close')),
      ),
    ],
  );
}
