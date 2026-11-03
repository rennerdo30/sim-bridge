import 'dart:convert';

import 'api.dart';
import 'device_authorization.dart';
import 'session_store.dart';

/// The headless Android gateway is the sole writer of its policy ledger.
/// Visible gateways reload this record; members never bootstrap a bridge.
class AuthorizationCoordinator {
  AuthorizationCoordinator(this.store, {this.gatewayWriter = false});
  final SessionStore store;
  final bool gatewayWriter;

  Future<Session> upgradeIfSupported(Session session) async {
    if (session.authorization != null) return session;
    // The headless gateway prepares its exportable identity while the old
    // relay is still running; only an authenticated upgrade issues a ticket.
    final preparedIdentity = gatewayWriter
        ? await store.prepareUpgradeIdentity(session)
        : null;
    final api = BridgeApi.forSession(session);
    final health = await api.authorizationHealth();
    if (health['authorizationVersion'] != 2) return session;
    final identity =
        preparedIdentity ?? await store.prepareUpgradeIdentity(session);
    final result = await api.upgradeAuthorization(session, identity);
    final certificate = result['certificate'];
    if (certificate is! String) {
      throw const FormatException('Missing membership certificate');
    }
    final auth = DeviceAuthorization(
      identity: identity,
      certificate: certificate,
      policyJson: result['policyJson'] as String?,
      bootId: result['bootId'] as String?,
    );
    auth.validateFor(session.bridgeId, session.deviceId);
    if (auth.authority && !gatewayWriter) {
      throw const StoredPairingUnavailable();
    }
    final updated = session.withCredentials(
      result['token'] as String? ?? session.token,
      auth,
    );
    await store.persistAuthorization(updated);
    await store.finishUpgradeIdentity();
    return updated;
  }

  Future<Session> recover(Session session, {bool adoptStored = true}) async {
    final originalToken = session.token;
    final latest = await store.load();
    if (adoptStored &&
        latest != null &&
        latest.session.bridgeId == session.bridgeId &&
        latest.session.deviceId == session.deviceId &&
        latest.session.authorization != null) {
      session = latest.session;
    }
    final auth = session.authorization;
    if (auth == null) {
      throw const RelayRequestException(
        401,
        'Legacy authorization needs operator recovery',
        code: 'legacy_upgrade_required',
      );
    }
    auth.validateFor(session.bridgeId, session.deviceId);
    if (auth.authority &&
        !gatewayWriter &&
        auth.policyJson != null &&
        validatePolicy(session, auth.policyJson!)['erased'] == true) {
      throw const RelayRequestException(
        401,
        'Durably inactive authority',
        code: 'device_revoked',
      );
    }
    final api = BridgeApi.forSession(session);
    Map<String, dynamic> result;
    if (auth.authority && gatewayWriter) {
      final policy = auth.policyJson;
      if (policy == null) throw const StoredPairingUnavailable();
      validatePolicy(session, policy);
      result = await api.authorizationProof(auth, 'bootstrap', policy);
    } else {
      if (auth.authority && !gatewayWriter) {
        // Only the headless writer may renew the authority record. Visible UI
        // can adopt its result without racing a newer durable policy write.
        if (latest != null && latest.session.token != originalToken) {
          return latest.session;
        }
        throw const RelayRequestException(
          409,
          'Waiting for gateway recovery',
          code: 'gateway_unavailable',
        );
      }
      result = await api.authorizationProof(auth, 'resume', '');
    }
    if (result['erased'] == true) {
      throw const RelayRequestException(
        401,
        'Bridge authority is durably inactive',
        code: 'device_revoked',
      );
    }
    if ((result['deviceId'] != null &&
            result['deviceId'] != session.deviceId) ||
        (result['bridgeId'] != null &&
            result['bridgeId'] != session.bridgeId) ||
        result['token'] is! String) {
      throw const FormatException('Recovery changed enrollment identity');
    }
    final responseId = result['deviceId'] ?? result['device']?['id'];
    final responseBridge = result['bridgeId'] ?? result['bridge']?['id'];
    if (responseId != session.deviceId ||
        responseBridge != session.bridgeId ||
        (result['certificate'] != null &&
            result['certificate'] != auth.certificate)) {
      throw const FormatException('Recovery changed identity');
    }
    final updated = session.withCredentials(
      result['token'] as String,
      auth.withBoot(result['bootId'] as String?),
    );
    await store.persistAuthorization(updated);
    return updated;
  }

