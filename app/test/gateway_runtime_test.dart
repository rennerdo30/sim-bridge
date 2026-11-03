import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/relay_http_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/gateway_runtime.dart';
import 'package:sim_bridge/protocol.dart';
import 'package:sim_bridge/session_store.dart';

class TestStore extends SessionStore {
  TestStore(this.session);
  final Session session;
  @override
  Future<StoredSession?> load() async => StoredSession(session, gateway: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'failed upload keeps durable event; retry uses same ID and acknowledges only success',
    () async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = null;
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final session = Session(
        server: 'http://127.0.0.1:${relay.port}',
        token: 'test',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      var failUpload = true;
      final uploadIds = <String>[];
      final acknowledgements = <String>[];
      final event = {
        'eventId': 'stable-event',
        'kind': 'sms',
        'direction': 'incoming',
        'body': 'Code 654321',
        'occurredAt': DateTime.now().toUtc().toIso8601String(),
      };
      relay.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final data = body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        dynamic response = {};
        if (request.uri.path == '/v1/devices') {
          response = {
            'devices': [],
            'bridge': {'joinable': true},
          };
        }
        if (request.uri.path == '/v1/commands') response = {'commands': []};
        if (request.uri.path == '/v1/messages' && data['uploadId'] != null) {
          uploadIds.add(data['uploadId'] as String);
          if (failUpload) {
            request.response.statusCode = 500;
            response = {'error': 'temporary'};
          }
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(
        GatewayRuntime.hardware,
        (call) async => switch (call.method) {
          'peekPending' => acknowledgements.isEmpty ? [event] : [],
          'acknowledgePending' => acknowledgements.addAll(
            List<String>.from((call.arguments as Map)['eventIds']),
          ),
          'pendingReceipts' => [],
          'getSubscriptions' => [],
          'hasPhoneRole' => false,
          _ => null,
        },
      );
      final runtime = GatewayRuntime(store: TestStore(session));
      try {
        await runtime.start();
        expect(acknowledgements, isEmpty);
        failUpload = false;
        await runtime.sync();
        expect(uploadIds, ['stable-event', 'stable-event']);
        expect(acknowledgements, ['stable-event']);
      } finally {
        await runtime.stop();
        await relay.close(force: true);
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );

  test(
    'recovered claimed command never resends hardware and stop awaits in-flight upload',
    () async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = null;
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final session = Session(
        server: 'http://127.0.0.1:${relay.port}',
        token: 'test',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      final command = buildCommand(
        type: 'send_sms',
        bridgeId: 'bridge',
        senderDeviceId: 'client',
        targetDeviceId: 'gateway',
        issuedAt: DateTime.now(),
        payload: {'address': '123456', 'body': 'test'},
      );
      final envelope = await session.crypto.seal(command);
      var sends = 0, claims = 0;
      final uploadStarted = Completer<void>(),
          releaseUpload = Completer<void>();
      relay.listen((request) async {
        await request.drain<void>();
        dynamic response = {};
        if (request.uri.path == '/v1/devices') {
          response = {
            'devices': [],
            'bridge': {'joinable': true},
          };
        }
        if (request.uri.path == '/v1/commands') {
          response = {
            'commands': [
              {
                'id': 'relay-command',
                'requestedBy': 'client',
                'envelope': envelope,
              },
            ],
          };
        }
        if (request.uri.path == '/v1/messages') {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          await releaseUpload.future;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'peekPending':
            return [];
          case 'pendingReceipts':
            return [];
          case 'getSubscriptions':
            return [];
          case 'hasPhoneRole':
            return false;
          case 'claimCommand':
            claims++;
            return false; // Persisted claim from prior process.
          case 'sendSms':
            sends++;
            return true;
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(store: TestStore(session));
      try {
        final starting = runtime.start();
        await uploadStarted.future;
        var stopped = false;
        final stopping = runtime.stop().then((_) {
          stopped = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(stopped, false);
        releaseUpload.complete();
        await starting;
        await stopping;
        expect(sends, 0);
        // Start a fresh runtime after the controlled stop to reach command polling.
        final recovered = GatewayRuntime(store: TestStore(session));
        await recovered.start();
        await recovered.stop();
        expect(claims, 1);
        expect(sends, 0);
      } finally {
        if (!releaseUpload.isCompleted) releaseUpload.complete();
        await runtime.stop();
        await relay.close(force: true);
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
  test(
    'healthy gateway stays network-idle across local probes; commands and device hints coalesce',
    () async {
      SharedPreferences.setMockInitialValues({});
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      final command = buildCommand(
        type: 'send_sms',
        bridgeId: 'bridge',
        senderDeviceId: 'client',
        targetDeviceId: 'gateway',
        issuedAt: DateTime.now(),
        payload: {'address': '123456', 'body': 'synthetic'},
      );
      final envelope = await session.crypto.seal(command);
      var commandReads = 0,
          rosterReads = 0,
          uploads = 0,
          localReads = 0,
          sends = 0;
      var queued = false;
      Completer<void>? release;
      final started = Completer<void>();
      final receipts = <Map<String, dynamic>>[];
      final clients = <RelayFixtureClient>[];
      final hardwareOrder = <String>[];
      final statuses = <Map<dynamic, dynamic>>[];
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/devices' && request.method == 'GET') {
          rosterReads++;
        }
        if (request.url.path == '/v1/messages') uploads++;
        if (request.url.path.endsWith('/complete')) queued = false;
        if (request.url.path == '/v1/commands') {
          commandReads++;
          if (release != null) {
            if (!started.isCompleted) started.complete();
            await release!.future;
          }
          return http.Response(
            jsonEncode({
              'commands': queued
                  ? [
                      {
                        'id': 'relay-command',
                        'requestedBy': 'client',
                        'envelope': envelope,
                      },
                    ]
                  : [],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, (
        call,
      ) async {
        if (call.method == 'statusUpdate') statuses.add(call.arguments as Map);
        return true;
      });
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'hasPhoneRole':
            localReads++;
            return false;
          case 'getSubscriptions':
            return [];
          case 'peekPending':
            return [];
          case 'pendingReceipts':
            return List.of(receipts);
          case 'claimCommand':
            hardwareOrder.add('claim');
            return true;
          case 'sendSms':
            hardwareOrder.add('send');
            sends++;
            return true;
          case 'finishCommand':
            hardwareOrder.add('finish');
            receipts.add({
              'bridgeId': 'bridge',
              'relayId': 'relay-command',
              'commandId': command['commandId'],
              'ok': true,
            });
            return null;
          case 'ackReceipt':
            receipts.clear();
            return null;
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(
        store: TestStore(session),
        nativeProbeInterval: const Duration(seconds: 1),
      );
      try {
        await http.runWithClient(
          () async {
            await runtime.start();
            for (var i = 0; i < 12; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            final active = clients.singleWhere(
              (client) => client.activeConnections == 1,
            );
            final beforeCommands = commandReads,
                beforeUploads = uploads,
                beforeNative = localReads;
            for (var i = 0; i < 6; i++) {
              active.emit(RelayEvent.heartbeat);
              await Future<void>.delayed(const Duration(seconds: 1));
            }
            expect(commandReads, beforeCommands);
            expect(rosterReads, 0);
            expect(uploads, beforeUploads);
            expect(localReads, greaterThan(beforeNative));
            expect(statuses.last['relayOnline'], true);
            queued = true;
            release = Completer<void>();
            active.emit(RelayEvent.commands);
            for (var i = 0; i < 12; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(started.isCompleted, true);
            for (var i = 0; i < 8; i++) {
              active.emit(RelayEvent.commands);
              active.emit(RelayEvent.devices);
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
            release!.complete();
            release = null;
            await Future<void>.delayed(const Duration(milliseconds: 30));
            for (var i = 0; i < 20; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(commandReads, beforeCommands + 2);
            expect(
              uploads,
              beforeUploads + 1,
            ); // Fresh sealed SIM state for newly joined clients.
            expect(sends, 1);
            expect(hardwareOrder, ['claim', 'send', 'finish']);
            expect(receipts, isEmpty);
            await runtime.stop();
            expect(
              clients.every((client) => client.activeConnections == 0),
              true,
            );
          },
          () {
            final client = RelayFixtureClient(rest);
            clients.add(client);
            return client;
          },
        );
      } finally {
        if (release != null && !release!.isCompleted) release!.complete();
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
  test(
    'a planned stream rotation resumes with commands only, no snapshot upload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      var commandReads = 0, uploads = 0, rosterReads = 0;
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/messages') uploads++;
        if (request.url.path == '/v1/devices' && request.method == 'GET') {
          rosterReads++;
        }
        if (request.url.path == '/v1/commands') {
          commandReads++;
          return http.Response(jsonEncode({'commands': []}), 200);
        }
        return http.Response('{}', 200);
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (call) async => true,
      );
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'getSubscriptions':
          case 'peekPending':
          case 'pendingReceipts':
            return [];
          case 'hasPhoneRole':
            return false;
          default:
            return null;
        }
      });
      final clients = <RelayFixtureClient>[];
      final runtime = GatewayRuntime(
        store: TestStore(session),
        nativeProbeInterval: const Duration(hours: 1),
      );
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      try {
        await http.runWithClient(
          () async {
            await runtime.start();
            await settle();
            final beforeCommands = commandReads, beforeUploads = uploads;
            clients.singleWhere((c) => c.activeConnections == 1).rotate();
            await settle();
            final resumed = clients.singleWhere(
              (c) => c.activeConnections == 1,
            );
            expect(resumed.resumeHeaders, ['rotation']);
            expect(commandReads, beforeCommands + 1, reason: 'gap catch-up');
            expect(uploads, beforeUploads, reason: 'snapshot is unchanged');
            expect(rosterReads, 0);
          },
          () {
            final client = RelayFixtureClient(rest);
            clients.add(client);
            return client;
          },
        );
      } finally {
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
  test(
    'revocation during a durable command claim prevents physical effects',
    () async {
      SharedPreferences.setMockInitialValues({});
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      final command = buildCommand(
        type: 'send_sms',
        bridgeId: 'bridge',
        senderDeviceId: 'client',
        targetDeviceId: 'gateway',
        issuedAt: DateTime.now(),
        payload: {'address': '123456', 'body': 'synthetic'},
      );
      final envelope = await session.crypto.seal(command);
      final claiming = Completer<void>(),
          release = Completer<bool>(),
          rejected = Completer<void>();
      final clients = <RelayFixtureClient>[];
      var rejectEvents = false, sent = 0;
      String? outcome;
      final rest = MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/v1/commands'
                ? {
                    'commands': [
                      {
                        'id': 'relay-command',
                        'requestedBy': 'client',
                        'envelope': envelope,
                      },
                    ],
                  }
                : {},
          ),
          200,
        ),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, (
        call,
      ) async {
        if (call.method == 'statusUpdate' &&
            (call.arguments as Map)['state'] == 'unauthorized' &&
            !rejected.isCompleted) {
          rejected.complete();
        }
        return true;
      });
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'hasPhoneRole':
            return false;
          case 'getSubscriptions':
          case 'peekPending':
          case 'pendingReceipts':
            return [];
          case 'claimCommand':
            if (!claiming.isCompleted) claiming.complete();
            return release.future;
          case 'sendSms':
          case 'placeCall':
          case 'controlCall':
            sent++;
            return true;
          case 'finishCommand':
            outcome = (call.arguments as Map)['status'] as String;
            return null;
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(store: TestStore(session));
      try {
        await http.runWithClient(
          () async {
            final starting = runtime.start();
            await claiming.future.timeout(const Duration(seconds: 3));
            rejectEvents = true;
            clients
                .singleWhere((client) => client.activeConnections == 1)
                .end();
            await rejected.future.timeout(const Duration(seconds: 3));
            release.complete(true);
            await starting;
            expect(sent, 0);
            expect(outcome, 'unknown');
            await runtime.stop();
          },
          () {
            final client = RelayFixtureClient(
              rest,
              eventStatus: rejectEvents ? 401 : 200,
            );
            clients.add(client);
            return client;
          },
        );
      } finally {
        if (!release.isCompleted) release.complete(false);
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );

  test(
    'reconnect work drains more than 100 durable events without another wake',
    () async {
      SharedPreferences.setMockInitialValues({});
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      final pending = List.generate(
        137,
        (i) => {'eventId': 'queued-$i', 'kind': 'call', 'address': 'synthetic'},
      );
      final accepted = <String>[];
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/messages') {
          final id = (jsonDecode(request.body) as Map)['uploadId'];
          if (id is String) accepted.add(id);
        }
        return http.Response(
          request.url.path == '/v1/commands' ? '{"commands":[]}' : '{}',
          200,
        );
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        GatewayRuntime.lifecycle,
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'hasPhoneRole':
            return false;
          case 'getSubscriptions':
          case 'pendingReceipts':
            return [];
          case 'peekPending':
            return pending.take(50).toList();
          case 'acknowledgePending':
            final ids = (call.arguments as Map)['eventIds'] as List;
            pending.removeWhere((row) => ids.contains(row['eventId']));
            return null;
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(store: TestStore(session));
      try {
        await http.runWithClient(() async {
          await runtime.start();
          expect(pending, isEmpty);
          expect(accepted.length, 137);
          expect(accepted.toSet().length, 137);
          await runtime.stop();
        }, () => RelayFixtureClient(rest));
      } finally {
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
  test(
    'transient native work retries without a further relay or lifecycle event',
    () async {
      SharedPreferences.setMockInitialValues({});
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'gateway',
        bridgeId: 'bridge',
        key: List.filled(32, 1),
      );
      var nativeReads = 0, commandReads = 0;
      final recovered = Completer<void>();
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/commands') commandReads++;
        return http.Response(
          request.url.path == '/v1/commands' ? '{"commands":[]}' : '{}',
          200,
        );
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, (
        call,
      ) async {
        if (call.method == 'statusUpdate' &&
            (call.arguments as Map)['state'] == 'running' &&
            !recovered.isCompleted) {
          recovered.complete();
        }
        return true;
      });
      messenger.setMockMethodCallHandler(GatewayRuntime.hardware, (call) async {
        switch (call.method) {
          case 'hasPhoneRole':
            return false;
          case 'getSubscriptions':
            if (++nativeReads == 1) {
              throw PlatformException(code: 'temporarily_unavailable');
            }
            return [];
          case 'peekPending':
          case 'pendingReceipts':
            return [];
          default:
            return null;
        }
      });
      final runtime = GatewayRuntime(store: TestStore(session));
      try {
        await http.runWithClient(() async {
          await runtime.start();
          await recovered.future.timeout(const Duration(seconds: 3));
          expect(nativeReads, greaterThanOrEqualTo(2));
          expect(commandReads, 1);
          await runtime.stop();
        }, () => RelayFixtureClient(rest));
      } finally {
        await runtime.stop();
        messenger.setMockMethodCallHandler(GatewayRuntime.hardware, null);
        messenger.setMockMethodCallHandler(GatewayRuntime.lifecycle, null);
      }
    },
  );
}
