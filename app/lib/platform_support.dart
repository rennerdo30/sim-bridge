import 'dart:io';

import 'package:flutter/foundation.dart';

import 'l10n/app_localizations.dart';

/// Native capability boundaries. Tests may supply a platform explicitly;
/// production always uses the host OS rather than the theme's target platform.
class BridgePlatform {
  const BridgePlatform(this.target);
  final TargetPlatform target;

  static BridgePlatform get current => BridgePlatform(
    Platform.isAndroid
        ? TargetPlatform.android
        : Platform.isIOS
        ? TargetPlatform.iOS
        : Platform.isMacOS
        ? TargetPlatform.macOS
        : Platform.isWindows
        ? TargetPlatform.windows
        : TargetPlatform.linux,
  );

  bool get isDesktop => switch (target) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };
  bool get canGateway => target == TargetPlatform.android;
  bool get canScanInvitation => !isDesktop;
  bool get defaultAutoCopy => !isDesktop;
  bool restoreGateway(bool storedGateway) => canGateway && storedGateway;

  /// Prefilled relay address. Release builds start empty, because emulator
  /// and loopback addresses never reach a real relay from a user's device.
  String get defaultRelayUrl => kReleaseMode
      ? ''
      : canGateway
      ? 'http://10.0.2.2:8787'
      : 'http://127.0.0.1:8787';

  String defaultDeviceName(AppLocalizations l10n) => switch (target) {
    TargetPlatform.macOS => l10n.defaultDeviceNameMac,
    TargetPlatform.windows => l10n.defaultDeviceNameWindows,
    TargetPlatform.linux => l10n.defaultDeviceNameLinux,
    TargetPlatform.iOS => l10n.defaultDeviceNameIos,
    _ => l10n.defaultDeviceNameAndroid,
  };
}
