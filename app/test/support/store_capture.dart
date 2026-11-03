import 'relay_http_fixture.dart';
// Store screenshot candidates rendered from the production widgets at exact
// store resolutions, in English and German, with only in-memory synthetic
// preferences, credentials, HTTP and native channels. These are widget renders,
// not native-device captures; see store/media-candidates/README.md.
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
  testWidgets('render store screenshot candidates with isolated synthetic data', (
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
    final root = Directory('../store/media-candidates');
    final session = Session(
      server: 'https://relay.example.com',
      token: 'synthetic-gallery-token',
      deviceId: 'gallery-client',
      bridgeId: 'gallery-bridge',
      key: List.filled(32, 0),
    );
    // Fictional data only: +1 202-555-01xx numbers and example names.
    const text = {
      'en': {
        'sim': 'Personal SIM',
        'carrier': 'Example Mobile',
        'service': 'Example Account',
        'code': 'Your verification code is 482619. It expires in 10 minutes.',
        'meeting': 'See you at the cafe at 3. Can you bring the charger?',
        'reply': 'Absolutely. See you there!',
        'gateway': 'Android gateway',
        'computer': 'My computer',
        'phone': 'My iPhone',
        'tablet': 'My iPad',
        'android': 'My phone',
        'androidTablet': 'My tablet',
      },
      'de': {
        'sim': 'Private SIM',
        'carrier': 'Beispiel Mobil',
        'service': 'Beispielkonto',
        'code':
            'Dein Bestätigungscode lautet 482619. Er ist 10 Minuten gültig.',
        'meeting':
            'Wir sehen uns um 15 Uhr im Café. Bringst du das Ladekabel mit?',
        'reply': 'Klar, bis gleich!',
        'gateway': 'Android-Gateway',
        'computer': 'Mein Computer',
        'phone': 'Mein iPhone',
        'tablet': 'Mein iPad',
        'android': 'Mein Telefon',
        'androidTablet': 'Mein Tablet',
      },
    };
    late List<Map<String, dynamic>> records, devices;
    // The capturing device is "this device": a phone in mobile captures,
    // a computer in desktop captures.
    Future<void> prepare(
      String language, {
      required bool desktop,
      bool android = false,
    }) async {
      final t = text[language]!;
      final now = DateTime.now().toUtc();
      final clear = <Map<String, dynamic>>[
        {
          'kind': 'gateway_state',
          'simProfiles': [
            {
              'subscriptionId': 1,
              'slotIndex': 0,
              'displayName': t['sim'],
              'carrierName': t['carrier'],
              'phoneNumber': '+1 202-555-0142',
            },
          ],
        },
        {
          'kind': 'sms',
          'direction': 'incoming',
          'eventId': 'gallery-code',
          'address': t['service'],
          'body': t['code'],
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
          'body': t['meeting'],
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
          'body': t['reply'],
          'status': 'sent',
          'occurredAt': now
              .subtract(const Duration(minutes: 6))
              .toIso8601String(),
          'subscriptionId': 1,
        },
      ];
      records = (await tester.runAsync(
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
      ))!;
      devices = [
        {
          'id': 'gallery-gateway',
          'name': t['gateway'],
          'isOwner': true,
          'lastSeenAt': now.toIso8601String(),
          'online': true,
          'capabilities': {'smsGateway': true, 'calls': true, 'multiSim': true},
        },
        {
          'id': session.deviceId,
          'name': desktop ? t['computer'] : t[android ? 'android' : 'phone'],
          'isOwner': false,
          'lastSeenAt': now.toIso8601String(),
          'online': true,
          'capabilities': {'smsGateway': false},
        },
        {
          'id': 'gallery-other',
          'name': desktop
              ? t['phone']
              : t[android ? 'androidTablet' : 'tablet'],
          'isOwner': false,
          'lastSeenAt': now.toIso8601String(),
          'online': true,
          'capabilities': {'smsGateway': false},
        },
      ];
    }

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
        // A realistic round trip, so the measured relay latency is not 0 ms.
        sleep(const Duration(milliseconds: 38));
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

    late AppLocalizations l10n;
    Future<void> mount({
      required Size size,
      required TargetPlatform platform,
      required Locale locale,
      bool paired = true,
    }) async {
      l10n = lookupAppLocalizations(locale);
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
            locale: locale,
            theme: buildTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BridgePage(platformOverride: BridgePlatform(platform)),
          ),
        ),
      );
      await ready(
        tester,
        paired ? l10n.recentActivity : l10n.pairExistingBridge,
      );
      if (paired) await ready(tester, text[locale.languageCode]!['service']!);
      if (!paired) await tester.pump(const Duration(seconds: 7));
    }

    Future<void> capture(String path, double scale) async {
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final file = File('${root.path}/$path.png');
        await file.parent.create(recursive: true);
        final image = await render.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> tab(String label) async {
      await tester.tap(find.text(label).last);
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> compose() async {
      await tester.tap(find.text(l10n.fabNew).last);
      await tester.pump(const Duration(milliseconds: 800));
    }

    // Logical size × scale gives the exact store pixel size.
    const phones = {
      'apple/iphone-6.9': (
        Size(440, 956),
        3.0,
        TargetPlatform.iOS,
      ), // 1320×2868
      'apple/iphone-6.3': (
        Size(402, 874),
        3.0,
        TargetPlatform.iOS,
      ), // 1206×2622
      'apple/ipad-13': (Size(1032, 1376), 2.0, TargetPlatform.iOS), // 2064×2752
      'google_play/phone': (
        Size(360, 640),
        3.0,
        TargetPlatform.android,
      ), // 1080×1920
    };
    final locales = {'en-US': const Locale('en'), 'de-DE': const Locale('de')};

    await http.runWithClient(() async {
      for (final MapEntry(key: tag, value: locale) in locales.entries) {
        for (final MapEntry(key: slot, value: (size, scale, platform))
            in phones.entries) {
          await prepare(
            locale.languageCode,
            desktop: false,
            android: platform == TargetPlatform.android,
          );
          final store = slot.split('/').first, device = slot.split('/').last;
          final base = '$store/$tag/$device';
          await mount(size: size, platform: platform, locale: locale);
          await capture('$base-1-activity', scale);
          await compose();
          await capture('$base-2-compose', scale);
          await mount(size: size, platform: platform, locale: locale);
          await tab(l10n.tabDevices);
          await capture('$base-3-devices', scale);
          await tab(l10n.tabSettings);
          await capture('$base-4-settings', scale);
        }
        // renner.dev launcher: desktop client at the default window size.
        await prepare(locale.languageCode, desktop: true);
        for (final (name, platform) in [
          ('macos', TargetPlatform.macOS),
          ('windows', TargetPlatform.windows),
        ]) {
          final base = 'renner_dev/$tag/$name';
          const size = Size(1180, 800);
          await mount(size: size, platform: platform, locale: locale);
          await capture('$base-1-activity', 2);
          await tab(l10n.tabDevices);
          await capture('$base-2-devices', 2);
          await tab(l10n.tabSettings);
          await capture('$base-3-settings', 2);
          await mount(
            size: size,
            platform: platform,
            locale: locale,
            paired: false,
          );
          await capture('$base-4-setup', 2);
        }
      }
      await tester.pumpWidget(const SizedBox());
    }, () => RelayFixtureClient(client));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
