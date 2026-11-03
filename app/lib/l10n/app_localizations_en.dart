// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get relayPairingExpired =>
      'This device is no longer authorized by the gateway. Your keys and local history are preserved. Use operator pairing recovery if the operator has approved restoring this device.';

  @override
  String get relayEventReconnecting =>
      'Reconnecting to the relay event stream…';

  @override
  String get appTitle => 'Sim Bridge';

  @override
  String get onboardingHeadline => 'One SIM.\nEvery phone.';

  @override
  String get onboardingTagline =>
      'Texts, verification codes and calls from your SIM, on every phone you own. End-to-end encrypted — the relay can\'t read any of it.';

  @override
  String get trustEncrypted => 'End-to-end encrypted';

  @override
  String get trustKeysLocal => 'Keys never leave your phones';

  @override
  String get setupTitle => 'Set up this phone';

  @override
  String get setupSubtitle => 'Connect to your private relay to get started.';

  @override
  String get relayUrlLabel => 'Relay URL';

  @override
  String get relayKeyLabel => 'Relay access key';

  @override
  String get deviceNameLabel => 'Device name';

  @override
  String get defaultDeviceNameIos => 'iPhone';

  @override
  String get defaultDeviceNameAndroid => 'Android gateway';

  @override
  String get discoverySearching => 'Looking for relays on this network…';

  @override
  String get discoveryNone => 'No relay found on this network';

  @override
  String get discoveryRetry => 'Scan again';

  @override
  String discoveryUnavailable(String details) {
    return 'Local relay discovery is unavailable: $details';
  }

  @override
  String get roleGateway => 'SIM gateway';

  @override
  String get roleClient => 'Client only';

  @override
  String get iosClientTitle => 'Client mode on iPhone';

  @override
  String get iosClientBody =>
      'View activity and send encrypted commands from this phone. An Android phone provides the SIM.';

  @override
  String get createBridge => 'Create a bridge';

  @override
  String get scanInvitation => 'Scan invitation';

  @override
  String get enterCode => 'Enter code';

  @override
  String get manualJoinTitle => 'Enter invitation';

  @override
  String get manualJoinSubtitle =>
      'Use the details shown on the trusted phone.';

  @override
  String get recoveryCodeFieldLabel => '52-character recovery code';

  @override
  String get joinBridge => 'Join bridge';

  @override
  String get pairTitle => 'Pair another phone';

  @override
  String get pairSubtitle => 'Scan the QR code or enter the details manually.';

  @override
  String get pairMethods => 'QR code or recovery code';

  @override
  String get recoveryCodeLabel => 'Recovery code';

  @override
  String get pairWarning =>
      'Anyone with these details can decrypt this bridge. Share them only with a phone you trust.';

  @override
  String labelCopied(String label) {
    return '$label copied';
  }

  @override
  String get copyTooltip => 'Copy';

  @override
  String get tabActivity => 'Activity';

  @override
  String get tabDevices => 'Devices';

  @override
  String get tabSettings => 'Settings';

  @override
  String get fabNew => 'New';

  @override
  String get pairDeviceTooltip => 'Pair another phone';

  @override
  String get bridgeHealthy => 'Bridge is healthy';

  @override
  String get bridgeOffline => 'Relay unreachable';

  @override
  String relayLatency(String milliseconds) {
    return 'Relay $milliseconds ms · content stays encrypted';
  }

  @override
  String get reconnecting => 'Trying to reconnect securely…';

  @override
  String get metricDevices => 'Devices';

  @override
  String get metricGateway => 'SIM gateway';

  @override
  String get statusOnline => 'Online';

  @override
  String get statusOffline => 'Offline';

  @override
  String get recentActivity => 'Recent activity';

  @override
  String eventsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events',
      one: '1 event',
    );
    return '$_temp0';
  }

  @override
  String get emptyActivityTitle => 'Quiet for now';

  @override
  String get emptyActivityBody =>
      'Texts and calls that reach your gateway will appear here.';

  @override
  String get privateNumber => 'Private number';

  @override
  String get unknownSender => 'Unknown sender';

  @override
  String get callIncoming => 'Incoming call';

  @override
  String get callMissed => 'Missed call';

  @override
  String get callDialed => 'Dialed on gateway';

  @override
  String get callActive => 'Call in progress';

  @override
  String get callOnHold => 'Call on hold';

  @override
  String get callEnded => 'Call ended';

  @override
  String get callActivity => 'Call activity';

  @override
  String get declineCall => 'Decline';

  @override
  String get hangUpCall => 'Hang up';

  @override
  String get smsStatusSent => 'Sent to carrier';

  @override
  String get smsStatusWaiting => 'Waiting for carrier confirmation';

  @override
  String smsStatusFailed(String reason) {
    return 'Failed · $reason';
  }

  @override
  String get smsFailureDefault => 'The mobile network rejected this message';

  @override
  String get otpLabel => 'Verification code';

  @override
  String get otpCopied => 'Verification code copied';

  @override
  String notificationOtpTitle(String code) {
    return 'Verification code $code';
  }

  @override
  String notificationMessageVia(String gateway) {
    return 'Message via $gateway';
  }

  @override
  String get notificationChannelName => 'Bridged messages';

  @override
  String get notificationChannelDescription =>
      'Incoming messages from your SIM gateway';

  @override
  String get composeTitle => 'Use the remote SIM';

  @override
  String get composeSubtitle => 'Choose what to do with your line.';

  @override
  String get actionSms => 'Send a text';

  @override
  String get actionSmsSubtitle => 'End-to-end encrypted, sent by your gateway';

  @override
  String get actionCall => 'Place a call';

  @override
  String get actionCallSubtitle =>
      'Dials on the Android gateway — audio stays there';

  @override
  String get smsSheetTitle => 'New message';

  @override
  String get callSheetTitle => 'Place a call';

  @override
  String smsSheetSubtitle(String gateway, String sim) {
    return 'Sent privately through $gateway · $sim.';
  }

  @override
  String callSheetSubtitle(String gateway, String sim) {
    return 'Dials with $gateway · $sim. Audio stays on the gateway.';
  }

  @override
  String get phoneNumberLabel => 'Phone number';

  @override
  String get messageLabel => 'Message';

  @override
  String get encryptAndSend => 'Encrypt & send';

  @override
  String get dialOnGateway => 'Dial on gateway';

  @override
  String get queuedSms =>
      'Encrypted request queued — waiting for carrier confirmation';

  @override
  String get queuedCall =>
      'Encrypted dial request queued — waiting for the gateway';

  @override
  String get chooseSim => 'Choose a SIM';

  @override
  String get chooseSimSubtitle => 'Select the line for this action.';

  @override
  String get defaultLine => 'Default line';

  @override
  String get simDetailsUnavailable => 'SIM details unavailable';

  @override
  String get unknownCarrier => 'Unknown carrier';

  @override
  String simSlot(int number) {
    return 'Slot $number';
  }

  @override
  String simNumber(int number) {
    return 'SIM $number';
  }

  @override
  String get devicesTitle => 'Your devices';

  @override
  String get devicesSubtitle => 'Live presence across this bridge';

  @override
  String get thisPhone => 'This phone';

  @override
  String get roleClientShort => 'Client';

  @override
  String get unnamedPhone => 'Unnamed phone';

  @override
  String simCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count SIMs',
      one: '1 SIM',
    );
    return '$_temp0';
  }

  @override
  String get onlineNow => 'Online now';

  @override
  String get seenJustNow => 'Seen just now';

  @override
  String seenMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Seen $count minutes ago',
      one: 'Seen 1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String seenHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Seen $count hours ago',
      one: 'Seen 1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String get timeJustNow => 'Just now';

  @override
  String timeMinutesAgo(int count) {
    return '${count}m ago';
  }

  @override
  String timeHoursAgo(int count) {
    return '${count}h ago';
  }

  @override
  String timeDaysAgo(int count) {
    return '${count}d ago';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsRole => 'Device role';

  @override
  String get roleGatewayFull => 'Android SIM gateway';

  @override
  String get roleClientIos =>
      'iPhone client — the SIM stays on your Android gateway';

  @override
  String get settingsRelay => 'Relay';

  @override
  String get settingsEncryption => 'Encryption';

  @override
  String get settingsEncryptionSubtitle =>
      'AES-256-GCM · 256-bit key from your pairing';

  @override
  String get settingsCallControl => 'Remote call control';

  @override
  String get callControlReady => 'Decline and hang up from any phone';

  @override
  String get callControlNeedsRole => 'Requires the Android phone role';

  @override
  String get settingsSims => 'Active SIMs';

  @override
  String get noActiveSim => 'No active SIM detected';

  @override
  String get leaveBridge => 'Leave bridge';

  @override
  String get leaveBridgeSubtitle =>
      'Removes the keys and session from this phone';

  @override
  String get leaveBridgeTitle => 'Leave this bridge?';

  @override
  String get leaveBridgeWarning =>
      'This phone\'s copy of the bridge key is erased. To use the bridge again you must pair it from another phone in the bridge, so do this only if you have one to hand.';

  @override
  String get leaveBridgeGatewayWarning =>
      'This phone provides the SIM. After leaving, your other phones lose access to it until you pair again.';

  @override
  String get leaveBridgeConfirm => 'Leave and erase keys';

  @override
  String get callAudioNote =>
      'Call audio stays on the Android gateway. Sim Bridge shows when it rings and can start calls on it; mobile platforms do not pass cellular audio to other apps.';

  @override
  String get cancel => 'Cancel';

  @override
  String get removeDevice => 'Remove';

  @override
  String removeDeviceTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get removeDeviceSubtitle =>
      'That phone loses access to this bridge straight away.';

  @override
  String get removeDeviceKeyWarning =>
      'It still holds a copy of the bridge key, so it can read messages it already downloaded. To cut it off completely, create a new bridge and pair your phones again.';

  @override
  String get removeDeviceGatewayWarning =>
      'This phone provides the SIM. Removing it also deletes the message history it sent to this bridge.';

  @override
  String get removeDeviceRejoinWarning =>
      'This bridge is open to new devices, so the removed phone could rejoin with the recovery code. Close enrollment below to prevent that.';

  @override
  String get removeDeviceConfirm => 'Remove this phone';

  @override
  String deviceRemoved(String name) {
    return '$name was removed';
  }

  @override
  String get ownerBadge => 'Owner';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get notificationsAllowed =>
      'Allowed — codes and messages will alert you';

  @override
  String get notificationsBlocked =>
      'Blocked — allow notifications in system settings';

  @override
  String get notificationsUnknown => 'Allow notifications to see new messages';

  @override
  String get openSettings => 'Open settings';

  @override
  String get testCodeTitle => 'Test a verification code';

  @override
  String get testCodeSubtitle =>
      'Notify this phone with a fake code, nothing is sent';

  @override
  String testCodeSent(String code) {
    return 'Test code $code sent. Try a keyboard suggestion or paste it into a code field.';
  }

  @override
  String get testMessageTitle => 'Send a test message to your phones';

  @override
  String get testMessageSubtitle =>
      'A simulated incoming SMS, encrypted through the relay';

  @override
  String testMessageSent(String code) {
    return 'Test message with code $code sent to your other phones.';
  }

  @override
  String get testSender => 'Sim Bridge test';

  @override
  String testCodeBody(String code) {
    return 'Your Sim Bridge verification code is $code';
  }

  @override
  String get testNotificationsUnavailable =>
      'Allow notifications for Sim Bridge first, then try again.';

  @override
  String get simulatedBadge => 'Test';

  @override
  String get settingsAutoCopy => 'Verification codes';

  @override
  String get autoCopyOn => 'Copied automatically, ready to paste';

  @override
  String get autoCopyOff => 'Copy them yourself from the message';

  @override
  String get settingsEnrollment => 'New devices';

  @override
  String get enrollmentOpen => 'Anyone with the recovery code can join';

  @override
  String get enrollmentClosed => 'Closed — no phone can join';

  @override
  String get enrollmentOpened => 'This bridge now accepts new devices';

  @override
  String get enrollmentClosed2 => 'This bridge no longer accepts new devices';

  @override
  String ownerOnlyHint(String name) {
    return 'Only $name can remove phones or change this.';
  }

  @override
  String get confirmJoinTitle => 'Join this bridge?';

  @override
  String get confirmJoinSubtitle =>
      'Check these details before your phone connects.';

  @override
  String get confirmJoinGatewayWarning =>
      'This phone will share its SIM: texts and call activity will be encrypted and sent to the relay above. Continue only if you set up that relay yourself.';

  @override
  String get confirmJoinClientNote =>
      'This phone will read activity from the bridge. Continue only if you recognise the relay above.';

  @override
  String get errorInvalidInvitation =>
      'That invitation could not be read. Ask for a fresh QR code.';

  @override
  String get errorInvalidRecoveryCode =>
      'That recovery code is not valid. Check all 52 characters and try again.';

  @override
  String get errorInsecureRelay =>
      'A relay outside your local network must use https.';

  @override
  String get errorSmsFields => 'Enter a phone number and a message';

  @override
  String get errorPhoneField => 'Enter a phone number';

  @override
  String get errorNoGateway => 'No Android gateway is connected';

  @override
  String get errorCallGateway => 'The gateway for this call is unavailable';

  @override
  String get scanTitle => 'Scan invitation';

  @override
  String get scanHint => 'Point this phone at the QR code on a trusted device.';

  @override
  String get testCodeKeyboardSubtitle =>
      'Generate a test code, then try a keyboard suggestion or paste it here.';

  @override
  String get verificationCodeLabel => 'Verification code';

  @override
  String get sendTestCode => 'Send test code';

  @override
  String get gatewayRuntimeTitle => 'Background gateway';

  @override
  String get gatewayRuntimeRunning => 'Running · relay connected';

  @override
  String get gatewayRuntimeWaiting =>
      'Running · waiting to reconnect. Messages stay queued.';

  @override
  String get gatewayRuntimeStopped =>
      'Background runtime is stopped. Use Restart gateway below.';

  @override
  String get gatewayRuntimeUnauthorized =>
      'Pairing credentials were rejected. Messages stay queued.';

  @override
  String get gatewayRuntimePermissions =>
      'Required phone permissions are missing. Messages stay queued.';

  @override
  String get gatewayBatteryTitle => 'Battery settings';

  @override
  String get gatewayBatteryUnrestricted =>
      'Battery optimization is off. Android can still stop the app.';

  @override
  String get gatewayBatteryRestricted =>
      'Battery optimization may delay syncing. Review background restrictions.';

  @override
  String get gatewayStopFailed =>
      'Could not stop the gateway safely. Pairing and queued messages were kept. Try again.';

  @override
  String get commandOutcomeUnknown =>
      'Outcome unknown · not retried automatically';

  @override
  String testMessageQueued(String code) {
    return 'Test message with code $code queued. It will upload when the gateway connects.';
  }

  @override
  String get pairingUnavailable =>
      'Stored pairing could not be opened. Unlock the phone and reopen the app. Existing pairing data has been kept.';

  @override
  String get gatewayClearFailed =>
      'Could not finish clearing this phone. Try again.';

  @override
  String get gatewayRestart => 'Restart gateway';

  @override
  String get gatewayRestartDescription =>
      'Restart after the previous worker has stopped. Pairing and queued messages are kept.';

  @override
  String get gatewayNotSynced => 'Not yet';

  @override
  String gatewayRuntimeDetails(String status, int pending, String time) {
    return '$status\nQueued: $pending · Last sync: $time';
  }

  @override
  String get gatewayAutostartTitle => 'Background autostart';

  @override
  String get gatewayAutostartDescription =>
      'Enable Sim Bridge in your device’s system settings. This app cannot confirm that setting.';

  @override
  String get gatewaySettingsUnavailable =>
      'System settings could not be opened. Open this app’s settings manually.';

  @override
  String get gatewayChecksTitle => 'Gateway checks';

  @override
  String get gatewayNeedsAttention => 'Gateway needs attention';

  @override
  String get gatewayReviewSetup => 'Review setup';

  @override
  String get gatewayCheckedNow => 'Checked just now';

  @override
  String get gatewayNotChecked => 'Not checked';

  @override
  String get gatewayChecksSubtitle =>
      'These checks show current device settings. Android can still restrict background activity.';

  @override
  String get gatewayCheckReceive => 'Receive SMS';

  @override
  String get gatewayCheckSend => 'Send SMS';

  @override
  String get gatewayCheckSim => 'SIM access';

  @override
  String get gatewayPermissionGranted => 'Permission granted';

  @override
  String get gatewayReceiveMissing =>
      'Incoming SMS permission is missing. New SMS cannot be captured.';

  @override
  String get gatewaySendMissing =>
      'SMS sending permission is missing. Remote SMS cannot be sent.';

  @override
  String get gatewaySimMissing =>
      'Phone state permission is missing. SIM access is unavailable.';

  @override
  String get gatewayAllowPermissions => 'Allow permissions';

  @override
  String get gatewayOpenPermissions => 'Open app permissions';

  @override
  String get gatewayCheckBackground => 'Background activity';

  @override
  String get gatewayBackgroundAllowed =>
      'No system background restriction detected';

  @override
  String get gatewayBackgroundRestricted =>
      'Background activity is restricted. Review this app’s system settings.';

  @override
  String get gatewayNotificationsVisible => 'Gateway notifications are visible';

  @override
  String get gatewayNotificationsHidden =>
      'Gateway notifications are hidden. The worker may still run, but its status is not visible.';

  @override
  String get gatewayAutostartPending =>
      'Check the device’s autostart setting and enable Sim Bridge. The app cannot read this switch.';

  @override
  String get gatewayAutostartManual =>
      'Confirmed by you · Not checked by the app';

  @override
  String get gatewayOpenAutostart => 'Open autostart settings';

  @override
  String get gatewayConfirmAutostart => 'I enabled autostart';

  @override
  String get gatewayCheckAgain => 'Check again';

  @override
  String get gatewayCheckActionFailed =>
      'Could not update gateway setup. Try again.';

  @override
  String get gatewayRelayConnected => 'Relay connected';

  @override
  String gatewayQueuedWarning(int count) {
    return '$count events are waiting to upload.';
  }

  @override
  String get gatewayRuntimeUnpaired =>
      'Local pairing is unavailable. Unlock this phone and review its pairing settings. Stored data has been kept.';

  @override
  String get gatewayReviewPairing => 'Review pairing settings';

  @override
  String get defaultDeviceNameMac => 'My Mac';

  @override
  String get defaultDeviceNameWindows => 'My Windows PC';

  @override
  String get defaultDeviceNameLinux => 'My Linux PC';

  @override
  String get desktopClientTitle => 'A client on your computer';

  @override
  String get desktopClientBody =>
      'Read messages, copy verification codes, and send SMS or call requests through your paired Android gateway. This computer cannot share a SIM.';

  @override
  String get desktopOnboardingHeadline => 'Your SIM.\nOn your computer.';

  @override
  String get desktopOnboardingTagline =>
      'Keep your Android SIM connected and bring its messages and verification codes to your desk. Only your paired devices can read them.';

  @override
  String get desktopSetupSubtitle =>
      'Join your existing bridge using its relay URL and recovery code. Create a new bridge on its Android SIM gateway first.';

  @override
  String get desktopAvailabilityTitle => 'Keep Sim Bridge open';

  @override
  String get desktopAvailabilityBody =>
      'Sync and notifications work while the app is running, including when minimized. They pause when you quit the app or your computer sleeps. There is no desktop background service or remote push.';

  @override
  String get desktopRole => 'Desktop client · Android gateway required';

  @override
  String get desktopThisDevice => 'This computer';

  @override
  String get desktopClipboardBody =>
      'Automatic copying is optional and off by default. Windows and Linux use the system clipboard without automatic expiry; clipboard history or other apps may retain codes.';

  @override
  String get desktopNotificationsUnknown =>
      'System notification permission cannot be checked here. Try a test notification and review your system notification settings.';

  @override
  String get desktopNotificationsAvailable =>
      'Connected to the system notification service. Whether alerts are shown depends on your system settings.';

  @override
  String get desktopNotificationAction => 'Open Sim Bridge';

  @override
  String get desktopNotificationSettingsHelp =>
      'Review Sim Bridge in your system notification settings.';

  @override
  String get desktopCodeTestSubtitle =>
      'Show a local test alert. Copies a code only when automatic copying is enabled.';

  @override
  String get desktopSetupTitle => 'Set up this computer';

  @override
  String get desktopTrustKeys => 'Keys stay on your devices';

  @override
  String get desktopPairTitle => 'Pair another device';

  @override
  String get desktopPairWarning =>
      'Anyone with these details can decrypt this bridge. Share them only with a device you trust.';

  @override
  String get desktopManualJoinSubtitle =>
      'Use the details shown on a trusted paired device.';

  @override
  String get desktopConfirmJoinSubtitle =>
      'Check these details before your computer connects.';

  @override
  String get desktopConfirmJoinClientNote =>
      'This computer will read activity from the bridge. Continue only if you recognise the relay above.';

  @override
  String get desktopLeaveBridgeSubtitle =>
      'Removes the keys and session from this computer';

  @override
  String get desktopLeaveBridgeWarning =>
      'This computer’s copy of the bridge key is erased. To join again, use the recovery details from another paired device.';

  @override
  String get desktopPairingUnavailable =>
      'Stored pairing could not be opened. Unlock your computer or credential store and reopen the app. Existing pairing data has been kept.';

  @override
  String get desktopUnnamedDevice => 'Unnamed device';

  @override
  String get pairingRecoveryWaiting =>
      'Waiting for the Android gateway to restore secure pairing. Your keys and local history are preserved.';

  @override
  String get pairingLegacyMigration =>
      'This pairing needs an operator-approved upgrade. Your credentials and gateway journal are preserved.';

  @override
  String get gatewayCreationRequired =>
      'Create the bridge on its Android SIM gateway, then pair this device.';

  @override
  String get pairExistingBridge => 'Pair an existing bridge';

  @override
  String get leavePolicyPending =>
      'Removal is not confirmed. Keep the Android gateway connected and try again; your credentials and journal are preserved.';

  @override
  String get operatorRecoveryTitle => 'Operator pairing recovery';

  @override
  String get operatorRecoveryBody =>
      'Send these public identity details to your relay operator. Paste their certificate and, for the Android authority gateway, its approved policy. Existing keys, IDs and journals stay on this device.';

  @override
  String get operatorRecoveryCopy => 'Copy public identity';

  @override
  String get operatorRecoveryCertificate => 'Operator-issued certificate';

  @override
  String get operatorRecoveryPolicy => 'Gateway policy JSON';

  @override
  String get operatorRecoveryApply => 'Apply approved recovery';

  @override
  String get operatorRecoverySummary =>
      'Upgrade an existing pairing after operator approval';

  @override
  String get operatorRecoveryRejected =>
      'Recovery was not accepted. Check the operator-issued certificate and policy; existing credentials are preserved.';

  @override
  String get operatorPrivateVerifier => 'Copy private enrollment verifier';

  @override
  String get operatorPrivateVerifierWarning =>
      'This verifier can authorize enrollment when the operator opens the bridge. Share it only with your trusted relay operator. Encryption keys, device tokens and signing seeds are excluded.';

  @override
  String get operatorIdentityPending =>
      'The gateway has not prepared its protected signing identity yet. Keep the gateway service available and try again. No new key was created by this screen.';

  @override
  String get authorityRemovalWarning =>
      'Removing this authority gateway permanently deactivates the entire bridge. Every paired device loses access.';

  @override
  String get errorRelayUnreachable =>
      'Cannot reach the relay. Check the address and your connection, then try again.';

  @override
  String get errorRelayUnauthorized =>
      'The relay no longer accepts this device. Pair it again from your gateway.';

  @override
  String get errorRelayRefused => 'The relay refused this request.';

  @override
  String get errorRelayNotFound =>
      'The relay does not know this bridge. Check the relay address.';

  @override
  String get errorGatewayBusy =>
      'The Android gateway has to confirm this first. Keep it online and try again.';

  @override
  String get errorRelayBusy =>
      'Too many attempts. Wait a minute and try again.';

  @override
  String get errorRelayFailure =>
      'The relay could not complete the request. Try again later.';

  @override
  String get errorRelayResponse =>
      'The relay sent an unexpected response. Check that the address points to a Sim Bridge relay.';

  @override
  String get errorPermissionDenied =>
      'Sim Bridge needs a permission for this. Allow it in the system settings.';

  @override
  String get errorDeviceAction =>
      'This device could not complete the action. Try again.';

  @override
  String get errorUnexpected => 'Something went wrong. Try again.';

  @override
  String get updatesTitle => 'Updates';

  @override
  String updatesCurrentVersion(String version) {
    return 'Version $version';
  }

  @override
  String updatesAvailableSubtitle(String version) {
    return 'Version $version is available';
  }

  @override
  String get updatesChecking => 'Checking for updates…';

  @override
  String updatesUpToDate(String version) {
    return 'Sim Bridge $version is up to date';
  }

  @override
  String get updatesCheckFailed =>
      'Could not check for updates. Check your connection and try again.';

  @override
  String get updatesAutomatic => 'Check for updates automatically';

  @override
  String get updatesAutomaticSubtitle =>
      'Once a day, from the Sim Bridge releases on GitHub';

  @override
  String updatesAvailableTitle(String version) {
    return 'Sim Bridge $version is available';
  }

  @override
  String get updatesInstallBody =>
      'Sim Bridge downloads and verifies the update, closes, installs it and starts again. Your pairing and settings are kept.';

  @override
  String get updatesDownloadBody =>
      'Sim Bridge downloads and verifies the new version and saves it in your Downloads folder. Then quit Sim Bridge and replace it with the new version. Your pairing and settings are kept.';

  @override
  String get updatesInstall => 'Install and restart';

  @override
  String get updatesDownload => 'Download';

  @override
  String get updatesLater => 'Later';

  @override
  String get updatesReleaseNotes => 'Release notes';

  @override
  String get updatesDownloading => 'Downloading and verifying the update…';

  @override
  String updatesDownloaded(String file) {
    return 'Saved $file in your Downloads folder';
  }

  @override
  String get updatesFailed =>
      'The update could not be downloaded or verified. Try again later.';

  @override
  String updatesNotice(String version) {
    return 'Sim Bridge $version is available';
  }

  @override
  String get updatesShow => 'Update';

  @override
  String get aboutTitle => 'About Sim Bridge';

  @override
  String get aboutTooltip => 'About, updates and licenses';

  @override
  String get aboutTagline =>
      'Your Android SMS and verification codes on every device, end-to-end encrypted, through a relay you run yourself.';

  @override
  String get aboutLegalese => 'Free and open source under the MIT License.';

  @override
  String get aboutWebsite => 'Website';

  @override
  String get aboutSource => 'Source code';

  @override
  String get aboutPrivacy => 'Privacy';

  @override
  String get aboutLicenses => 'Licenses';

  @override
  String get updatesCheckNow => 'Check for updates';

  @override
  String get updatesManaged => 'Updates are managed by the renner.dev launcher';

  @override
  String get close => 'Close';

  @override
  String get callWithoutNumber => 'Phone call';
}
