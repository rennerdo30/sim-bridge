import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/protocol.dart';
import 'package:sim_bridge/security.dart';

const _bridgeId = 'bridge-one';
const _gatewayId = 'gateway-one';
const _clientId = 'client-one';

Map<String, dynamic> sampleCommand({
  String bridgeId = _bridgeId,
  String targetDeviceId = _gatewayId,
  DateTime? issuedAt,
}) => buildCommand(
  type: 'send_sms',
  bridgeId: bridgeId,
  senderDeviceId: _clientId,
  targetDeviceId: targetDeviceId,
  issuedAt: issuedAt ?? DateTime.now(),
  payload: {'address': '+15551234567', 'body': 'hello'},
);

Future<ExecutedCommands> emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return ExecutedCommands.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('command binding', () {
    test('a well-formed command for this gateway is accepted', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          sampleCommand(),
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        isNull,
      );
    });

    test('a replayed command is refused the second time', () async {
      final executed = await emptyStore();
      final command = sampleCommand();
      final now = DateTime.now();
      expect(
        rejectCommand(
          command,
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: now,
        ),
        isNull,
      );
      await executed.remember(command['commandId'] as String);
      expect(
        rejectCommand(
          command,
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: now,
        ),
        CommandRejection.replayed,
      );
    });

    test('replay protection survives a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final command = sampleCommand();
      final first = await ExecutedCommands.load();
      await first.remember(command['commandId'] as String);

      final afterRestart = await ExecutedCommands.load();
      expect(
        rejectCommand(
          command,
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: afterRestart,
          now: DateTime.now(),
        ),
        CommandRejection.replayed,
      );
    });

    test('a command aimed at another gateway is refused', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          sampleCommand(targetDeviceId: 'gateway-two'),
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        CommandRejection.wrongTarget,
      );
    });

    test('a command sealed for another bridge is refused', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          sampleCommand(bridgeId: 'other-bridge'),
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        CommandRejection.wrongBridge,
      );
    });

    test('a command older than the freshness window is refused', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          sampleCommand(
            issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
          ),
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        CommandRejection.stale,
      );
    });

    test('a command from the future beyond clock skew is refused', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          sampleCommand(issuedAt: DateTime.now().add(const Duration(hours: 1))),
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        CommandRejection.stale,
      );
    });

    test('an unversioned legacy command is refused', () async {
      final executed = await emptyStore();
      expect(
        rejectCommand(
          {'type': 'send_sms', 'address': '+15551234567', 'body': 'hello'},
          bridgeId: _bridgeId,
          deviceId: _gatewayId,
          executed: executed,
          now: DateTime.now(),
        ),
        CommandRejection.malformed,
      );
    });

    test('every command carries a distinct identifier', () {
      final ids = List.generate(200, (_) => sampleCommand()['commandId']);
      expect(ids.toSet().length, 200);
    });
  });

  group('notification de-duplication', () {
    Map<String, dynamic> message(String at, String body) => {
      'kind': 'sms',
      'direction': 'incoming',
      'occurredAt': at,
      'address': '+15550000000',
      'body': body,
    };

    test('sealed event id is stable across notification preview and inbox', () {
      final full = message('2026-08-23T10:00:00Z', 'code 123456')
        ..['eventId'] = 'gateway-event-1';
      final preview = message('2026-08-23T10:00:00Z', 'code 123')
        ..['eventId'] = 'gateway-event-1';
      expect(messageKey(full), 'event:gateway-event-1');
      expect(messageKey(preview), messageKey(full));
    });

    test(
      'a message held back by the relay still notifies when it arrives',
      () async {
        SharedPreferences.setMockInitialValues({});
        final notified = await NotifiedMessages.load();
        final delayed = message('2026-08-23T10:00:00Z', 'your code is 1234');
        final newer = message('2026-08-23T10:05:00Z', 'unrelated');

        // The relay delivers only the newer message first.
        await notified.rememberAll([messageKey(newer)]);

        // A high-water timestamp would now skip the older message forever.
        expect(notified.contains(messageKey(delayed)), isFalse);
      },
    );

    test('a message already seen does not notify twice', () async {
      SharedPreferences.setMockInitialValues({});
      final notified = await NotifiedMessages.load();
      final item = message('2026-08-23T10:00:00Z', 'your code is 1234');
      await notified.rememberAll([messageKey(item)]);
      expect(notified.contains(messageKey(item)), isTrue);
    });

    test('seen messages survive a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final item = message('2026-08-23T10:00:00Z', 'your code is 1234');
      await (await NotifiedMessages.load()).rememberAll([messageKey(item)]);

      final afterRestart = await NotifiedMessages.load();
      expect(afterRestart.isEmpty, isFalse);
      expect(afterRestart.contains(messageKey(item)), isTrue);
    });

    test('distinct messages get distinct keys', () {
      final a = message('2026-08-23T10:00:00Z', 'code 1111');
      final b = message('2026-08-23T10:00:00Z', 'code 2222');
      expect(messageKey(a), isNot(messageKey(b)));
    });
  });

  group('relay address safety', () {
    test('local addresses may use plain http', () {
      for (final url in [
        'http://192.168.1.10:8787',
        'http://10.0.2.2:8787',
        'http://127.0.0.1:8787',
        'http://Mac-home.local:8787',
        'http://172.16.4.5:8787',
      ]) {
        expect(isSafeRelayUrl(url), isTrue, reason: url);
      }
    });

    test('a relay beyond the local network must use https', () {
      expect(isSafeRelayUrl('http://relay.example.com:8787'), isFalse);
      expect(isSafeRelayUrl('http://203.0.113.9:8787'), isFalse);
      expect(isSafeRelayUrl('https://relay.example.com'), isTrue);
    });

    test('malformed addresses are refused', () {
      for (final url in [
        '',
        'not a url',
        'ftp://relay.example.com',
        'http://',
      ]) {
        expect(isSafeRelayUrl(url), isFalse, reason: url);
      }
    });
  });

  group('invitation validation', () {
    test('an invitation carrying a short key is refused', () {
      // A 3-byte key would derive a valid-looking identity, enroll
      // successfully, and then fail on every encrypt.
      const shortKeyInvite =
          'simbridge://invite#'
          'eyJ2IjoxLCJzZXJ2ZXIiOiJodHRwOi8vMTkyLjE2OC4xLjEwOjg3ODciLCJrZXkiOiJBQUVDIn0=';
      expect(
        () => BridgeInvite.decode(shortKeyInvite),
        throwsA(isA<FormatException>()),
      );
    });

    test('an invitation pointing at a cleartext internet relay is refused', () {
      final hostile = BridgeInvite(
        server: 'http://evil.example.com:8787',
        key: List<int>.filled(bridgeKeyBytes, 7),
      ).encode();
      expect(
        () => BridgeInvite.decode(hostile),
        throwsA(isA<FormatException>()),
      );
    });

    test('a genuine local invitation still round trips', () {
      final key = List<int>.generate(bridgeKeyBytes, (index) => index);
      final invite = BridgeInvite(server: 'http://192.168.1.10:8787', key: key);
      final decoded = BridgeInvite.decode(invite.encode());
      expect(decoded.key, key);
      expect(decoded.server, 'http://192.168.1.10:8787');
    });
  });
}
