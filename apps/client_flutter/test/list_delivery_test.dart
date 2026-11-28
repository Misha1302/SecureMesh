import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/delivery_client.dart';
import 'package:securemesh_client/transport.dart';

class _Relay implements MeshTransport {
  final pulled = <String>[];
  final sent = <String>[];

  @override
  Future<Map<String, dynamic>> sync(
    String group,
    String cursor, {
    int limit = 6,
  }) async {
    pulled.add(group);
    return {'messages': [], 'nextCursor': cursor};
  }

  @override
  Future<Map<String, dynamic>> send(Map<String, dynamic> message) async {
    sent.add(message['id'] as String);
    return {'durable': true, 'serverSequence': 1};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('list view drains the outbox and rotates verified chats; an open chat takes precedence', () async {
    final relay = _Relay();
    final outbox = <Map<String, dynamic>>[
      {'kind': 1, 'id': 'm', 'group': 'second'},
    ];
    final delivery = NativeDelivery(
      transport: relay,
      crypto: (op, [args = const {}]) async {
        switch (op) {
          case 'outbox':
            return {'messages': outbox.toList()};
          case 'cursor':
            return {'cursor': '', 'seq': 0};
          case 'saved':
            expect(args['group'], 'second');
            outbox.clear();
            return {};
          default:
            throw StateError(op);
        }
      },
    );
    for (var i = 0; i < 3; i++) {
      await delivery.tick('first', listedGroups: ['first', 'second']);
      await Future<void>.delayed(Duration.zero);
    }
    final duringConversation = await delivery.tick('selected');
    expect(duringConversation.delay, const Duration(milliseconds: 250));
    expect(relay.pulled, ['first', 'second', 'first', 'selected']);
    expect(relay.sent, ['m']);
    expect(outbox, isEmpty);
    for (var i = 0; i < 8; i++) {
      await delivery.tick('selected');
    }
    final idle = await delivery.tick('selected');
    expect(idle.delay, const Duration(seconds: 3));
    delivery.close();
  });
}
