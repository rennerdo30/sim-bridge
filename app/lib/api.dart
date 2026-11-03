import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'security.dart';
import 'device_authorization.dart';

const relayHealthTimeout = Duration(seconds: 4);

/// Every relay call is bounded. Without this a single stalled socket — routine
/// when a phone changes network — leaves a sync in flight forever, and the
/// guard against overlapping syncs then blocks every later one.
const relayRequestTimeout = Duration(seconds: 10);

class Session {
  const Session({
    required this.server,
    required this.token,
    required this.deviceId,
    required this.bridgeId,
    required this.key,
    this.authorization,
  });
  final String server, token, deviceId, bridgeId;
  final List<int> key;
  final DeviceAuthorization? authorization;
  Session withCredentials(String value, DeviceAuthorization auth) => Session(
    server: server,
    token: value,
    deviceId: deviceId,
    bridgeId: bridgeId,
    key: key,
    authorization: auth,
  );
  BridgeCrypto get crypto => BridgeCrypto(key);
  String get invitation => BridgeInvite(server: server, key: key).encode();
  String get recoveryCode => RecoveryCode.encode(key);
}

class BridgeApi {
  BridgeApi(this.server, [this.relayKey]);
  BridgeApi.forSession(Session session)
    : server = session.server,
      relayKey = null,
      _certificate = session.authorization?.certificate;
  final String server;
  final String? relayKey;
  Uri uri(String path) =>
      Uri.parse('${server.replaceAll(RegExp(r'/$'), '')}$path');
  String? _certificate;
  Map<String, String> headers([String? token]) => {
    'content-type': 'application/json',
    if (relayKey?.isNotEmpty == true) 'x-relay-key': relayKey!,
    if (token != null) 'authorization': 'Bearer $token',
    'x-device-certificate': ?_certificate,
  };

  Map<String, String> _principalHeaders(Object? principal) {
    if (principal is Session) {
      return {
        'content-type': 'application/json',
        'authorization': 'Bearer ${principal.token}',
        'x-device-certificate': ?principal.authorization?.certificate,
      };
    }
    return headers(principal as String?);
  }

  RelayEvents events(
    Session session, {
    http.Client Function()? clientFactory,
    Duration retryBase = const Duration(seconds: 1),
    Duration retryMaximum = const Duration(seconds: 30),
    Duration idleTimeout = const Duration(seconds: 45),
  }) => RelayEvents(
    uri('/v1/events'),
    session.token,
    certificate: session.authorization?.certificate,
    clientFactory: clientFactory,
    retryBase: retryBase,
    retryMaximum: retryMaximum,
    idleTimeout: idleTimeout,
  );

  Future<Map<String, dynamic>> authorizationHealth() async =>
      _decode(await http.get(uri('/health')).timeout(relayHealthTimeout));
  Future<Map<String, dynamic>> upgradeAuthorization(
    Session session,
    DeviceSigningIdentity identity,
  ) => _enrollment(
    '/v1/auth/upgrade',
    {'devicePublicKey': identity.publicKey},
    identity,
    token: session.token,
  );
  Future<Map<String, dynamic>> _enrollment(
    String path,
    Map<String, dynamic> payload,
    DeviceSigningIdentity? identity, {
    String? token,
  }) async {
    if (identity == null) return _post(path, payload, token);
    final operation = path.endsWith('/upgrade')
        ? 'upgrade'
        : path.endsWith('/join')
        ? 'join'
        : 'create';
    final payloadJson = jsonEncode(payload);
    final challenge = await _post('/v1/auth/challenge', {
      'devicePublicKey': identity.publicKey,
      'operation': operation,
      'payloadJson': payloadJson,
    }, token);
    final signature = await DeviceAuthorization(
      identity: identity,
      certificate: identity.publicKey,
    ).challengeSignature(challenge, operation, payloadJson);
    return _post(path, {
      'devicePublicKey': identity.publicKey,
      'challengeId': challenge['challengeId'],
      'signature': signature,
      'payloadJson': payloadJson,
    }, token);
  }

  Future<Map<String, dynamic>> authorizationChallenge(
    DeviceAuthorization auth,
    String operation,
    String payloadJson,
  ) => _post('/v1/auth/challenge', {
    'certificate': auth.certificate,
    'operation': operation,
    'payloadJson': payloadJson,
  });
  Future<Map<String, dynamic>> authorizationProof(
    DeviceAuthorization auth,
    String operation,
    String payloadJson,
  ) async {
    final challenge = await authorizationChallenge(
      auth,
      operation,
      payloadJson,
    );
    final signature = await auth.challengeSignature(
      challenge,
      operation,
      payloadJson,
    );
    final path = operation == 'policy_commit'
        ? '/v1/auth/policy/commit'
        : '/v1/auth/$operation';
    return _post(path, {
      'certificate': auth.certificate,
      'challengeId': challenge['challengeId'],
      'signature': signature,
      'payloadJson': payloadJson,
    });
  }

