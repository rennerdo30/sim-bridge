import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'security.dart';
import 'device_authorization.dart';

class StoredSession {
  const StoredSession(this.session, {required this.gateway});
  final Session session;
  final bool gateway;
}

/// Shared by the activity and the service-owned engine. Metadata is reloaded
/// because each engine has its own SharedPreferences cache; credentials stay
/// in Keystore/Keychain. Incomplete or temporarily inaccessible pairing data
/// is preserved rather than silently deleted.
class SessionStore {
  SessionStore({
    bool? allowGatewayPolicyStorage,
    Future<void> Function()? authorizationBarrier,
  }) : _allowGatewayPolicyStorage =
           allowGatewayPolicyStorage ?? Platform.isAndroid,
       _authorizationBarrier = authorizationBarrier ?? _flushAndroidStorage;
  final bool _allowGatewayPolicyStorage;
  final Future<void> Function() _authorizationBarrier;
  static Future<void> _flushAndroidStorage() async {
    if (Platform.isAndroid &&
        await const MethodChannel(
              'app.simbridge/sms',
            ).invokeMethod<bool>('flushAuthorizationStorage') !=
            true) {
      throw const StoredPairingUnavailable();
    }
  }

  Future<void> _writeProtected(String key, String value) async {
    await secureStorage.write(key: key, value: value);
    await _authorizationBarrier();
    if (await secureStorage.read(key: key) != value) {
      throw const StoredPairingUnavailable();
    }
  }

