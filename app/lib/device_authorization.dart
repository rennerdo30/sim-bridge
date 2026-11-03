import 'dart:convert';

import 'package:cryptography/cryptography.dart';

List<int> decodeAuthorizationBytes(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// Separate device identity: never derived from the bridge's shared encryption key.
class DeviceSigningIdentity {
  const DeviceSigningIdentity(this.seed, this.publicKey);
  final String seed, publicKey;
  static final _algorithm = Ed25519();

  static Future<DeviceSigningIdentity> generate() async {
    final pair = await _algorithm.newKeyPair();
    return DeviceSigningIdentity(
      base64UrlEncode(await pair.extractPrivateKeyBytes()).replaceAll('=', ''),
      base64UrlEncode(
        (await pair.extractPublicKey()).bytes,
      ).replaceAll('=', ''),
    );
  }

  Future<String> sign(String payload) async {
    final pair = await _algorithm.newKeyPairFromSeed(
      decodeAuthorizationBytes(seed),
    );
    final actual = base64UrlEncode(
      (await pair.extractPublicKey()).bytes,
    ).replaceAll('=', '');
    if (actual != publicKey) {
      throw const FormatException('Device identity mismatch');
    }
    return base64UrlEncode(
      (await _algorithm.sign(utf8.encode(payload), keyPair: pair)).bytes,
    ).replaceAll('=', '');
  }
}

/// Stored as one protected record. Gateway policy contains authorization only;
/// it never contains message bodies, commands, previews, or the shared root key.
class DeviceAuthorization {
  const DeviceAuthorization({
    required this.identity,
    required this.certificate,
    this.policyJson,
    this.bootId,
  });
  final DeviceSigningIdentity identity;
  final String certificate;
  final String? policyJson;
  final String? bootId;
  Map<String, dynamic> get claims {
    final parts = certificate.split('.');
    if (parts.length != 2) {
      throw const FormatException('Invalid membership certificate');
    }
    final value = jsonDecode(
      utf8.decode(decodeAuthorizationBytes(parts.first)),
    );
    if (value is! Map<String, dynamic> ||
        value['v'] != 1 ||
        value['publicKey'] != identity.publicKey) {
      throw const FormatException('Certificate identity mismatch');
    }
    return value;
  }

  bool get authority => claims['authority'] == true;
  void validateFor(String bridgeId, String deviceId) {
    final value = claims;
    if (value['bridgeId'] != bridgeId || value['deviceId'] != deviceId) {
      throw const FormatException('Certificate enrollment mismatch');
    }
  }

  void assertPolicyNotOlder(DeviceAuthorization? previous) {
    if (previous?.policyJson == null) return;
    if (previous!.claims['issuer'] != claims['issuer'] ||
        previous.claims['incarnation'] != claims['incarnation']) {
      return;
    }
    if (policyJson == null) {
      throw const FormatException('Missing existing authority policy');
    }
    final oldRevision = (jsonDecode(previous.policyJson!) as Map)['revision'];
    final newRevision = (jsonDecode(policyJson!) as Map)['revision'];
    if (oldRevision is! int ||
        newRevision is! int ||
        newRevision < oldRevision ||
        (newRevision == oldRevision && policyJson != previous.policyJson)) {
      throw const FormatException('Authority policy rollback');
    }
  }

  Future<String> challengeSignature(
    Map<String, dynamic> challenge,
    String operation,
    String payloadJson,
  ) async {
    final text = challenge['signingPayload'];
    final value = text is String ? jsonDecode(text) : null;
    final certificateHash = (await Sha256().hash(
      utf8.encode(certificate),
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final payloadHash = (await Sha256().hash(
      utf8.encode(payloadJson),
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    if (value is! List ||
        value.length != 7 ||
        value[0] != 'simbridge/pop/v1' ||
        value[1] != challenge['bootId'] ||
        value[2] != challenge['challengeId'] ||
        value[3] != challenge['nonce'] ||
        value[4] != operation ||
        value[5] != certificateHash ||
        value[6] != payloadHash ||
        value[1] is! String ||
        (value[1] as String).isEmpty ||
        value[2] is! String ||
        (value[2] as String).isEmpty ||
        value[3] is! String ||
        (value[3] as String).isEmpty) {
      throw const FormatException('Unexpected authorization challenge');
    }
    final expiresAt = challenge['expiresAt'];
    final expiry = expiresAt is int
        ? DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true)
        : DateTime.tryParse(expiresAt?.toString() ?? '');
    if (expiry == null ||
        expiry.isBefore(DateTime.now().toUtc()) ||
        expiry.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        )) {
      throw const FormatException('Expired authorization challenge');
    }
    return identity.sign(text as String);
  }

  DeviceAuthorization withPolicy(String value) => DeviceAuthorization(
    identity: identity,
    certificate: certificate,
    policyJson: value,
    bootId: bootId,
  );
  DeviceAuthorization withBoot(String? value) => DeviceAuthorization(
    identity: identity,
    certificate: certificate,
    policyJson: policyJson,
    bootId: value,
  );
  Map<String, dynamic> toJson() => {
    'v': 1,
    'seed': identity.seed,
    'publicKey': identity.publicKey,
    'certificate': certificate,
    if (policyJson != null) 'policyJson': policyJson,
    if (bootId != null) 'bootId': bootId,
  };
  factory DeviceAuthorization.fromJson(Map<String, dynamic> value) {
    if (value['v'] != 1 ||
        value['seed'] is! String ||
        value['publicKey'] is! String ||
        value['certificate'] is! String ||
        decodeAuthorizationBytes(value['seed']).length != 32 ||
        decodeAuthorizationBytes(value['publicKey']).length != 32 ||
        (value['certificate'] as String).isEmpty ||
        (value['policyJson'] != null && value['policyJson'] is! String)) {
      throw const FormatException('Incomplete device authorization');
    }
    return DeviceAuthorization(
      identity: DeviceSigningIdentity(value['seed'], value['publicKey']),
      certificate: value['certificate'],
      policyJson: value['policyJson'],
      bootId: value['bootId'] as String?,
    );
  }
}