  Future<Map<String, dynamic>> policyProposal(Session session) =>
      _getObject('/v1/auth/policy', session);
  Future<Map<String, dynamic>> _getObject(
    String path,
    Object principal,
  ) async => _decode(
    await http
        .get(uri(path), headers: _principalHeaders(principal))
        .timeout(relayRequestTimeout),
  );

  Future<int> health() async {
    final watch = Stopwatch()..start();
    final response = await http.get(uri('/health')).timeout(relayHealthTimeout);
    if (response.statusCode != 200) throw Exception('Relay unavailable');
    return watch.elapsedMilliseconds;
  }

  Future<Map<String, dynamic>> create(
    BridgeIdentity identity,
    String name,
    bool gateway, {
    DeviceSigningIdentity? signingIdentity,
    bool authority = false,
  }) => _enrollment('/v1/bridges', {
    'authority': authority,
    'bridgeId': identity.bridgeId,
    'inviteToken': identity.inviteToken,
    'deviceName': name,
    if (signingIdentity != null) 'devicePublicKey': signingIdentity.publicKey,
    'capabilities': {
      'smsGateway': gateway,
      'calls': gateway,
      'callControl': false,
      'multiSim': false,
    },
  }, signingIdentity);
  Future<Map<String, dynamic>> join(
    BridgeIdentity identity,
    String name,
    bool gateway, {
    DeviceSigningIdentity? signingIdentity,
  }) => _enrollment('/v1/bridges/join', {
    'bridgeId': identity.bridgeId,
    'inviteToken': identity.inviteToken,
    'deviceName': name,
    if (signingIdentity != null) 'devicePublicKey': signingIdentity.publicKey,
    'capabilities': {
      'smsGateway': gateway,
      'calls': gateway,
      'callControl': false,
      'multiSim': false,
    },
  }, signingIdentity);

  /// Fetches only what arrived after [since], and reports the relay's own
  /// range so a client can tell a stale cursor from an idle bridge.
  Future<({List<dynamic> records, int oldestSeq, int latestSeq})> messagesSince(
    Session session,
    int since,
  ) async {
    final data = _decode(
      await http
          .get(
            uri('/v1/messages?since=$since'),
            headers: _principalHeaders(session),
          )
          .timeout(relayRequestTimeout),
    );
    return (
      records: data['messages'] as List<dynamic>,
      oldestSeq: (data['oldestSeq'] as num?)?.toInt() ?? 0,
      latestSeq: (data['latestSeq'] as num?)?.toInt() ?? 0,
    );
  }

  /// Devices plus the bridge's enrollment state, in one round trip.
  Future<({List<dynamic> devices, bool joinable, int latencyMs})> roster(
    Session session,
  ) async {
    final watch = Stopwatch()..start();
    final data = _decode(
      await http
          .get(uri('/v1/devices'), headers: _principalHeaders(session))
          .timeout(relayRequestTimeout),
    );
    return (
      devices: data['devices'] as List<dynamic>,
      joinable: data['bridge']?['joinable'] == true,
      latencyMs: watch.elapsedMilliseconds,
    );
  }

  Future<List<dynamic>> devices(Session session) =>
      _get('/v1/devices', session, 'devices');
  Future<List<dynamic>> commands(Session session) =>
      _get('/v1/commands', session, 'commands');
  Future<void> updateCapabilities(
    Session session,
    Map<String, dynamic> capabilities,
  ) => _post('/v1/devices/me', {'capabilities': capabilities}, session);
  Future<void> upload(
    Session session,
    Map<String, dynamic> envelope, {
    Map<String, dynamic>? notification,
    String? uploadId,
  }) => _post('/v1/messages', {
    'envelope': envelope,
    'notification': ?notification,
    'uploadId': ?uploadId,
  }, session);

  Future<void> registerPush(
    Session session,
    String token,
    String environment,
  ) => _post('/v1/devices/me/push', {
    'token': token,
    'environment': environment,
  }, session);
  Future<void> command(
    Session session,
    String gatewayId,
    Map<String, dynamic> envelope,
  ) => _post('/v1/commands', {
    'targetDeviceId': gatewayId,
    'envelope': envelope,
  }, session);
  Future<void> complete(
    Session session,
    String id,
    bool ok, {
    bool receiptRetry = false,
  }) async {
    try {
      await _post('/v1/commands/$id/complete', {'ok': ok}, session);
    } on RelayRequestException catch (error) {
      // The same target's terminal command can be acknowledged again after a
      // lost response. A pruned/revoked receipt can also retire locally.
      if (error.recoveryRequired ||
          !receiptRetry ||
          ![404, 409].contains(error.status)) {
        rethrow;
      }
    }
  }

