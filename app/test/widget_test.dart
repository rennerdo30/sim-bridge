import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:sim_bridge/platform_support.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_bridge/main.dart';

/// Pumps in fixed steps until [condition] holds. `pumpAndSettle` is unusable
/// because the startup placeholder animates continuously.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 30,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
}

void main() {
  testWidgets('reaches onboarding on its own when no session is stored', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      const SimBridgeApp(platformOverride: BridgePlatform(TargetPlatform.iOS)),
    );
    // Startup must complete unaided. This guards the deadlock that once left
    // the app stuck on its placeholder: if restore never finishes, onboarding
    // never appears and the expectations below fail.
    await pumpUntil(
      tester,
      () => find.text('Pair an existing bridge').evaluate().isNotEmpty,
    );

    expect(find.textContaining('One SIM.'), findsOneWidget);
    expect(find.text('Pair an existing bridge'), findsOneWidget);
    expect(find.text('Relay access key'), findsNothing);
  });

  testWidgets('a stored session skips onboarding entirely', (tester) async {
    SharedPreferences.setMockInitialValues({
      'server': 'http://192.168.1.10:8787',
      'deviceId': 'device-1',
      'bridgeId': 'bridge-1',
      'gateway': false,
    });
    FlutterSecureStorage.setMockInitialValues({
      'deviceToken': 'stored-token',
      // 32 zero bytes, base64url — a well-formed bridge key.
      'bridgeKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    });

    await tester.pumpWidget(
      const SimBridgeApp(platformOverride: BridgePlatform(TargetPlatform.iOS)),
    );
    await pumpUntil(tester, () => find.text('Activity').evaluate().isNotEmpty);

    // A paired phone must never be shown the setup form, even briefly.
    expect(find.text('Pair an existing bridge'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
  });
}
