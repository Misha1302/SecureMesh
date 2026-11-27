import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/conversation_drafts.dart';

void main() {
  test('late reads cannot expose the previous recipient and edits survive switching', () async {
    final controller = TextEditingController();
    final delayed = Completer<void>();
    final records = {'A': 'private A', 'B': 'private B'};
    Future<Map<String, dynamic>> command(
      String op,
      Map<String, dynamic> args,
    ) async {
      final group = args['group'] as String;
      if (op == 'draft_get') {
        if (group == 'A') await delayed.future;
        return {'text': records[group] ?? ''};
      }
      records[group] = args['text'] as String;
      return {};
    }

    final drafts = ConversationDrafts(
      controller,
      command,
      () => fail('write failed'),
    );
    final first = drafts.select('A');
    final second = drafts.select('B');
    expect(controller.text, '');
    expect(drafts.readyFor('A'), isFalse);
    delayed.complete();
    await first;
    await second;
    expect(controller.text, 'private B');
    controller.text = 'edited B';
    final switching = drafts.select('A');
    expect(controller.text, '');
    await switching;
    expect(controller.text, 'private A');
    await drafts.close();
    expect(controller.text, '');
    expect(records['B'], 'edited B');
    controller.dispose();
  });

  test('queue completion preserves edits made in flight and lock drains pending saves', () async {
    final controller = TextEditingController();
    final sent = Completer<void>();
    final started = Completer<void>();
    final commands = <String>[];
    Future<Map<String, dynamic>> command(
      String op,
      Map<String, dynamic> args,
    ) async {
      commands.add(op);
      if (op == 'draft_get') return {'text': ''};
      if (op == 'queue') {
        expect(args['submittedDraft'], ' draft ');
        expect(args['text'], 'draft');
        started.complete();
        await sent.future;
      }
      return {};
    }

    final drafts = ConversationDrafts(
      controller,
      command,
      () => fail('write failed'),
    );
    await drafts.select('A');
    controller.text = ' draft ';
    final submitting = drafts.enqueue('A', 'id');
    await started.future;
    controller.text = 'second';
    sent.complete();
    await submitting;
    expect(controller.text, 'second');
    await drafts.close();
    expect(commands, ['draft_get', 'draft_put', 'queue', 'draft_put']);
    controller.dispose();
  });
}