  /// Drops this device's own enrollment, so leaving does not strand a row.
  Future<void> leave(Session session) =>
      _post('/v1/devices/me/leave', const {}, session);

  /// Removes another phone from the bridge. Owner devices only.
  Future<void> removeDevice(Session session, String deviceId) => _post(
    '/v1/devices/${Uri.encodeComponent(deviceId)}/remove',
    const {},
    session,
  );

  /// Opens or closes the bridge to new devices. Owner devices only.
  Future<bool> setJoinable(Session session, bool joinable) async =>
      (await _post('/v1/bridges/joinable', {
            'joinable': joinable,
          }, session))['joinable']
          as bool;

  Future<Map<String, dynamic>> bridge(Session session) async => _decode(
    await http
        .get(uri('/v1/bridges/me'), headers: _principalHeaders(session))
        .timeout(relayRequestTimeout),
  );

  Future<List<dynamic>> _get(String path, Session token, String field) async =>
      (_decode(
            await http
                .get(uri(path), headers: _principalHeaders(token))
                .timeout(relayRequestTimeout),
          )[field])
          as List<dynamic>;
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> value, [
    Object? token,
  ]) async => _decode(
    await http
        .post(
          uri(path),
          headers: _principalHeaders(token),
          body: jsonEncode(value),
        )
        .timeout(relayRequestTimeout),
  );
  Map<String, dynamic> _decode(http.Response response) {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw RelayRequestException(
        response.statusCode,
        (data['error'] ?? 'Request failed').toString(),
        code: data['code'] as String?,
      );
    }
    return data;
  }
}

class RelayRequestException implements Exception {
  const RelayRequestException(this.status, this.message, {this.code});
  final String? code;
  bool get recoveryRequired =>
      status == 409 &&
      [
        'policy_unavailable',
        'session_expired',
        'pairing_recovery_pending',
        'gateway_unavailable',
        'policy_pending',
      ].contains(code);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// `resumed` is the `ready` of a planned stream rotation: the device stayed
/// online, so only a cheap catch-up is needed instead of a full resync.
enum RelayEvent {
  ready,
  resumed,
  messages,
  commands,
  devices,
  policy,
  heartbeat,
}

/// A device-owned authenticated SSE connection. Invalidations carry no content;
/// a ready frame always prompts catch-up after reconnect. Heartbeats only prove
/// stream liveness. Cancellation aborts both pending headers and the response.
class RelayEvents {
  RelayEvents(
    this._uri,
    this._token, {
    http.Client Function()? clientFactory,
    this.certificate,
    this.retryBase = const Duration(seconds: 1),
    this.retryMaximum = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 45),
  }) : _clientFactory = clientFactory ?? (() => http.Client()) {
    _controller.onListen = () => unawaited(_connect());
    _controller.onCancel = _dispose;
  }

  final Uri _uri;
  final String _token;
  final String? certificate;
  final http.Client Function() _clientFactory;
  final Duration retryBase, retryMaximum, idleTimeout;
  final _controller = StreamController<RelayEvent>();
  Stream<RelayEvent> get stream => _controller.stream;
  http.Client? _client;
  Completer<void>? _abort;
  StreamSubscription<List<int>>? _body;
  Timer? _retry, _idle;
  bool _closed = false;
  int _generation = 0, _failures = 0, _frameBytes = 0;
  bool _rotating = false, _resuming = false;
  final _line = <int>[];
  final _data = <String>[];
  static const _maximumLineBytes = 2048, _maximumFrameBytes = 4096;

