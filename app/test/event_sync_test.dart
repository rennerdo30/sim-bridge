import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/device_authorization.dart';
import 'package:sim_bridge/bridge_page.dart';
import 'package:sim_bridge/l10n/app_localizations.dart';
import 'package:sim_bridge/platform_support.dart';
import 'package:sim_bridge/session_store.dart';
import 'package:sim_bridge/theme.dart';

import 'support/relay_http_fixture.dart';
import 'support/authorization_fixture.dart';

Widget app(TargetPlatform target) => MaterialApp(
  theme: buildTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: BridgePage(platformOverride: BridgePlatform(target)),
);

Future<void> flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void pairing() {
  SharedPreferences.setMockInitialValues({
    'server': 'http://127.0.0.1:18798',
    'deviceId': 'client',
    'bridgeId': 'bridge',
    'gateway': false,
  });
  FlutterSecureStorage.setMockInitialValues({
    'deviceToken': 'synthetic-token',
    'bridgeKey': base64UrlEncode(List.filled(32, 0)),
  });
}

void main() {
  testWidgets(
    'UI stays idle, coalesces in-flight invalidations, reconnects and keeps desktop minimize active',
    (tester) async {
      pairing();
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = Session(
        server: 'http://127.0.0.1:18798',
        token: 'synthetic-token',
        deviceId: 'client',
        bridgeId: 'bridge',
        key: List.filled(32, 0),
      );
      var latest = 0, messageReads = 0, rosterReads = 0;
      final records = <Map<String, dynamic>>[];
      Completer<void>? release;
      final fetching = Completer<void>();
      final clients = <RelayFixtureClient>[];
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/messages') {
          messageReads++;
          final since = int.parse(request.url.queryParameters['since']!);
          final captured = records
              .where((row) => (row['seq'] as int) > since)
              .toList();
          final capturedLatest = latest;
          if (release != null) {
            if (!fetching.isCompleted) fetching.complete();
            await release!.future;
          }
          return http.Response(
            jsonEncode({
              'messages': captured,
              'latestSeq': capturedLatest,
              'oldestSeq': capturedLatest == 0 ? 0 : 1,
            }),
            200,
          );
        }
        if (request.url.path == '/v1/devices') rosterReads++;
        return http.Response(
          jsonEncode({
            'devices': [],
            'bridge': {'joinable': true},
          }),
          200,
        );
      });
      await http.runWithClient(
        () async {
          await tester.pumpWidget(app(TargetPlatform.windows));
          await flush(tester);
          final beforeMessages = messageReads, beforeRoster = rosterReads;
          final active = clients.singleWhere(
            (client) => client.activeConnections == 1,
          );
          active.emit(RelayEvent.heartbeat);
          await tester.pump(const Duration(seconds: 6));
          await flush(tester);
          expect(messageReads, beforeMessages);
          expect(rosterReads, beforeRoster);
          release = Completer<void>();
          active.emit(RelayEvent.messages);
          await flush(tester);
          expect(fetching.isCompleted, true);
          final envelope = await tester.runAsync(
            () => session.crypto.seal({
              'kind': 'sms',
              'direction': 'incoming',
              'body': 'Arrived during a fetch',
              'bridgeId': 'bridge',
              'senderDeviceId': 'gateway',
            }),
          );
          records.add({
            'seq': ++latest,
            'envelope': envelope,
            'gatewayDeviceId': 'gateway',
          });
          for (var i = 0; i < 8; i++) {
            active.emit(RelayEvent.messages);
            active.emit(RelayEvent.devices);
          }
          await flush(tester);
          release!.complete();
          release = null;
          await flush(tester);
          expect(find.text('Arrived during a fetch'), findsOneWidget);
          expect(messageReads, beforeMessages + 2);
          expect(rosterReads, beforeRoster + 1);

          final second = await tester.runAsync(
            () => session.crypto.seal({
              'kind': 'sms',
              'direction': 'incoming',
              'body': 'Caught up after reconnect',
              'bridgeId': 'bridge',
              'senderDeviceId': 'gateway',
            }),
          );
          records.add({
            'seq': ++latest,
            'envelope': second,
            'gatewayDeviceId': 'gateway',
          });
          active.end();
          await flush(tester);
          await tester.pump(const Duration(seconds: 2));
          await flush(tester);
          expect(find.text('Caught up after reconnect'), findsOneWidget);
          expect(
            clients.fold(0, (int total, client) => total + client.connections),
            2,
          );
          final restored = clients.singleWhere(
            (client) => client.activeConnections == 1,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await flush(tester);
          expect(restored.activeConnections, 1);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await flush(tester);
          expect(
            clients.fold(0, (int total, client) => total + client.connections),
            3,
          );
          await tester.pumpWidget(const SizedBox());
          await flush(tester);
          expect(
            clients.every((client) => client.activeConnections == 0),
            true,
          );
          expect(tester.takeException(), isNull);
        },
        () {
          final client = RelayFixtureClient(rest);
          clients.add(client);
          return client;
        },
      );
    },
  );

  testWidgets(
    'relay restart rejection stops retries and preserves local pairing',
    (tester) async {
      pairing();
      var calls = 0;
      final clients = <RelayFixtureClient>[];
      final rest = MockClient((_) async {
        calls++;
        return http.Response('{"error":"Unauthorized"}', 401);
      });
      await http.runWithClient(
        () async {
          await tester.pumpWidget(app(TargetPlatform.windows));
          await flush(tester);
          final l10n = lookupAppLocalizations(const Locale('en'));
          expect(find.text(l10n.relayPairingExpired), findsOneWidget);
          final before = calls;
          await tester.pump(const Duration(seconds: 10));
          await flush(tester);
          expect(calls, before);
          expect(
            clients.every((client) => client.activeConnections == 0),
            true,
          );
          expect(
            await SessionStore.secureStorage.read(key: 'deviceToken'),
            'synthetic-token',
          );
          expect(
            await SessionStore.secureStorage.read(key: 'bridgeKey'),
            isNotNull,
          );
          await tester.pumpWidget(const SizedBox());
          await flush(tester);
          expect(tester.takeException(), isNull);
        },
        () {
          final client = RelayFixtureClient(rest);
          clients.add(client);
          return client;
        },
      );
    },
  );
  testWidgets(
    'late successful fetch cannot clear a terminal stream rejection',
    (tester) async {
      pairing();
      final clients = <RelayFixtureClient>[];
      var rejectEvents = false;
      Completer<void>? held;
      final fetching = Completer<void>();
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/messages') {
          if (held != null) {
            if (!fetching.isCompleted) fetching.complete();
            await held!.future;
          }
          return http.Response(
            '{"messages":[],"latestSeq":0,"oldestSeq":0}',
            200,
          );
        }
        return http.Response('{"devices":[],"bridge":{"joinable":true}}', 200);
      });
      await http.runWithClient(
        () async {
          await tester.pumpWidget(app(TargetPlatform.windows));
          await flush(tester);
          final active = clients.singleWhere(
            (client) => client.activeConnections == 1,
          );
          held = Completer<void>();
          active.emit(RelayEvent.messages);
          await flush(tester);
          expect(fetching.isCompleted, true);
          rejectEvents = true;
          active.end();
          await flush(tester);
          await tester.pump(const Duration(seconds: 2));
          await flush(tester);
          final text = lookupAppLocalizations(
            const Locale('en'),
          ).relayPairingExpired;
          expect(find.text(text), findsOneWidget);
          held!.complete();
          held = null;
          await flush(tester);
          expect(find.text(text), findsOneWidget);
          expect(
            await SessionStore.secureStorage.read(key: 'bridgeKey'),
            isNotNull,
          );
          await tester.pumpWidget(const SizedBox());
          await flush(tester);
          expect(tester.takeException(), isNull);
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
    },
  );
  testWidgets(
    'client process restart consumes staged operator recovery and waits for late gateway',
    (tester) async {
      pairing();
      final store = SessionStore();
      final old = (await store.load())!.session;
      final identity = await store.prepareUpgradeIdentity(old);
      final certificate = fixtureCertificate(
        identity,
        deviceId: 'client',
        authority: false,
      );
      await store.stageOperatorRecovery(old, certificate, null, gateway: false);
      var available = false, resumes = 0, legacyUpgrades = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(app(TargetPlatform.windows));
          for (var i = 0; i < 3; i++) {
            await flush(tester);
          }
          expect(resumes, greaterThan(0));
          expect(legacyUpgrades, 0);
          expect(
            find.text(
              lookupAppLocalizations(const Locale('en')).pairingRecoveryWaiting,
            ),
            findsOneWidget,
          );
          available = true;
          await tester.pump(const Duration(seconds: 3));
          for (var i = 0; i < 6; i++) {
            await flush(tester);
          }
          final current = (await store.load())!.session;
          expect(current.token, 'operator-restored');
          expect(current.deviceId, old.deviceId);
          expect(current.key, old.key);
          expect(
            await SessionStore.secureStorage.read(key: 'operatorRecovery'),
            isNull,
          );
          expect(legacyUpgrades, 0);
          await tester.pumpWidget(const SizedBox());
          await flush(tester);
          expect(tester.takeException(), isNull);
        },
        () => RelayFixtureClient(
          MockClient((request) async {
            if (request.url.path == '/v1/auth/upgrade') legacyUpgrades++;
            if (request.url.path == '/v1/auth/resume') {
              resumes++;
              return available
                  ? http.Response(
                      jsonEncode({
                        'token': 'operator-restored',
                        'certificate': certificate,
                        'bootId': 'new-boot',
                        'device': {'id': 'client'},
                        'bridge': {'id': 'bridge'},
                      }),
                      200,
                    )
                  : http.Response(
                      '{"code":"pairing_recovery_pending","error":"Waiting for gateway"}',
                      409,
                    );
            }
            if (request.url.path == '/v1/messages') {
              return http.Response(
                '{"messages":[],"latestSeq":0,"oldestSeq":0}',
                200,
              );
            }
            return http.Response(
              '{"devices":[],"bridge":{"joinable":true}}',
              200,
            );
          }),
          requireCertificate: true,
        ),
      );
    },
  );
  testWidgets(
    'Leave waits for renewal and accepts durable revoked absence after a lost removal ACK',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const discovery = MethodChannel('fr.skyost.bonsoir');
      final eventChannels = <MethodChannel>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        discovery,
        (call) async {
          if (call.method == 'discovery.initialize') {
            final events = MethodChannel(
              'fr.skyost.bonsoir.discovery.${call.arguments['id']}',
            );
            eventChannels.add(events);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              events,
              (_) async => null,
            );
          }
          return null;
        },
      );
      addTearDown(() {
        for (final channel in [discovery, ...eventChannels]) {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        }
      });
      pairing();
      final store = SessionStore();
      final old = (await store.load())!.session;
      final identity = await store.prepareUpgradeIdentity(old);
      final certificate = fixtureCertificate(
        identity,
        deviceId: 'client',
        authority: false,
      );
      final original = old.withCredentials(
        old.token,
        DeviceAuthorization(
          identity: identity,
          certificate: certificate,
          bootId: 'old-boot',
        ),
      );
      await store.save(original, gateway: false);
      final started = Completer<void>(), release = Completer<void>();
      var recovering = true, leaves = 0;
      final rest = MockClient((request) async {
        if (request.url.path == '/v1/auth/resume') {
          if (!started.isCompleted) started.complete();
          await release.future;
          recovering = false;
          return http.Response(
            jsonEncode({
              'token': 'renewed-before-leave',
              'certificate': certificate,
              'bootId': 'new-boot',
              'device': {'id': 'client'},
              'bridge': {'id': 'bridge'},
            }),
            200,
          );
        }
        if (request.url.path == '/v1/devices/me/leave') {
          leaves++;
          expect(
            request.headers['authorization'],
            'Bearer renewed-before-leave',
          );
          return leaves == 1
              ? http.Response(
                  '{"code":"policy_pending","error":"ACK pending"}',
                  409,
                )
              : http.Response(
                  '{"code":"device_revoked","error":"Already removed"}',
                  401,
                );
        }
        if (request.url.path == '/v1/messages') {
          return http.Response(
            '{"messages":[],"latestSeq":0,"oldestSeq":0}',
            200,
          );
        }
        return http.Response('{"devices":[],"bridge":{"joinable":true}}', 200);
      });
      await http.runWithClient(
        () async {
          await tester.pumpWidget(app(TargetPlatform.windows));
          for (var i = 0; i < 4; i++) {
            await flush(tester);
          }
          expect(started.isCompleted, true);
          await tester.tap(find.text('Settings'));
          await flush(tester);
          final leaveText = lookupAppLocalizations(
            const Locale('en'),
          ).leaveBridge;
          await tester.scrollUntilVisible(
            find.text(leaveText),
            300,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.tap(find.text(leaveText));
          await flush(tester);
          await tester.tap(
            find.text(
              lookupAppLocalizations(const Locale('en')).leaveBridgeConfirm,
            ),
          );
          await flush(tester);
          expect(leaves, 0);
          expect(
            await SessionStore.secureStorage.read(key: 'deviceAuthorization'),
            isNotNull,
          );
          release.complete();
          for (var i = 0; i < 6; i++) {
            await flush(tester);
          }
          expect(leaves, 1);
          expect(
            await SessionStore.secureStorage.read(key: 'deviceAuthorization'),
            isNotNull,
          );
          await tester.tap(find.text(leaveText));
          await flush(tester);
          await tester.tap(
            find.text(
              lookupAppLocalizations(const Locale('en')).leaveBridgeConfirm,
            ),
          );
          for (var i = 0; i < 4; i++) {
            await flush(tester);
          }
          expect(leaves, 2);
          expect(
            await SessionStore.secureStorage.read(key: 'deviceAuthorization'),
            isNull,
          );
          expect(
            await SessionStore.secureStorage.read(key: 'bridgeKey'),
            isNull,
          );
          expect(
            await SessionStore.secureStorage.read(key: 'deviceToken'),
            isNull,
          );
          await tester.pump(const Duration(seconds: 5));
          await flush(tester);
          expect(
            await SessionStore.secureStorage.read(key: 'deviceAuthorization'),
            isNull,
          );
          await tester.pumpWidget(const SizedBox());
          await flush(tester);
          expect(tester.takeException(), isNull);
        },
        () => RelayFixtureClient(
          rest,
          eventStatus: recovering ? 409 : 200,
          eventCode: recovering ? 'pairing_recovery_pending' : null,
        ),
      );
    },
  );
}
