import 'support/relay_http_fixture.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bridge/api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/bridge_page.dart';
import 'package:sim_bridge/l10n/app_localizations.dart';
import 'package:sim_bridge/platform_support.dart';
import 'package:sim_bridge/theme.dart';
import 'package:sim_bridge/widgets.dart';

Future<void> pumpReady(WidgetTester tester, Finder expected) async {
  for (var i = 0; i < 40 && expected.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(expected, findsOneWidget);
}

Widget desktopApp(
  TargetPlatform platform, {
  Locale locale = const Locale('en'),
}) => MaterialApp(
  locale: locale,
  theme: buildTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: BridgePage(platformOverride: BridgePlatform(platform)),
);

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test('$platform cannot become a gateway or use camera pairing', () {
      final host = BridgePlatform(platform);
      expect(host.isDesktop, isTrue);
      expect(host.canGateway, isFalse);
      expect(host.restoreGateway(true), isFalse);
      expect(host.canScanInvitation, isFalse);
      expect(host.defaultAutoCopy, isFalse);
      expect(host.defaultRelayUrl, 'http://127.0.0.1:8787');
    });

    testWidgets(
      '$platform recovery onboarding has local defaults and no scan',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.physicalSize = const Size(1100, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(desktopApp(platform));
        await pumpReady(tester, find.text('Pair an existing bridge'));
        expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
        expect(find.text('Relay access key'), findsNothing);
        expect(find.text('A client on your computer'), findsOneWidget);
        final fields = tester
            .widgetList<TextField>(find.byType(TextField))
            .toList();
        expect(fields, hasLength(2));
        expect(fields.first.controller!.text, 'http://127.0.0.1:8787');
        expect(
          fields.last.controller!.text,
          BridgePlatform(
            platform,
          ).defaultDeviceName(lookupAppLocalizations(const Locale('en'))),
        );
        expect(tester.takeException(), isNull);
        // On desktop the primary button opens code entry.
        await tester.ensureVisible(find.text('Pair an existing bridge'));
        await tester.pump();
        await tester.tap(find.text('Pair an existing bridge'));
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.text(
            lookupAppLocalizations(const Locale('en')).recoveryCodeFieldLabel,
          ),
          findsOneWidget,
        );
        final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
        expect(sheet.constraints!.maxWidth, lessThanOrEqualTo(640));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('mobile platform defaults remain unchanged', () {
    const android = BridgePlatform(TargetPlatform.android);
    const ios = BridgePlatform(TargetPlatform.iOS);
    expect(android.canGateway, isTrue);
    expect(android.restoreGateway(true), isTrue);
    expect(android.defaultRelayUrl, 'http://10.0.2.2:8787');
    expect(android.defaultAutoCopy, isTrue);
    expect(ios.canScanInvitation, isTrue);
    expect(ios.defaultRelayUrl, 'http://127.0.0.1:8787');
    expect(ios.restoreGateway(true), isFalse);
  });

  for (final size in [
    const Size(1200, 850),
    const Size(900, 600),
    const Size(760, 600),
    const Size(620, 850),
  ]) {
    final width = size.width;
    testWidgets(
      'German paired desktop at $width uses responsive navigation without overflow',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'server': 'http://127.0.0.1:19999',
          'deviceId': 'test-desktop',
          'bridgeId': 'test-bridge',
          'gateway': true,
        });
        FlutterSecureStorage.setMockInitialValues({
          'deviceToken': 'isolated-test-token',
          'bridgeKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          desktopApp(TargetPlatform.linux, locale: const Locale('de')),
        );
        final l10n = lookupAppLocalizations(const Locale('de'));
        await pumpReady(tester, find.text(l10n.tabActivity));
        expect(
          find.byType(NavigationRail),
          width >= 900 ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          width >= 900 ? findsNothing : findsOneWidget,
        );
        await tester.tap(find.text(l10n.tabSettings));
        await tester.pump();
        expect(find.text(l10n.desktopRole), findsOneWidget);
        expect(find.text(l10n.desktopAvailabilityTitle), findsOneWidget);
        expect(find.text(l10n.gatewayChecksTitle), findsNothing);
        await tester.drag(find.byType(ListView).last, const Offset(0, -400));
        await tester.pump();
        final toggle = tester.widget<Switch>(find.byType(Switch).first);
        expect(toggle.value, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final size in [
    const Size(1180, 800),
    const Size(900, 600),
    const Size(760, 600),
  ]) {
    testWidgets('Mac recovery modal paints and accepts input at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final previousTarget = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MacOSFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() {
        debugDefaultTargetPlatformOverride = previousTarget;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(desktopApp(TargetPlatform.macOS));
      await pumpReady(tester, find.text('Pair an existing bridge'));
      await tester.ensureVisible(find.text('Pair an existing bridge'));
      await tester.pump();
      await tester.tap(find.text('Pair an existing bridge'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final sheetRect = tester.getRect(find.byType(Sheet));
      expect(sheetRect.width, greaterThan(400));
      expect(sheetRect.width, lessThanOrEqualTo(640));
      expect(sheetRect.height, greaterThan(250));
      final l10n = lookupAppLocalizations(const Locale('en'));
      final recoveryField = find.widgetWithText(
        TextField,
        l10n.recoveryCodeFieldLabel,
      );
      expect(recoveryField, findsOneWidget);
      final fieldRect = tester.getRect(recoveryField);
      expect(fieldRect.center.dy, lessThan(size.height));
      await tester.tap(recoveryField);
      await tester.enterText(recoveryField, 'INVALID-TEST-CODE');
      await tester.pump();
      expect(
        tester.widget<TextField>(recoveryField).controller!.text,
        'INVALID-TEST-CODE',
      );
      // An invalid code is reported inside the sheet, which stays open with
      // the typed text, instead of closing and losing the input.
      await tester.tap(
        find.descendant(
          of: find.byType(Sheet),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pump();
      expect(
        find.text(
          lookupAppLocalizations(const Locale('en')).errorInvalidRecoveryCode,
        ),
        findsOneWidget,
      );
      expect(find.byType(Sheet), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = previousTarget;
    });
  }

  testWidgets(
    'desktop notification initialization rejection never attempts an alert',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'server': 'http://127.0.0.1:19999',
        'deviceId': 'test-desktop',
        'bridgeId': 'test-bridge',
        'gateway': false,
      });
      FlutterSecureStorage.setMockInitialValues({
        'deviceToken': 'isolated-test-token',
        'bridgeKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      });
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      var shown = 0;
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'initialize') return false;
        if (call.method == 'show') shown++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(desktopApp(TargetPlatform.windows));
      await pumpReady(tester, find.text('Activity'));
      final l10n = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.text(l10n.tabSettings));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text(l10n.testCodeTitle),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text(l10n.testCodeTitle));
      await tester.pump();
      expect(shown, 0);
      expect(find.text(l10n.testNotificationsUnavailable), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notification service failure preserves inbox and relay connectivity',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'server': 'http://127.0.0.1:19999',
        'deviceId': 'test-desktop',
        'bridgeId': 'test-bridge',
        'gateway': false,
        'notifiedMessageKeys': ['previous-test-event'],
      });
      FlutterSecureStorage.setMockInitialValues({
        'deviceToken': 'isolated-test-token',
        'bridgeKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      });
      const current = Session(
        server: 'http://127.0.0.1:19999',
        token: 'isolated-test-token',
        deviceId: 'test-desktop',
        bridgeId: 'test-bridge',
        key: [],
      );
      final envelope = await tester.runAsync(
        () =>
            Session(
              server: current.server,
              token: current.token,
              deviceId: current.deviceId,
              bridgeId: current.bridgeId,
              key: List.filled(32, 0),
            ).crypto.seal({
              'kind': 'sms',
              'direction': 'incoming',
              'bridgeId': 'test-bridge',
              'eventId': 'new-event',
              'gatewayDeviceId': 'test-gateway',
              'occurredAt': '2026-10-13T00:00:00Z',
              'address': 'test sender',
              'body': 'A message remains visible after notification failure',
            }),
      );
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      var notificationsAttempted = 0;
      const notificationChannel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        notificationChannel,
        (call) async {
          if (call.method == 'initialize') return true;
          if (call.method == 'show') {
            notificationsAttempted++;
            throw PlatformException(
              code: 'test_notification_service_unavailable',
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notificationChannel,
          null,
        ),
      );
      final client = MockClient((request) async {
        if (request.url.path == '/v1/messages') {
          return http.Response(
            jsonEncode({
              'messages': request.url.queryParameters['since'] == '0'
                  ? [
                      {'envelope': envelope, 'gatewayDeviceId': 'test-gateway'},
                    ]
                  : [],
              'latestSeq': 1,
              'oldestSeq': 1,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'devices': [],
            'bridge': {'joinable': true},
          }),
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(desktopApp(TargetPlatform.linux));
        await pumpReady(
          tester,
          find.text('A message remains visible after notification failure'),
        );
        expect(notificationsAttempted, 1);
        expect(
          find.text(lookupAppLocalizations(const Locale('en')).bridgeHealthy),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.text('A message remains visible after notification failure'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, () => RelayFixtureClient(client));
    },
  );

  testWidgets(
    'German compact desktop onboarding remains scrollable without overflow',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(620, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        desktopApp(TargetPlatform.windows, locale: const Locale('de')),
      );
      final l10n = lookupAppLocalizations(const Locale('de'));
      await pumpReady(tester, find.text(l10n.desktopOnboardingHeadline));
      await tester.drag(find.byType(ListView).first, const Offset(0, -1100));
      await tester.pump(const Duration(milliseconds: 300));
      // The primary action opens code entry; no duplicate button is shown.
      expect(find.text(l10n.pairExistingBridge), findsOneWidget);
      expect(find.text(l10n.enterCode), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