  static const secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    mOptions: MacOsOptions(
      accountName: 'dev.renner.simbridge.desktop.credentials',
      usesDataProtectionKeychain: false,
      accessibility: null,
      synchronizable: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Persist a new device identity before any enrollment request, including
  /// retries after a lost response. This is never used for known-session recovery.
  Future<({List<int> key, DeviceSigningIdentity identity})> prepareEnrollment(
    String server, {
    List<int>? invitationKey,
  }) async {
    final stored = await secureStorage.read(key: 'pendingDeviceIdentity');
    if (stored != null) {
      final value = jsonDecode(stored) as Map<String, dynamic>;
      if (value['server'] != server ||
          (invitationKey != null &&
              value['rootKey'] != base64UrlEncode(invitationKey))) {
        throw const StoredPairingUnavailable();
      }
      final key = decodeAuthorizationBytes(value['rootKey'] as String);
      final identity = DeviceSigningIdentity(
        value['seed'] as String,
        value['publicKey'] as String,
      );
      if (key.length != bridgeKeyBytes ||
          decodeAuthorizationBytes(identity.seed).length != 32 ||
          decodeAuthorizationBytes(identity.publicKey).length != 32) {
        throw const StoredPairingUnavailable();
      }
      return (key: key, identity: identity);
    }
    final key = invitationKey ?? await BridgeCrypto.newKey();
    final identity = await DeviceSigningIdentity.generate();
    final text = jsonEncode({
      'v': 1,
      'server': server,
      'rootKey': base64UrlEncode(key),
      'seed': identity.seed,
      'publicKey': identity.publicKey,
    });
    await _writeProtected('pendingDeviceIdentity', text);
    if (await secureStorage.read(key: 'pendingDeviceIdentity') != text) {
      throw const StoredPairingUnavailable();
    }
    return (key: key, identity: identity);
  }

  static final _upgradeIdentities = <String, Future<DeviceSigningIdentity>>{};
  Future<DeviceSigningIdentity> prepareUpgradeIdentity(
    Session session, {
    bool createIfMissing = true,
  }) {
    final id = '${session.server}\n${session.bridgeId}\n${session.deviceId}';
    final active = _upgradeIdentities[id];
    if (active != null) return active;
    final work = _prepareUpgradeIdentity(
      session,
      createIfMissing: createIfMissing,
    );
    _upgradeIdentities[id] = work;
    return work.whenComplete(() {
      if (identical(_upgradeIdentities[id], work)) {
        _upgradeIdentities.remove(id);
      }
    });
  }

  Future<DeviceSigningIdentity> _prepareUpgradeIdentity(
    Session session, {
    bool createIfMissing = true,
  }) async {
    final stored = await secureStorage.read(key: 'pendingUpgradeIdentity');
    if (stored != null) {
      final record = jsonDecode(stored) as Map<String, dynamic>;
      if (record['server'] != session.server ||
          record['deviceId'] != session.deviceId ||
          record['bridgeId'] != session.bridgeId) {
        throw const StoredPairingUnavailable();
      }
      final identity = DeviceSigningIdentity(
        record['seed'] as String,
        record['publicKey'] as String,
      );
      if (decodeAuthorizationBytes(identity.seed).length != 32 ||
          decodeAuthorizationBytes(identity.publicKey).length != 32) {
        throw const StoredPairingUnavailable();
      }
      return identity;
    }
    if (!createIfMissing ||
        await secureStorage.read(key: 'operatorRecovery') != null) {
      throw const StoredPairingUnavailable();
    }
    final identity = await DeviceSigningIdentity.generate();
    final text = jsonEncode({
      'v': 1,
      'server': session.server,
      'deviceId': session.deviceId,
      'bridgeId': session.bridgeId,
      'seed': identity.seed,
      'publicKey': identity.publicKey,
    });
    await _writeProtected('pendingUpgradeIdentity', text);
    if (await secureStorage.read(key: 'pendingUpgradeIdentity') != text) {
      throw const StoredPairingUnavailable();
    }
    return identity;
  }

  Future<void> finishUpgradeIdentity() async {
    await secureStorage.delete(key: 'pendingUpgradeIdentity');
    await _authorizationBarrier();
  }

  Future<void> stageOperatorRecovery(
    Session session,
    String certificate,
    String? policyJson, {
    required bool gateway,
  }) async {
    final identity =
        session.authorization?.identity ??
        await prepareUpgradeIdentity(session);
    final auth = DeviceAuthorization(
      identity: identity,
      certificate: certificate,
      policyJson: policyJson,
    );
    auth.validateFor(session.bridgeId, session.deviceId);
    if (auth.claims['smsGateway'] != gateway ||
        (auth.authority &&
            (!_allowGatewayPolicyStorage || !gateway || policyJson == null))) {
      throw const StoredPairingUnavailable();
    }
    auth.assertPolicyNotOlder(session.authorization);
    final text = jsonEncode({
      'v': 1,
      'server': session.server,
      'bridgeId': session.bridgeId,
      'deviceId': session.deviceId,
      'certificate': certificate,
      'policyJson': policyJson,
    });
    await _writeProtected('operatorRecovery', text);
    if (await secureStorage.read(key: 'operatorRecovery') != text) {
      throw const StoredPairingUnavailable();
    }
  }

  Future<DeviceAuthorization?> stagedOperatorRecovery(
    Session session, {
    required bool gateway,
  }) async {
    final text = await secureStorage.read(key: 'operatorRecovery');
    if (text == null) return null;
    final value = jsonDecode(text) as Map<String, dynamic>;
    if (value['v'] != 1 ||
        value['server'] != session.server ||
        value['bridgeId'] != session.bridgeId ||
        value['deviceId'] != session.deviceId) {
      throw const StoredPairingUnavailable();
    }
    final identity =
        session.authorization?.identity ??
        await prepareUpgradeIdentity(session, createIfMissing: false);
    final auth = DeviceAuthorization(
      identity: identity,
      certificate: value['certificate'],
      policyJson: value['policyJson'],
    );
    auth.validateFor(session.bridgeId, session.deviceId);
    if (auth.claims['smsGateway'] != gateway ||
        (auth.authority &&
            (!_allowGatewayPolicyStorage ||
                !gateway ||
                auth.policyJson == null))) {
      throw const StoredPairingUnavailable();
    }
    return auth;
  }

  Future<void> finishOperatorRecovery() async {
    await secureStorage.delete(key: 'operatorRecovery');
    await finishUpgradeIdentity();
  }

  Future<StoredSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final server = prefs.getString('server');
    final deviceId = prefs.getString('deviceId');
    final bridgeId = prefs.getString('bridgeId');
    final token = await secureStorage.read(key: 'deviceToken');
    final encoded = await secureStorage.read(key: 'bridgeKey');
    final authorizationText = await secureStorage.read(
      key: 'deviceAuthorization',
    );
    DeviceAuthorization? authorization;
    String? recoveredToken;
    if (authorizationText != null) {
      final record = jsonDecode(authorizationText) as Map<String, dynamic>;
      if (record['v'] == 2) {
        final auth = DeviceAuthorization.fromJson(
          Map<String, dynamic>.from(record['authorization']),
        );
        final recordKey = decodeAuthorizationBytes(record['rootKey'] as String);
        final recordServer = record['server'] as String;
        final recordDevice = record['deviceId'] as String;
        final recordBridge = record['bridgeId'] as String;
        auth.validateFor(recordBridge, recordDevice);
        if (recordKey.length != bridgeKeyBytes ||
            !isSafeRelayUrl(recordServer) ||
            record['token'] is! String ||
            record['gateway'] != auth.claims['smsGateway']) {
          throw const StoredPairingUnavailable();
        }
        if (auth.policyJson != null && !_allowGatewayPolicyStorage) {
          throw const StoredPairingUnavailable();
        }
        final pendingText = await secureStorage.read(
          key: 'pendingDeviceIdentity',
        );
        if (pendingText != null) {
          final pending = jsonDecode(pendingText) as Map;
          if (pending['server'] != recordServer ||
              pending['publicKey'] != auth.identity.publicKey ||
              pending['rootKey'] != record['rootKey']) {
            throw const StoredPairingUnavailable();
          }
        }
        if (prefs.getBool('sessionReady') == false ||
            server != recordServer ||
            deviceId != recordDevice ||
            bridgeId != recordBridge ||
            token == null ||
            encoded == null) {
          await secureStorage.write(key: 'deviceToken', value: record['token']);
          await secureStorage.write(key: 'bridgeKey', value: record['rootKey']);
          await _authorizationBarrier();
          await prefs.setString('server', recordServer);
          await prefs.setString('deviceId', recordDevice);
          await prefs.setString('bridgeId', recordBridge);
          await prefs.setBool('gateway', record['gateway'] as bool);
          await prefs.setBool('sessionReady', true);
          await secureStorage.delete(key: 'pendingDeviceIdentity');
        }
        return StoredSession(
          Session(
            server: recordServer,
            token: record['token'],
            deviceId: recordDevice,
            bridgeId: recordBridge,
            key: recordKey,
            authorization: auth,
          ),
          gateway: record['gateway'] as bool,
        );
      }

      if (record['bridgeId'] != bridgeId ||
          record['deviceId'] != deviceId ||
          record['token'] is! String) {
        throw const StoredPairingUnavailable();
      }
      authorization = DeviceAuthorization.fromJson(
        Map<String, dynamic>.from(record['authorization']),
      );
      recoveredToken = record['token'] as String;
    }
    final anyPairing =
        deviceId != null ||
        bridgeId != null ||
        token != null ||
        encoded != null ||
        authorizationText != null;
    if (!anyPairing) return null;
    if (prefs.getBool('sessionReady') == false) {
      throw const StoredPairingUnavailable();
    }
    if (server == null ||
        !isSafeRelayUrl(server) ||
        deviceId == null ||
        bridgeId == null ||
        token == null ||
        encoded == null) {
      throw const StoredPairingUnavailable();
    }
    final key = decodeAuthorizationBytes(encoded);
    if (key.length != bridgeKeyBytes) throw const StoredPairingUnavailable();
    return StoredSession(
      Session(
        server: server,
        token: recoveredToken ?? token,
        deviceId: deviceId,
        bridgeId: bridgeId,
        key: key,
        authorization: authorization,
      ),
      gateway: prefs.getBool('gateway') ?? false,
    );
  }

