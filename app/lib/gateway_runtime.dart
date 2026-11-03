import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'api.dart';
import 'authorization_coordinator.dart';
import 'logging.dart';
import 'protocol.dart';
import 'session_store.dart';

/// Native SIM/role fallback probe only. It never fetches relay data while unchanged.
const gatewayNativeProbeInterval = Duration(minutes: 1);
const _maximumPreviewRunes = 600;

/// The foreground service owns this executor. The visible activity only reads
/// messages and runtime status; it never consumes events or executes commands.
class GatewayRuntime {
  GatewayRuntime({
    SessionStore? store,
    Duration nativeProbeInterval = gatewayNativeProbeInterval,
  }) : _store = store ?? SessionStore(),
       _nativeProbeInterval = nativeProbeInterval;
  static const hardware = MethodChannel('app.simbridge/sms');
  static const lifecycle = MethodChannel('app.simbridge/gateway');
  final SessionStore _store;
  final Duration _nativeProbeInterval;
  Timer? _retryTimer, _nativeProbeTimer, _recoveryTimer, _policyTimer;
  bool _recovering = false, _policySyncing = false, _policyAgain = false;
  bool _authorizationBlocked = false, _upgradeChecked = false;
  int _recoveryFailures = 0, _policyFailures = 0, _policyGeneration = 0;
  Completer<void>? _policyDone, _recoveryDone;
  RelayEvents? _events;
  StreamSubscription<RelayEvent>? _eventSubscription;
  Completer<void>? _workDone;
  bool _running = false, _syncing = false, _wakeRequested = false;
  bool _commandsPending = false, _probePending = false;
  bool _relayConnected = false, _unauthorized = false;
  int _failures = 0, _stateRevision = 0, _publishedStateRevision = -1;
  String? _snapshot, _capabilities, _identity;
  String _state = 'starting';
  ExecutedCommands? _executed;

  Future<void> start() async {
    _running = true;
    lifecycle.setMethodCallHandler((call) async {
      if (call.method == 'wake') unawaited(_operatorRecoveryWake());
      if (call.method == 'stop') await stop();
    });
    await lifecycle.invokeMethod('ready');
    _nativeProbeTimer = Timer.periodic(
      _nativeProbeInterval,
      (_) => unawaited(_probeLocalState()),
    );
    await _operatorRecoveryWake();
  }

  Future<void> _closeEvents() async {
    final subscription = _eventSubscription;
    final events = _events;
    _eventSubscription = null;
    _events = null;
    _relayConnected = false;
    await subscription?.cancel();
    await events?.close();
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    _nativeProbeTimer?.cancel();
    _recoveryTimer?.cancel();
    _policyTimer?.cancel();
    await _closeEvents();
    await _workDone?.future;
    await _policyDone?.future;
    await _recoveryDone?.future;
  }