  Future<Session?> installStagedOperatorRecovery(
    Session session, {
    required bool gateway,
  }) async {
    final auth = await store.stagedOperatorRecovery(session, gateway: gateway);
    if (auth == null) return null;
    if (auth.authority && !gatewayWriter) {
      throw const StoredPairingUnavailable();
    }
    auth.assertPolicyNotOlder(session.authorization);
    final candidate = session.withCredentials(session.token, auth);
    if (auth.authority) validatePolicy(candidate, auth.policyJson!);
    final updated = await recover(candidate, adoptStored: false);
    await store.finishOperatorRecovery();
    return updated;
  }

  Future<Session> commitPolicy(Session session) async {
    final auth = session.authorization;
    if (!gatewayWriter || auth == null || !auth.authority) return session;
    final api = BridgeApi.forSession(session);
    final proposal = await api.policyProposal(session);
    if (proposal['proposalId'] == null) return session;
    final policy = proposal['policyJson'];
    if (policy is! String ||
        proposal['proposalId'] is! String ||
        proposal['baseRevision'] is! int ||
        proposal['revision'] is! int) {
      throw const FormatException('Invalid policy proposal');
    }
    final decoded = validatePolicy(session, policy);
    final revision = decoded['revision'] as int;
    final prior = auth.policyJson == null
        ? 0
        : (validatePolicy(session, auth.policyJson!)['revision'] as int);
    if (revision != proposal['revision'] ||
        proposal['baseRevision'] != revision - 1 ||
        revision < prior ||
        (revision == prior && auth.policyJson != policy) ||
        revision > prior + 1) {
      throw const FormatException('Policy rollback or skipped revision');
    }
    final updated = session.withCredentials(
      session.token,
      auth.withPolicy(policy),
    );
    // A lost ACK leaves the durable new record intact and relay frozen.
    await store.persistAuthorization(updated);
    await api.authorizationProof(
      updated.authorization!,
      'policy_commit',
      jsonEncode({'proposalId': proposal['proposalId'], 'policyJson': policy}),
    );
    return updated;
  }

  static Map<String, dynamic> validatePolicy(
    Session session,
    String policyJson,
  ) {
    if (utf8.encode(policyJson).length > 65536) {
      throw const FormatException('Policy too large');
    }
    final policy = jsonDecode(policyJson);
    final auth = session.authorization;
    if (policy is! Map<String, dynamic> ||
        auth == null ||
        !auth.authority ||
        policy['v'] != 1 ||
        policy['bridgeId'] != session.bridgeId ||
        policy['authorityDeviceId'] != session.deviceId ||
        policy['issuer'] != auth.claims['issuer'] ||
        policy['incarnation'] != auth.claims['incarnation'] ||
        policy['revision'] is! int ||
        policy['revision'] < 1 ||
        policy['joinable'] is! bool ||
        policy['erased'] is! bool ||
        policy['members'] is! List ||
        (policy['members'] as List).length > 16) {
      throw const FormatException('Policy authority mismatch');
    }
    var authorities = 0;
    final ids = <String>{};
    for (final member in policy['members'] as List) {
      if (member is! Map || member['certificate'] is! String) {
        throw const FormatException('Invalid policy member');
      }
      final parts = (member['certificate'] as String).split('.');
      if (parts.length != 2) {
        throw const FormatException('Invalid policy certificate');
      }
      final claims =
          jsonDecode(utf8.decode(decodeAuthorizationBytes(parts.first))) as Map;
      if (claims['v'] != 1 ||
          claims['bridgeId'] != session.bridgeId ||
          claims['issuer'] != policy['issuer'] ||
          claims['incarnation'] != policy['incarnation'] ||
          claims['deviceId'] is! String ||
          claims['publicKey'] is! String ||
          claims['smsGateway'] is! bool ||
          claims['isOwner'] is! bool ||
          claims['authority'] is! bool ||
          !ids.add(claims['deviceId'] as String)) {
        throw const FormatException('Invalid policy enrollment');
      }
      if (claims['authority'] == true) {
        authorities++;
        if (member['certificate'] != auth.certificate ||
            claims['smsGateway'] != true ||
            claims['isOwner'] != true) {
          throw const FormatException('Foreign policy authority');
        }
      }
    }
    if ((policy['erased'] == false && authorities != 1) ||
        (policy['erased'] == true && (policy['members'] as List).isNotEmpty)) {
      throw const FormatException('Missing policy authority');
    }
    return policy;
  }
}
