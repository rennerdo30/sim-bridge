import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/device_authorization.dart';

String fixtureCertificate(
  DeviceSigningIdentity identity, {
  String deviceId = 'gateway',
  String bridgeId = 'bridge',
  bool authority = true,
}) =>
    '${base64UrlEncode(utf8.encode(jsonEncode({'v': 1, 'issuer': 'fixture-issuer', 'bridgeId': bridgeId, 'incarnation': 'fixture-incarnation', 'deviceId': deviceId, 'publicKey': identity.publicKey, 'smsGateway': authority, 'isOwner': authority, 'authority': authority}))).replaceAll('=', '')}.fixture-tag';
String fixturePolicy(Session session, int revision, {bool joinable = true}) =>
    jsonEncode({
      'v': 1,
      'issuer': 'fixture-issuer',
      'bridgeId': session.bridgeId,
      'incarnation': 'fixture-incarnation',
      'authorityDeviceId': session.deviceId,
      'revision': revision,
      'joinable': joinable,
      'erased': false,
      'inviteTokenHash': 'fixture-verifier',
      'createdAt': '2026-10-13T00:00:00Z',
      'members': [
        {
          'certificate': session.authorization!.certificate,
          'name': 'Synthetic gateway',
          'capabilities': {'smsGateway': true},
        },
      ],
    });
Future<Map<String, dynamic>> fixtureChallenge(
  Map<String, dynamic> request, {
  String bootId = 'boot-after-restart',
}) async {
  Future<String> digest(String value) async => (await Sha256().hash(
    utf8.encode(value),
  )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final identity = request['certificate'] ?? request['devicePublicKey'];
  return {
    'bootId': bootId,
    'challengeId': 'synthetic-challenge',
    'nonce': 'synthetic-nonce',
    'expiresAt': DateTime.now()
        .toUtc()
        .add(const Duration(seconds: 30))
        .millisecondsSinceEpoch,
    'signingPayload': jsonEncode([
      'simbridge/pop/v1',
      bootId,
      'synthetic-challenge',
      'synthetic-nonce',
      request['operation'],
      await digest(identity),
      await digest(request['payloadJson']),
    ]),
  };
}