  Future<void> _status(String state, {bool relayOnline = false}) async {
    _state = state;
    await lifecycle.invokeMethod('statusUpdate', {
      'state': state,
      'relayOnline': relayOnline,
      if (relayOnline)
        'lastSuccessAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _openEvents(Session session, BridgeApi api) {
    final events = api.events(session);
    _events = events;
    _eventSubscription = events.stream.listen(
      (event) {
        if (!_running || !identical(_events, events)) return;
        final connected =
            event == RelayEvent.ready || event == RelayEvent.resumed;
        // Policy is rechecked after every reconnect, planned or not, so a
        // proposal hinted during the gap is never missed.
        if (event == RelayEvent.policy ||
            (connected && session.authorization?.authority == true)) {
          _authorizationBlocked = true;
          _policyGeneration++;
          unawaited(_syncPolicy());
        }
        // Only a fresh connection republishes the SIM snapshot; after a planned
        // rotation the relay announced nothing, so no client needs a new one.
        if (event == RelayEvent.ready) _stateRevision++;
        if (connected || event == RelayEvent.heartbeat) {
          _relayConnected = true;
          unawaited(_status(_state, relayOnline: true));
        }
        if (event == RelayEvent.devices) {
          // Enrollment/stream changes republish expiring sealed SIM metadata.
          // The resulting upload emits messages, never another devices hint.
          _stateRevision++;
          unawaited(sync(commands: false));
        }
        // Commands are fetched after every reconnect; a resumed stream skips
        // the local probe and therefore any unchanged snapshot upload.
        if (connected || event == RelayEvent.commands) {
          unawaited(sync(probe: event == RelayEvent.ready));
        }
        // Message/roster hints belong to the visible inbox; never feed back into
        // the sole gateway worker's uploads or command executor.
      },
      onError: (Object error) {
        if (!_running || !identical(_events, events)) return;
        _relayConnected = false;
        _retryTimer?.cancel();
        if (error is RelayRequestException && error.recoveryRequired) {
          _authorizationBlocked = true;
          _policyGeneration++;
          unawaited(_recoverAuthorization());
        } else if (error is RelayRequestException && error.status == 401) {
          _unauthorized = true;
          unawaited(_status('unauthorized'));
          unawaited(_closeEvents());
        } else {
          unawaited(_status('offline'));
        }
      },
    );
  }

  Future<void> _operatorRecoveryWake() async {
    if (!_running || _recovering) return;
    final stored = await _store.load();
    if (stored == null || !_running) return;
    Object? staged;
    try {
      staged = await _store.stagedOperatorRecovery(
        stored.session,
        gateway: true,
      );
    } catch (_) {
      // A damaged staged-recovery record must not turn every native wake
      // into a no-op; ordinary sync still runs and the record stays for review.
      Log.warn('Staged operator recovery could not be read; syncing normally');
      staged = null;
    }
    if (staged == null) {
      await sync();
      return;
    }
    if (!_running) return;
    _recovering = true;
    _recoveryDone = Completer<void>();
    _authorizationBlocked = true;
    _policyGeneration++;
    try {
      await _closeEvents();
      await _workDone?.future;
      await _policyDone?.future;
      if (!_running) return;
      await AuthorizationCoordinator(
        _store,
        gatewayWriter: true,
      ).installStagedOperatorRecovery(stored.session, gateway: true);
      _unauthorized = false;
      _authorizationBlocked = false;
      _upgradeChecked = true;
      _identity = null;
      _stateRevision++;
    } catch (_) {
      await _status('migration_required');
    } finally {
      _recovering = false;
      _recoveryDone!.complete();
      _recoveryDone = null;
    }
    if (!_authorizationBlocked && _running) unawaited(sync());
  }

  Future<void> _recoverAuthorization() async {
    if (!_running || _unauthorized || _recovering) return;
    _recovering = true;
    _recoveryDone = Completer<void>();
    _authorizationBlocked = true;
    _recoveryTimer?.cancel();
    try {
      await _closeEvents();
      await _policyDone?.future;
      if (!_running) return;
      final stored = await _store.load();
      if (stored == null) return;
      var session = stored.session;
      final coordinator = AuthorizationCoordinator(_store, gatewayWriter: true);
      if (session.authorization == null) {
        session = await coordinator.upgradeIfSupported(session);
      }
      await coordinator.recover(session);
      _identity = null;
      _stateRevision++;
      _authorizationBlocked = false;
      _recoveryFailures = 0;
      unawaited(sync());
    } on RelayRequestException catch (failure) {
      if (failure.status == 401) {
        _unauthorized = true;
        await _status(
          failure.code == 'legacy_upgrade_required'
              ? 'migration_required'
              : 'unauthorized',
        );
      } else {
        await _status('waiting_for_gateway');
        _retryRecovery();
      }
    } catch (_) {
      await _status('retrying');
      _retryRecovery();
    } finally {
      _recovering = false;
      _recoveryDone!.complete();
      _recoveryDone = null;
    }
  }

  void _retryRecovery() {
    if (!_running || _unauthorized) return;
    final seconds = (1 << _recoveryFailures.clamp(0, 5)).clamp(1, 30);
    _recoveryFailures++;
    _recoveryTimer = Timer(
      Duration(seconds: seconds),
      () => unawaited(_recoverAuthorization()),
    );
  }

  /// Independent from message/command work: membership mutation may be waiting
  /// for this ACK while the ordinary executor is blocked in another request.
  Future<void> _syncPolicy() async {
    _policyAgain = true;
    if (!_running || _unauthorized || _policySyncing || _recovering) return;
    _policySyncing = true;
    _policyDone = Completer<void>();
    _policyTimer?.cancel();
    try {
      do {
        _policyAgain = false;
        final stored = await _store.load();
        if (stored == null || stored.session.authorization?.authority != true) {
          // Only the gateway authority commits policy; a non-authority must
          // not stay blocked waiting for a commit it will never make.
          _authorizationBlocked = false;
          return;
        }
        await AuthorizationCoordinator(
          _store,
          gatewayWriter: true,
        ).commitPolicy(stored.session);
      } while (_running && !_unauthorized && _policyAgain);
      _authorizationBlocked = false;
      _policyFailures = 0;
      if (_running) unawaited(sync());
    } on RelayRequestException catch (failure) {
      if (failure.recoveryRequired && failure.code != 'policy_pending') {
        unawaited(_recoverAuthorization());
      } else if (failure.status == 401) {
        _unauthorized = true;
        await _status('unauthorized');
      } else {
        _retryPolicy();
      }
    } catch (_) {
      _retryPolicy();
    } finally {
      _policySyncing = false;
      _policyDone!.complete();
      _policyDone = null;
    }
  }

  void _retryPolicy() {
    if (!_running || _unauthorized) return;
    final seconds = (1 << _policyFailures.clamp(0, 5)).clamp(1, 30);
    _policyFailures++;
    _policyTimer = Timer(
      Duration(seconds: seconds),
      () => unawaited(_syncPolicy()),
    );
    unawaited(_status('policy_pending'));
  }

  Future<
    ({List<Map<String, dynamic>> profiles, Map<String, dynamic> capabilities})
  >
  _nativeState() async {
    final role = await hardware.invokeMethod<bool>('hasPhoneRole') ?? false;
    final rows =
        await hardware.invokeListMethod<dynamic>('getSubscriptions') ?? [];
    final profiles = rows
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    return (
      profiles: profiles,
      capabilities: {'callControl': role, 'multiSim': profiles.length > 1},
    );
  }

  Future<void> _probeLocalState() async {
    if (!_running || _syncing || _unauthorized) return;
    try {
      final state = await _nativeState();
      if (!_running) return;
      if (_state == 'permissions' ||
          jsonEncode(state.profiles) != _snapshot ||
          jsonEncode(state.capabilities) != _capabilities) {
        await sync(commands: false);
      }
    } catch (_) {
      if (_running) await _status('permissions', relayOnline: _relayConnected);
    }
  }

  Future<void> sync({bool commands = true, bool probe = true}) async {
    _commandsPending |= commands;
    _probePending |= probe;
    _wakeRequested = true;
    if (!_running || _syncing || _unauthorized || _authorizationBlocked) return;
    _syncing = true;
    _workDone = Completer<void>();
    _retryTimer?.cancel();
    var successful = false, retryFailed = false;
    try {
      do {
        successful = false;
        _wakeRequested = false;
        final readCommands = _commandsPending, readNative = _probePending;
        _commandsPending = _probePending = false;
        final stored = await _store.load();
        if (stored == null || !stored.gateway) {
          await _closeEvents();
          await _status('unpaired');
          return;
        }
        var session = stored.session;
        if (!_upgradeChecked) {
          session = await AuthorizationCoordinator(
            _store,
            gatewayWriter: true,
          ).upgradeIfSupported(session);
          _upgradeChecked = true;
        }
        final identity =
            '${session.server}\n${session.deviceId}\n${session.token}';
        if (_identity != identity) {
          await _closeEvents();
          _identity = identity;
          _snapshot = _capabilities = null;
          _publishedStateRevision = -1;
          _executed = null;
          _openEvents(session, BridgeApi.forSession(session));
        }
        final api = BridgeApi.forSession(session);
        if (_authorizationBlocked) return;
        await _flushReceipts(session, api);
        if (!_running || _unauthorized || _authorizationBlocked) return;
        await _flushEvents(session, api);
        if (!_running || _unauthorized || _authorizationBlocked) return;
        if (readNative) {
          final state = await _nativeState();
          final snapshot = jsonEncode(state.profiles);
          final revision = _stateRevision;
          if (_snapshot != snapshot || _publishedStateRevision != revision) {
            await api.upload(
              session,
              await session.crypto.seal(
                bindEvent(
                  {
                    'kind': 'gateway_state',
                    'simProfiles': state.profiles,
                    'occurredAt': DateTime.now().toUtc().toIso8601String(),
                  },
                  bridgeId: session.bridgeId,
                  senderDeviceId: session.deviceId,
                ),
              ),
            );
            _snapshot = snapshot;
            _publishedStateRevision = revision;
          }
          if (!_running || _unauthorized || _authorizationBlocked) return;
          final capabilities = jsonEncode(state.capabilities);
          if (_capabilities != capabilities) {
            await api.updateCapabilities(session, state.capabilities);
            _capabilities = capabilities;
          }
        }
        if (!_running || _unauthorized || _authorizationBlocked) return;
        if (readCommands) {
          final executed = _executed ??= await ExecutedCommands.load();
          for (final row in await api.commands(session)) {
            if (!_running || _unauthorized || _authorizationBlocked) break;
            await _command(
              session,
              api,
              Map<String, dynamic>.from(row as Map),
              executed,
            );
          }
        }
        await _flushEvents(session, api);
        await _flushReceipts(session, api);
        if (!_running || _unauthorized || _authorizationBlocked) return;
        await _status('running', relayOnline: _relayConnected);
        successful = true;
      } while (_running && !_unauthorized && _wakeRequested);
    } on RelayRequestException catch (error) {
      if (error.recoveryRequired) {
        _authorizationBlocked = true;
        _policyGeneration++;
        unawaited(_recoverAuthorization());
      } else if (error.status == 401) {
        _unauthorized = true;
        await _closeEvents();
        await _status(
          error.code == 'legacy_upgrade_required'
              ? 'migration_required'
              : 'unauthorized',
        );
      } else {
        retryFailed = true;
        await _status('retrying', relayOnline: _relayConnected);
      }
      Log.warn('Gateway relay request failed with HTTP ${error.status}');
    } on PlatformException catch (error) {
      retryFailed = true;
      _commandsPending = _probePending = true;
      await _status(
        error.code == 'permission_denied' ? 'permissions' : 'retrying',
        relayOnline: _relayConnected,
      );
      Log.warn('Gateway native operation unavailable (${error.code})');
    } catch (_) {
      retryFailed = true;
      await _status('retrying', relayOnline: _relayConnected);
      Log.warn('Gateway sync postponed; durable events and receipts retained');
    } finally {
      _syncing = false;
      _workDone!.complete();
      _workDone = null;
      if (successful) _failures = 0;
      if (_running && !_unauthorized && !_authorizationBlocked && retryFailed) {
        // Only failed work retries. A successful, idle connection sends no GETs.
        final seconds = (1 << _failures.clamp(0, 5)).clamp(1, 30);
        _failures++;
        _retryTimer = Timer(
          Duration(seconds: seconds),
          () => unawaited(sync()),
        );
      } else if (_running &&
          !_unauthorized &&
          !_authorizationBlocked &&
          _wakeRequested) {
        unawaited(
          Future<void>.microtask(() => sync(commands: false, probe: false)),
        );
      }
    }
  }

  Future<void> _flushEvents(Session session, BridgeApi api) async {
    final events =
        await hardware.invokeListMethod<dynamic>('peekPending', {
          'limit': 50,
        }) ??
        [];
    for (final value in events) {
      if (!_running || _unauthorized || _authorizationBlocked) return;
      final event = Map<String, dynamic>.from(value as Map);
      final id = event['eventId'];
      if (id is! String || id.isEmpty) {
        // Native records always carry an ID; a malformed one cannot be
        // acknowledged, so skip it instead of stalling every later event.
        Log.warn('Skipped a queued gateway event without a stable identifier');
        continue;
      }
      event['kind'] ??= 'sms';
      event['direction'] ??= 'incoming';
      try {
        await _uploadEvent(session, api, event, id);
      } on RelayRequestException catch (error) {
        if (!_permanentRejection(error)) rethrow;
        // An oversized message would otherwise block the queue forever.
        // Retry once with a shortened body that says it was truncated.
        final body = event['body']?.toString() ?? '';
        if (body.runes.length <= _truncatedBodyRunes) rethrow;
        Log.warn(
          'Relay refused an oversized gateway event; sending it shortened',
        );
        await _uploadEvent(session, api, {
          ...event,
          'body': String.fromCharCodes(body.runes.take(_truncatedBodyRunes)),
          'truncated': true,
        }, id);
      }
      if (!_running || _unauthorized || _authorizationBlocked) return;
      // A lost HTTP response leaves the same event queued. The relay uses the
      // stable upload id to return the original message without a second push.
      await hardware.invokeMethod('acknowledgePending', {
        'eventIds': [id],
      });
    }
    // Continue accepted backlog work until drained, without an idle network timer.
    if (events.length == 50) _wakeRequested = true;
  }

  static const _truncatedBodyRunes = 4000;

  static bool _permanentRejection(RelayRequestException error) =>
      error.status == 400 || error.status == 413;

  Future<void> _uploadEvent(
    Session session,
    BridgeApi api,
    Map<String, dynamic> event,
    String id,
  ) async {
    final notification =
        event['kind'] == 'sms' && event['direction'] == 'incoming'
        ? await sealedPushPreview(session, event)
        : null;
    await api.upload(
      session,
      await session.crypto.seal(
        bindEvent(
          event,
          bridgeId: session.bridgeId,
          senderDeviceId: session.deviceId,
        ),
      ),
      uploadId: id,
      notification: notification,
    );
  }

  Future<void> _flushReceipts(Session session, BridgeApi api) async {
    final receipts =
        await hardware.invokeListMethod<dynamic>('pendingReceipts') ?? [];
    for (final value in receipts) {
      if (!_running || _unauthorized || _authorizationBlocked) return;
      final receipt = Map<String, dynamic>.from(value as Map);
      if (receipt['bridgeId'] != session.bridgeId) continue;
      await api.complete(
        session,
        receipt['relayId'] as String,
        receipt['ok'] == true,
        receiptRetry: true,
      );
      if (!_running || _unauthorized || _authorizationBlocked) return;
      await hardware.invokeMethod('ackReceipt', {
        'commandId': receipt['commandId'],
      });
    }
  }

  Future<void> _command(
    Session session,
    BridgeApi api,
    Map<String, dynamic> row,
    ExecutedCommands executed,
  ) async {
    final policyGeneration = _policyGeneration;
    Map<String, dynamic> clear;
    try {
      clear = await session.crypto.open(
        Map<String, dynamic>.from(row['envelope'] as Map),
      );
    } catch (_) {
      await api.complete(
        session,
        row['id'] as String,
        false,
        receiptRetry: true,
      );
      return;
    }
    final rejection = rejectCommand(
      clear,
      bridgeId: session.bridgeId,
      deviceId: session.deviceId,
      executed: executed,
      now: DateTime.now(),
    );
    if (rejection != null || clear['senderDeviceId'] != row['requestedBy']) {
      await api.complete(
        session,
        row['id'] as String,
        false,
        receiptRetry: true,
      );
      return;
    }
    final commandId = clear['commandId'] as String;
    final type = clear['type'];
    final event = <String, dynamic>{
      'eventId': 'command:$commandId',
      'commandId': commandId,
      'kind': type == 'send_sms' ? 'sms' : 'call',
      if (type == 'send_sms') 'direction': 'outgoing',
      'address': clear['address'],
      if (type == 'send_sms') 'body': clear['body'],
      'subscriptionId': clear['subscriptionId'],
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    };
    final claimed =
        await hardware.invokeMethod<bool>('claimCommand', {
          'commandId': commandId,
          'relayId': row['id'],
          'bridgeId': session.bridgeId,
          if (type == 'send_sms' || type == 'place_call') 'event': event,
        }) ??
        false;
    if (!claimed) {
      return; // Existing claim/result is retried by the receipt path.
    }
    // Keep the legacy replay fence as well; a crash after claim remains fenced
    // by SQLite even if this preference write did not finish.
    await executed.remember(commandId);
    var ok = false;
    var outcome = 'failed';
    try {
      if (!_running ||
          _unauthorized ||
          _authorizationBlocked ||
          policyGeneration != _policyGeneration) {
        outcome = 'unknown';
      } else if (type == 'send_sms') {
        await hardware.invokeMethod('sendSms', clear);
        ok = true;
      } else if (type == 'place_call') {
        await hardware.invokeMethod('placeCall', clear);
        ok = true;
      } else if (type == 'control_call') {
        await hardware.invokeMethod('controlCall', clear);
        ok = true;
      }
    } on PlatformException catch (error) {
      // A timeout or a partly delivered multipart SMS is not proof the carrier
      // rejected the send, so the sender must not simply resend it.
      outcome = const {'send_timeout', 'send_partial'}.contains(error.code)
          ? 'unknown'
          : 'failed';
    } catch (_) {
      outcome = 'unknown';
    }
    if (ok) outcome = 'complete';
    event['status'] = ok ? (type == 'send_sms' ? 'sent' : 'dialing') : outcome;
    await hardware.invokeMethod('finishCommand', {
      'commandId': commandId,
      'ok': ok,
      'status': outcome,
      if (type == 'send_sms' || type == 'place_call') 'event': event,
    });
  }
}

Future<Map<String, dynamic>?> sealedPushPreview(
  Session session,
  Map<String, dynamic> event,
) async {
  final body = event['body']?.toString() ?? '';
  final otp = verificationCodeFrom(body);
  final envelope = await session.crypto.seal({
    'v': commandProtocolVersion,
    'kind': 'sms',
    'direction': 'incoming',
    'bridgeId': session.bridgeId,
    'senderDeviceId': session.deviceId,
    'eventId': event['eventId'],
    'address': String.fromCharCodes(
      (event['address'] ?? '').toString().runes.take(80),
    ),
    'body': String.fromCharCodes(body.runes.take(_maximumPreviewRunes)),
    'otp': otp,
  });
  final payload = {
    'aps': {
      'alert': {
        'title': 'New Sim Bridge message',
        'body': 'Open Sim Bridge to view',
      },
      'mutable-content': 1,
      'sound': 'default',
    },
    'encrypted': envelope,
    'messageId': '00000000-0000-0000-0000-000000000000',
  };
  return utf8.encode(jsonEncode(payload)).length <= 4096 ? envelope : null;
}

String? verificationCodeFrom(String? body) {
  if (body == null) return null;
  final explicit = RegExp(
    r'(?:code|pin|otp|passcode|verification)[^0-9]{0,20}([0-9]{4,8})',
    caseSensitive: false,
  ).firstMatch(body);
  if (explicit != null) return explicit.group(1);
  return RegExp(r'(?<![0-9])([0-9]{4,8})(?![0-9])').firstMatch(body)?.group(1);
}
