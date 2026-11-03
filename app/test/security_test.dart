import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/security.dart';

void main() {
  test('AES-256-GCM envelope round trips and authenticates', () async {
    final key = await BridgeCrypto.newKey();
    expect(key, hasLength(32));
    final crypto = BridgeCrypto(key);
    final envelope = await crypto.seal({
      'address': '+491234',
      'body': 'secret OTP',
    });
    expect(jsonEncode(envelope), isNot(contains('secret OTP')));
    expect(await crypto.open(envelope), {
      'address': '+491234',
      'body': 'secret OTP',
    });

    envelope['ciphertext'] = base64UrlEncode(List<int>.filled(8, 0));
    await expectLater(crypto.open(envelope), throwsA(anything));
  });

  test('QR invitation transports a 256-bit root key', () async {
    final invite = BridgeInvite(
      server: 'https://relay.example',
      key: await BridgeCrypto.newKey(),
    );
    final decoded = BridgeInvite.decode(invite.encode());
    expect(decoded.server, invite.server);
    expect(decoded.key, invite.key);
  });

  test('manual recovery code preserves all 256 key bits', () async {
    final key = await BridgeCrypto.newKey();
    final code = RecoveryCode.encode(key);
    expect(code.replaceAll('-', ''), hasLength(52));
    expect(RecoveryCode.decode(code), key);
    final identity = await BridgeIdentity.derive(key);
    final recoveredIdentity = await BridgeIdentity.derive(
      RecoveryCode.decode(code),
    );
    expect(recoveredIdentity.bridgeId, identity.bridgeId);
    expect(recoveredIdentity.inviteToken, identity.inviteToken);
  });
}
