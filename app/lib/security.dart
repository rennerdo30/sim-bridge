import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// A bridge root key is always 256 bits. Anything else is a corrupt invitation,
/// and accepting it would produce a session that enrolls successfully and then
/// fails to encrypt anything.
const bridgeKeyBytes = 32;

class BridgeCrypto {
  BridgeCrypto(List<int> keyBytes) : _key = SecretKey(keyBytes);
  final SecretKey _key;
  static final _cipher = AesGcm.with256bits();

  static Future<List<int>> newKey() async =>
      (await SecretKeyData.random(length: bridgeKeyBytes).extractBytes());

  Future<Map<String, dynamic>> seal(Map<String, dynamic> value) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: _key,
    );
    return {
      'v': 1,
      'ciphertext': base64UrlEncode(box.cipherText),
      'nonce': base64UrlEncode(box.nonce),
      'mac': base64UrlEncode(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> open(Map<String, dynamic> envelope) async {
    if (envelope['v'] != 1) throw const FormatException('Unknown envelope');
    final clear = await _cipher.decrypt(
      SecretBox(
        base64Url.decode(envelope['ciphertext']),
        nonce: base64Url.decode(envelope['nonce']),
        mac: Mac(base64Url.decode(envelope['mac'])),
      ),
      secretKey: _key,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}

class BridgeIdentity {
  const BridgeIdentity({required this.bridgeId, required this.inviteToken});
  final String bridgeId;
  final String inviteToken;

  static Future<BridgeIdentity> derive(List<int> rootKey) async {
    final hmac = Hmac.sha256();
    final key = SecretKey(rootKey);
    final id = await hmac.calculateMac(
      utf8.encode('simbridge/bridge-id/v1'),
      secretKey: key,
    );
    final invite = await hmac.calculateMac(
      utf8.encode('simbridge/invite-auth/v1'),
      secretKey: key,
    );
    return BridgeIdentity(
      bridgeId: base64UrlEncode(id.bytes).replaceAll('=', ''),
      inviteToken: base64UrlEncode(invite.bytes).replaceAll('=', ''),
    );
  }
}

class RecoveryCode {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String encode(List<int> bytes) {
    var bits = 0;
    var value = 0;
    final output = StringBuffer();
    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        output.write(_alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) output.write(_alphabet[(value << (5 - bits)) & 31]);
    final raw = output.toString();
    return [
      for (var i = 0; i < raw.length; i += 4)
        raw.substring(i, i + 4 > raw.length ? raw.length : i + 4),
    ].join('-');
  }

  static List<int> decode(String code) {
    final normalized = code
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '')
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    var bits = 0;
    var value = 0;
    final output = <int>[];
    for (final rune in normalized.runes) {
      final index = _alphabet.indexOf(String.fromCharCode(rune));
      if (index < 0) {
        throw const FormatException(
          'Recovery code contains an invalid character',
        );
      }
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        output.add((value >> (bits - 8)) & 255);
        bits -= 8;
      }
    }
    if (output.length != bridgeKeyBytes) {
      throw const FormatException('Recovery code must contain 52 characters');
    }
    return output;
  }
}

final _privateHostPatterns = [
  RegExp(r'^localhost$'),
  RegExp(r'^127\.\d+\.\d+\.\d+$'),
  RegExp(r'^10\.\d+\.\d+\.\d+$'),
  RegExp(r'^192\.168\.\d+\.\d+$'),
  RegExp(r'^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$'),
  RegExp(r'^169\.254\.\d+\.\d+$'),
  RegExp(r'^::1$'),
  RegExp(r'^f[cde][0-9a-f]{2}:', caseSensitive: false),
  // Suffixes a router hands out on a home network. None is publicly
  // resolvable, so none can be pointed at an internet host.
  RegExp(r'\.local$', caseSensitive: false),
  RegExp(r'\.home$', caseSensitive: false),
  RegExp(r'\.home\.arpa$', caseSensitive: false),
  RegExp(r'\.lan$', caseSensitive: false),
  RegExp(r'\.internal$', caseSensitive: false),
  RegExp(r'^[a-z0-9-]+$', caseSensitive: false),
];

/// True when [host] is on a local network, where plain HTTP is a deliberate
/// trade-off rather than an open invitation to a passive eavesdropper.
bool isPrivateHost(String host) {
  final bare = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  return _privateHostPatterns.any((pattern) => pattern.hasMatch(bare));
}

/// Relay addresses must be HTTPS unless they are on the local network.
///
/// Everything that authenticates this phone — the enrollment verifier, the
/// device bearer token, the relay access key — travels in these requests, so a
/// cleartext relay across the internet would hand all of them to any on-path
/// observer.
bool isSafeRelayUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  return uri.scheme == 'http' && isPrivateHost(uri.host);
}

class BridgeInvite {
  const BridgeInvite({required this.server, required this.key});
  final String server;
  final List<int> key;

  String encode() {
    final payload = jsonEncode({
      'v': 1,
      'server': server,
      'key': base64UrlEncode(key),
    });
    return 'simbridge://invite#${base64UrlEncode(utf8.encode(payload))}';
  }

  static BridgeInvite decode(String value) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'simbridge' || uri.host != 'invite') {
      throw const FormatException('Not a Sim Bridge invitation');
    }
    final data =
        jsonDecode(utf8.decode(base64Url.decode(uri.fragment)))
            as Map<String, dynamic>;
    if (data['v'] != 1) throw const FormatException('Unsupported invitation');
    final server = data['server'];
    if (server is! String || !isSafeRelayUrl(server)) {
      throw const FormatException(
        'Invitation points at an unsupported relay address',
      );
    }
    final key = base64Url.decode(data['key']);
    if (key.length != bridgeKeyBytes) {
      throw const FormatException(
        'Invitation does not contain a valid bridge key',
      );
    }
    return BridgeInvite(server: server, key: key);
  }
}
