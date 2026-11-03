import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/gateway_runtime.dart';
import 'package:sim_bridge/protocol.dart';

void main() {
  test(
    'headless push preview retains extension protocol bindings and code extraction',
    () async {
      final session = Session(
        server: 'http://127.0.0.1:8787',
        token: 'test',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      final envelope = await sealedPushPreview(session, {
        'eventId': 'durable-event',
        'address': 'test',
        'body': 'Reference 1111, verification code: 654321',
      });
      final clear = await session.crypto.open(envelope!);
      expect(clear['v'], commandProtocolVersion);
      expect(clear['kind'], 'sms');
      expect(clear['direction'], 'incoming');
      expect(clear['eventId'], 'durable-event');
      expect(clear['senderDeviceId'], session.deviceId);
      expect(clear['bridgeId'], session.bridgeId);
      expect(clear['otp'], '654321');
    },
  );
}
