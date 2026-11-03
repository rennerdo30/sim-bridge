import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Version of the sealed-plaintext format. Version 1 carried only the payload,
/// which let a hostile relay replay a captured command or hand it to a
/// different gateway. Version 2 binds every command to a bridge, a target
/// device, an identity, and a moment in time.
const commandProtocolVersion = 2;

/// How long a command stays executable. A gateway that has been offline longer
/// than this rejects the backlog rather than acting on stale intent.
const commandFreshnessWindow = Duration(minutes: 5);

/// Tolerance for clock skew between the requesting phone and the gateway.
const commandClockSkew = Duration(minutes: 2);

const _seenCommandsKey = 'executedCommandIds';
const _notifiedMessagesKey = 'notifiedMessageKeys';
const _maxRememberedCommands = 500;
const _maxRememberedNotifications = 400;
const _idBytes = 16;

final _random = Random.secure();

String newCommandId() {
  final bytes = List<int>.generate(_idBytes, (_) => _random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Builds the plaintext for a command, including everything a gateway needs to
/// decide the command is genuinely for it, right now, and only once.
Map<String, dynamic> buildCommand({
  required String type,
  required String bridgeId,
  required String senderDeviceId,
  required String targetDeviceId,
  required DateTime issuedAt,
  Map<String, dynamic> payload = const {},
}) => {
  'v': commandProtocolVersion,
  'type': type,
  'commandId': newCommandId(),
  'bridgeId': bridgeId,
  'senderDeviceId': senderDeviceId,
  'targetDeviceId': targetDeviceId,
  'issuedAt': issuedAt.toUtc().toIso8601String(),
  ...payload,
};

/// Adds the same binding fields to an event a gateway publishes, so a client
/// can trust the origin instead of relay-supplied metadata.
Map<String, dynamic> bindEvent(
  Map<String, dynamic> event, {
  required String bridgeId,
  required String senderDeviceId,
}) => {
  ...event,
  'v': commandProtocolVersion,
  'bridgeId': bridgeId,
  'senderDeviceId': senderDeviceId,
  'gatewayDeviceId': senderDeviceId,
};

/// Identity of a delivered message, derived only from fields the gateway
/// sealed. Two different messages sharing a timestamp, sender, and body are
/// indistinguishable to a reader anyway.
String messageKey(Map<String, dynamic> event) => [
  if (event['eventId'] is String && (event['eventId'] as String).isNotEmpty)
    'event:${event['eventId']}'
  else ...[
    event['occurredAt'] ?? '',
    event['address'] ?? '',
    (event['body'] ?? '').toString().hashCode,
  ],
].join('|');

/// Tracks which messages have already raised a notification.
///
/// A single high-water timestamp was not enough: a relay could hold one
/// message back until a newer one arrived, moving the watermark past it so the
/// delayed message never alerted. Remembering identities instead means a
/// late-arriving message still notifies.
class NotifiedMessages {
  NotifiedMessages(this._prefs);
  final SharedPreferences _prefs;
  late final List<String> _keys =
      _prefs.getStringList(_notifiedMessagesKey) ?? [];

  static Future<NotifiedMessages> load() async =>
      NotifiedMessages(await SharedPreferences.getInstance());

  /// True before this device has ever recorded a message, in which case the
  /// existing history is adopted silently rather than alerting for all of it.
  bool get isEmpty => _keys.isEmpty;

  bool contains(String key) => _keys.contains(key);

  Future<void> rememberAll(Iterable<String> keys) async {
    var changed = false;
    for (final key in keys) {
      if (_keys.contains(key)) continue;
      _keys.add(key);
      changed = true;
    }
    if (!changed) return;
    if (_keys.length > _maxRememberedNotifications) {
      _keys.removeRange(0, _keys.length - _maxRememberedNotifications);
    }
    await _prefs.setStringList(_notifiedMessagesKey, _keys);
  }

  Future<void> clear() async {
    _keys.clear();
    await _prefs.remove(_notifiedMessagesKey);
  }
}

enum CommandRejection { malformed, wrongBridge, wrongTarget, stale, replayed }

extension CommandRejectionMessage on CommandRejection {
  String get reason => switch (this) {
    CommandRejection.malformed => 'command is not a supported version',
    CommandRejection.wrongBridge => 'command belongs to another bridge',
    CommandRejection.wrongTarget => 'command was addressed to another gateway',
    CommandRejection.stale => 'command is outside the freshness window',
    CommandRejection.replayed => 'command was already executed',
  };
}

/// Remembers which commands this gateway has already carried out, so a replayed
/// envelope cannot make it send the same SMS or drop the same call twice.
class ExecutedCommands {
  ExecutedCommands(this._prefs);
  final SharedPreferences _prefs;
  late final List<String> _ids = _prefs.getStringList(_seenCommandsKey) ?? [];

  static Future<ExecutedCommands> load() async =>
      ExecutedCommands(await SharedPreferences.getInstance());

  bool contains(String commandId) => _ids.contains(commandId);

  Future<void> remember(String commandId) async {
    if (_ids.contains(commandId)) return;
    _ids.add(commandId);
    if (_ids.length > _maxRememberedCommands) {
      _ids.removeRange(0, _ids.length - _maxRememberedCommands);
    }
    await _prefs.setStringList(_seenCommandsKey, _ids);
  }

  Future<void> clear() async {
    _ids.clear();
    await _prefs.remove(_seenCommandsKey);
  }
}

/// Validates a decrypted command against this gateway's identity and clock.
///
/// Decryption alone only proves the command was written by someone holding the
/// bridge key; it says nothing about when, for whom, or how many times.
CommandRejection? rejectCommand(
  Map<String, dynamic> clear, {
  required String bridgeId,
  required String deviceId,
  required ExecutedCommands executed,
  required DateTime now,
}) {
  if (clear['v'] != commandProtocolVersion) return CommandRejection.malformed;
  final commandId = clear['commandId'];
  if (commandId is! String || commandId.isEmpty) {
    return CommandRejection.malformed;
  }
  if (clear['bridgeId'] != bridgeId) return CommandRejection.wrongBridge;
  if (clear['targetDeviceId'] != deviceId) return CommandRejection.wrongTarget;
  final issuedAt = DateTime.tryParse(clear['issuedAt']?.toString() ?? '');
  if (issuedAt == null) return CommandRejection.malformed;
  final age = now.toUtc().difference(issuedAt.toUtc());
  if (age > commandFreshnessWindow || age < -commandClockSkew) {
    return CommandRejection.stale;
  }
  if (executed.contains(commandId)) return CommandRejection.replayed;
  return null;
}
