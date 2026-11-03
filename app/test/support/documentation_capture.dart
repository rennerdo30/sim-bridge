import 'relay_http_fixture.dart';
// Reproducible documentation images from the production widgets, with only
// in-memory synthetic preferences, credentials, HTTP and native channels.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/api.dart';
import 'package:sim_bridge/bridge_page.dart';
import 'package:sim_bridge/l10n/app_localizations.dart';
import 'package:sim_bridge/platform_support.dart';
import 'package:sim_bridge/theme.dart';

Future<void> ready(WidgetTester tester, String text) async {
  for (var i = 0; i < 60 && find.text(text).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.text(text), findsWidgets);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('render documentation gallery with isolated synthetic data', (
    tester,
  ) async {
    final sdk = Platform.environment['FLUTTER_ROOT'];
    if (sdk == null) throw StateError('Set FLUTTER_ROOT to the Flutter SDK.');
    await tester.runAsync(() async {
      for (final family in [Fonts.display, Fonts.mono]) {
        final loader = FontLoader(family);
        final paths = family == Fonts.display
            ? [
                'BricolageGrotesque-SemiBold.ttf',
                'BricolageGrotesque-ExtraBold.ttf',
              ]
            : ['JetBrainsMono-Medium.ttf', 'JetBrainsMono-Bold.ttf'];
        for (final path in paths) {
          loader.addFont(
            Future.value(
              ByteData.sublistView(
                await File('assets/fonts/$path').readAsBytes(),
              ),
            ),
          );
        }
        await loader.load();
      }
      final body = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        body.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '$sdk/bin/cache/artifacts/material_fonts/Roboto-$weight.ttf',
              ).readAsBytes(),
            ),
          ),
        );
      }
      await body.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          ByteData.sublistView(
            await File(
              '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes(),
          ),
        ),
      );
      await icons.load();
    });
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final discoveryChannels = <MethodChannel>[];
    const discovery = MethodChannel('fr.skyost.bonsoir');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(discovery, (
      call,
    ) async {
      if (call.method == 'discovery.initialize') {
        final events = MethodChannel(
          'fr.skyost.bonsoir.discovery.${call.arguments['id']}',
        );
        discoveryChannels.add(events);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          events,
          (call) async => null,
        );
      }
      return null;
    });
    addTearDown(() {
      for (final channel in [discovery, ...discoveryChannels]) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    });
    const nativeNotifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      nativeNotifications,
      (call) async => call.method == 'initialize' ? true : null,
    );
    const macNotifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    // Plugin dispatch is mocked; no OS permission prompt or alert is delivered.
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        macNotifications,
        null,
      ),
    );
    final boundary = GlobalKey();
    final out = Directory('../docs/public/screenshots');
    await tester.runAsync(() => out.create(recursive: true));
    final session = Session(
      server: 'https://relay.example.com',
      token: 'synthetic-gallery-token',
      deviceId: 'gallery-desktop',
      bridgeId: 'gallery-bridge',
      key: List.filled(32, 0),
    );
    final now = DateTime.now().toUtc();
    final clear = <Map<String, dynamic>>[
      {
        'kind': 'gateway_state',
        'simProfiles': [
          {
            'subscriptionId': 1,
            'slotIndex': 0,
            'displayName': 'Personal SIM',
            'carrierName': 'Example Mobile',
            'phoneNumber': '+1 202-555-0142',
          },
        ],
      },
      {
        'kind': 'sms',
        'direction': 'incoming',
        'eventId': 'gallery-code',
        'address': 'Example Account',
        'body': 'Your verification code is 482619. It expires in 10 minutes.',
        'occurredAt': now
            .subtract(const Duration(minutes: 2))
            .toIso8601String(),
        'subscriptionId': 1,
      },
      {
        'kind': 'sms',
        'direction': 'incoming',
        'eventId': 'gallery-meeting',
        'address': '+1 202-555-0108',
        'body': 'See you at the cafe at 3. Can you bring the charger?',
        'occurredAt': now
            .subtract(const Duration(minutes: 8))
            .toIso8601String(),
        'subscriptionId': 1,
      },
      {
        'kind': 'sms',
        'direction': 'outgoing',
        'eventId': 'gallery-reply',
        'address': '+1 202-555-0108',
        'body': 'Absolutely. See you there!',
        'status': 'sent',
        'occurredAt': now
            .subtract(const Duration(minutes: 6))
            .toIso8601String(),
        'subscriptionId': 1,
      },
    ];
    final records = await tester.runAsync(
      () async => [
        for (final event in [clear[0], clear[2], clear[3], clear[1]])
          {
            'gatewayDeviceId': 'gallery-gateway',
            'receivedAt': now.toIso8601String(),
            'envelope': await session.crypto.seal({
              ...event,
              'bridgeId': session.bridgeId,
              'senderDeviceId': 'gallery-gateway',
              'gatewayDeviceId': 'gallery-gateway',
              'v': 2,
            }),
          },
      ],
    );
    final devices = [
      {
        'id': 'gallery-gateway',
        'name': 'Android gateway',
        'isOwner': true,
        'lastSeenAt': now.toIso8601String(),
        'online': true,
        'capabilities': {'smsGateway': true, 'calls': true, 'multiSim': true},
      },
      {
        'id': session.deviceId,
        'name': 'My computer',
        'isOwner': false,
        'lastSeenAt': now.toIso8601String(),
        'online': true,
        'capabilities': {'smsGateway': false},
      },
      {
        'id': 'gallery-phone',
        'name': 'My iPhone',
        'isOwner': false,
        'lastSeenAt': now.toIso8601String(),
        'online': true,
        'capabilities': {'smsGateway': false},
      },
    ];
    final client = MockClient((request) async {
      if (request.url.path == '/v1/messages') {
        return http.Response(
          jsonEncode({
            'messages': request.url.queryParameters['since'] == '0'
                ? records
                : [],
            'oldestSeq': 1,
            'latestSeq': 4,
          }),
          200,
        );
      }
      if (request.url.path == '/v1/devices') {
        return http.Response(
          jsonEncode({
            'devices': devices,
            'bridge': {'joinable': true},
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    Future<void> mount({
      required Size size,
      bool paired = true,
      bool mobile = false,
    }) async {
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues(
        paired
            ? {
                'server': session.server,
                'deviceId': session.deviceId,
                'bridgeId': session.bridgeId,
                'gateway': false,
                'autoCopyCodes': false,
              }
            : {},
      );
      FlutterSecureStorage.setMockInitialValues(
        paired
            ? {
                'deviceToken': session.token,
                'bridgeKey': base64UrlEncode(session.key),
              }
            : {},
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('en'),
            theme: buildTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BridgePage(
              platformOverride: BridgePlatform(
                mobile ? TargetPlatform.iOS : TargetPlatform.macOS,
              ),
            ),
          ),
        ),
      );
      await ready(
        tester,
        paired ? 'Recent activity' : 'Pair an existing bridge',
      );
      if (paired) await ready(tester, 'Example Account');
      if (!paired) await tester.pump(const Duration(seconds: 7));
    }

    Future<void> capture(String name, double scale) async {
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${out.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await http.runWithClient(() async {
      await mount(size: const Size(1180, 800));
      await capture('desktop-inbox', 2);
      await tester.tap(find.text('Devices'));
      await tester.pump(const Duration(milliseconds: 500));
      await capture('desktop-devices', 2);
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 500));
      await capture('desktop-settings', 2);
      await mount(size: const Size(1180, 800), paired: false);
      await capture('desktop-onboarding', 2);
      await mount(size: const Size(390, 844), mobile: true);
      await capture('mobile-inbox', 3);
      await tester.pumpWidget(const SizedBox());
    }, () => RelayFixtureClient(client));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
