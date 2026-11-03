import 'package:flutter/material.dart';

import 'bridge_page.dart';
import 'gateway_runtime.dart';
import 'logging.dart';
import 'platform_support.dart';
import 'l10n/app_localizations.dart';
import 'theme.dart';

void main() => runApp(const SimBridgeApp());

@pragma('vm:entry-point')
Future<void> gatewayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.initialize(fileName: 'sim-bridge-gateway.log');
  await GatewayRuntime().start();
}

class SimBridgeApp extends StatelessWidget {
  const SimBridgeApp({super.key, this.platformOverride});
  final BridgePlatform? platformOverride;

  @override
  Widget build(BuildContext context) => MaterialApp(
    onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
    debugShowCheckedModeBanner: false,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(),
    home: BridgePage(platformOverride: platformOverride),
  );
}
