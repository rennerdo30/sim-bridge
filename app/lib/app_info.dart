import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Public project links shown in About.
const projectWebsite = 'https://sim-bridge.renner.dev';
const projectSource = 'https://github.com/rennerdo30/sim-bridge';
const projectPrivacy = 'https://sim-bridge.renner.dev/docs/legal/privacy/';

/// Command-line flag the renner.dev launcher passes to installs it updates
/// itself; Sim Bridge then never checks for or downloads updates on its own.
const managedUpdatesFlag = '--managed-updates';
// The launcher installs tools under <library>/.tools/<id>/ on every platform.
const _launcherInstallSegment = '/.tools/sim-bridge/';

/// Whether another program (the renner.dev launcher) manages updates for this
/// installation. Set once from the command line in main().
bool updatesManagedExternally = false;

/// True when started with [managedUpdatesFlag], or from the launcher's own
/// install folder, which also covers starting that copy from the Start menu
/// or the Dock without the flag.
bool detectManagedUpdates(List<String> arguments, {String? executable}) {
  if (arguments.contains(managedUpdatesFlag)) return true;
  final path = (executable ?? Platform.resolvedExecutable).replaceAll(
    '\\',
    '/',
  );
  return path.toLowerCase().contains(_launcherInstallSegment);
}

/// Adds Sim Bridge's own license and the bundled fonts' licenses to the
/// licenses page; package licenses are collected by Flutter automatically.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (packages, asset) in const [
      (['Sim Bridge'], 'assets/licenses/SimBridge-MIT.txt'),
      (['Bricolage Grotesque'], 'assets/fonts/BricolageGrotesque-OFL.txt'),
      (['JetBrains Mono'], 'assets/fonts/JetBrainsMono-OFL.txt'),
    ]) {
      try {
        yield LicenseEntryWithLineBreaks(
          packages,
          await rootBundle.loadString(asset),
        );
      } catch (_) {
        // A missing asset must not break the licenses page for the rest.
      }
    }
  });
}