  Future<void> save(Session session, {required bool gateway}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sessionReady', false);
    if (session.authorization != null) {
      await persistAuthorization(session);
    } else {
      await secureStorage.delete(key: 'deviceAuthorization');
    }
    await secureStorage.write(key: 'deviceToken', value: session.token);
    await secureStorage.write(
      key: 'bridgeKey',
      value: base64UrlEncode(session.key),
    );
    await prefs.setString('server', session.server);
    await prefs.setString('deviceId', session.deviceId);
    await prefs.setString('bridgeId', session.bridgeId);
    await prefs.setBool('gateway', gateway);
    await prefs.setBool('sessionReady', true);
    await secureStorage.delete(key: 'pendingDeviceIdentity');
    await _authorizationBarrier();
  }

  /// One authenticated-encryption storage write commits policy before relay ACK.
  /// This never changes enrollment IDs, recovery markers, or native journals.
  Future<void> persistAuthorization(Session session) async {
    final auth = session.authorization;
    if (auth == null) throw const StoredPairingUnavailable();
    auth.validateFor(session.bridgeId, session.deviceId);
    if (auth.policyJson != null &&
        (!_allowGatewayPolicyStorage || !auth.authority)) {
      throw const StoredPairingUnavailable();
    }
    final previousText = await secureStorage.read(key: 'deviceAuthorization');
    if (previousText != null) {
      final previous = jsonDecode(previousText) as Map<String, dynamic>;
      if (previous['deviceId'] == session.deviceId &&
          previous['bridgeId'] == session.bridgeId) {
        auth.assertPolicyNotOlder(
          DeviceAuthorization.fromJson(
            Map<String, dynamic>.from(previous['authorization']),
          ),
        );
      }
    }
    final text = jsonEncode({
      'v': 2,
      'server': session.server,
      'rootKey': base64UrlEncode(session.key),
      'gateway': auth.claims['smsGateway'],
      'bridgeId': session.bridgeId,
      'deviceId': session.deviceId,
      'token': session.token,
      'authorization': auth.toJson(),
    });
    await _writeProtected('deviceAuthorization', text);
    if (await secureStorage.read(key: 'deviceAuthorization') != text) {
      throw const StoredPairingUnavailable();
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sessionReady', false);
    // The authorization record can rebuild every other credential on load, so
    // it goes first: an interrupted clear must never resurrect a left pairing.
    await secureStorage.delete(key: 'deviceAuthorization');
    await secureStorage.delete(key: 'deviceToken');
    await secureStorage.delete(key: 'bridgeKey');
    await secureStorage.delete(key: 'pendingDeviceIdentity');
    await secureStorage.delete(key: 'pendingUpgradeIdentity');
    await secureStorage.delete(key: 'operatorRecovery');
    for (final key in ['server', 'deviceId', 'bridgeId', 'gateway']) {
      await prefs.remove(key);
    }
    await _authorizationBarrier();
  }
}

class StoredPairingUnavailable implements Exception {
  const StoredPairingUnavailable();
}