  Future<void> _connect() async {
    if (_closed) return;
    final generation = ++_generation;
    final client = _client = _clientFactory();
    final abort = _abort = Completer<void>();
    try {
      final request =
          http.AbortableRequest('GET', _uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'accept': 'text/event-stream',
              'authorization': 'Bearer $_token',
              'x-device-certificate': ?certificate,
              if (_resuming) 'x-simbridge-resume': 'rotation',
            });
      final response = await client.send(request).timeout(relayRequestTimeout);
      if (_closed || generation != _generation) return;
      if (response.statusCode != 200) {
        var length = 0;
        final body = <int>[];
        await for (final chunk in response.stream.timeout(
          relayRequestTimeout,
        )) {
          length += chunk.length;
          if (length > 4096) {
            throw const FormatException('Event error too large');
          }
          body.addAll(chunk);
        }
        String? code;
        try {
          code = (jsonDecode(utf8.decode(body)) as Map)['code'] as String?;
        } catch (_) {}
        throw RelayRequestException(
          response.statusCode,
          'Relay event stream unavailable',
          code: code,
        );
      }
      if (!(response.headers['content-type'] ?? '').startsWith(
        'text/event-stream',
      )) {
        throw const FormatException('Expected relay event stream');
      }
      _line.clear();
      _data.clear();
      _frameBytes = 0;
      _armIdle(generation);
      _body = response.stream.listen(
        (bytes) {
          if (_closed || generation != _generation) return;
          _armIdle(generation);
          try {
            _parse(bytes);
          } catch (error) {
            unawaited(_failed(error, generation));
          }
        },
        onError: (Object error) => unawaited(_failed(error, generation)),
        onDone: () {
          if (_rotating && !_closed && generation == _generation) {
            _rotating = false;
            _resuming = true;
            _idle?.cancel();
            _client?.close();
            _body = null;
            unawaited(_connect());
            return;
          }
          unawaited(
            _failed(
              const FormatException('Relay event stream ended'),
              generation,
            ),
          );
        },
      );
    } catch (error) {
      await _failed(error, generation);
    } finally {
      if (_closed || generation != _generation) client.close();
    }
  }

  void _armIdle(int generation) {
    _idle?.cancel();
    _idle = Timer(
      idleTimeout,
      () => unawaited(
        _failed(TimeoutException('Relay event stream idle'), generation),
      ),
    );
  }

  void _parse(List<int> bytes) {
    for (final byte in bytes) {
      if (byte != 10) {
        if (_line.length >= _maximumLineBytes) {
          throw const FormatException('Relay event line too large');
        }
        _line.add(byte);
        continue;
      }
      if (_line.isNotEmpty && _line.last == 13) _line.removeLast();
      final line = utf8.decode(_line);
      _line.clear();
      if (line.isEmpty) {
        if (_data.isNotEmpty) {
          final value = jsonDecode(_data.join('\n'));
          if (value is! Map) throw const FormatException('Invalid relay event');
          final event = switch (value['type']) {
            'ready' => RelayEvent.ready,
            'messages' => RelayEvent.messages,
            'commands' => RelayEvent.commands,
            'devices' => RelayEvent.devices,
            'policy' => RelayEvent.policy,
            _ => null,
          };
          if (event == RelayEvent.ready) _failures = 0;
          final delivered = event == RelayEvent.ready && _resuming
              ? RelayEvent.resumed
              : event;
          if (event == RelayEvent.ready) _resuming = false;
          // A hosted relay rotates long-lived streams; the end that follows
          // this hint is planned, not a failure.
          if (value['type'] == 'reconnect') _rotating = true;
          if (delivered != null) _controller.add(delivered);
        }
        _data.clear();
        _frameBytes = 0;
      } else if (line.startsWith(':')) {
        _controller.add(RelayEvent.heartbeat);
      } else {
        _frameBytes += utf8.encode(line).length;
        if (_frameBytes > _maximumFrameBytes) {
          throw const FormatException('Relay event frame too large');
        }
        if (line.startsWith('data:')) {
          _data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
        }
      }
    }
  }

  Future<void> _failed(Object error, int generation) async {
    if (_closed || generation != _generation) return;
    ++_generation;
    // After a real failure the next connection is announced normally.
    _resuming = _rotating = false;
    _idle?.cancel();
    if (_abort?.isCompleted == false) _abort!.complete();
    _client?.close();
    final body = _body;
    _body = null;
    await body?.cancel();
    if (_closed) return;
    _controller.addError(error);
    if (error is RelayRequestException &&
        (error.status == 401 || error.recoveryRequired)) {
      await close(); // Terminal enrollment rejection: never auto-enroll again.
      return;
    }
    final milliseconds =
        (retryBase.inMilliseconds * (1 << _failures.clamp(0, 5))).clamp(
          1,
          retryMaximum.inMilliseconds,
        );
    _failures++;
    _retry = Timer(
      Duration(milliseconds: milliseconds),
      () => unawaited(_connect()),
    );
  }

  Future<void> _dispose() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _retry?.cancel();
    _idle?.cancel();
    if (_abort?.isCompleted == false) _abort!.complete();
    _client?.close();
    await _body?.cancel();
    _body = null;
  }

  Future<void> close() async {
    await _dispose();
    await _controller.close();
  }
}
