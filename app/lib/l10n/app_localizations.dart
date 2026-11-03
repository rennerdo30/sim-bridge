import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
  ];

  /// No description provided for @relayPairingExpired.
  ///
  /// In en, this message translates to:
  /// **'This device is no longer authorized by the gateway. Your keys and local history are preserved. Use operator pairing recovery if the operator has approved restoring this device.'**
  String get relayPairingExpired;

  /// No description provided for @relayEventReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to the relay event stream…'**
  String get relayEventReconnecting;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge'**
  String get appTitle;

  /// No description provided for @onboardingHeadline.
  ///
  /// In en, this message translates to:
  /// **'One SIM.\nEvery phone.'**
  String get onboardingHeadline;

  /// No description provided for @onboardingTagline.
  ///
  /// In en, this message translates to:
  /// **'Texts, verification codes and calls from your SIM, on every phone you own. End-to-end encrypted — the relay can\'t read any of it.'**
  String get onboardingTagline;

  /// No description provided for @trustEncrypted.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted'**
  String get trustEncrypted;

  /// No description provided for @trustKeysLocal.
  ///
  /// In en, this message translates to:
  /// **'Keys never leave your phones'**
  String get trustKeysLocal;

  /// No description provided for @setupTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up this phone'**
  String get setupTitle;

  /// No description provided for @setupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to your private relay to get started.'**
  String get setupSubtitle;

  /// No description provided for @relayUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Relay URL'**
  String get relayUrlLabel;

  /// No description provided for @relayKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Relay access key'**
  String get relayKeyLabel;

  /// No description provided for @deviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get deviceNameLabel;

  /// No description provided for @defaultDeviceNameIos.
  ///
  /// In en, this message translates to:
  /// **'iPhone'**
  String get defaultDeviceNameIos;

  /// No description provided for @defaultDeviceNameAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android gateway'**
  String get defaultDeviceNameAndroid;

  /// No description provided for @discoverySearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for relays on this network…'**
  String get discoverySearching;

  /// No description provided for @discoveryNone.
  ///
  /// In en, this message translates to:
  /// **'No relay found on this network'**
  String get discoveryNone;

  /// No description provided for @discoveryRetry.
  ///
  /// In en, this message translates to:
  /// **'Scan again'**
  String get discoveryRetry;

  /// No description provided for @discoveryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Local relay discovery is unavailable: {details}'**
  String discoveryUnavailable(String details);

  /// No description provided for @roleGateway.
  ///
  /// In en, this message translates to:
  /// **'SIM gateway'**
  String get roleGateway;

  /// No description provided for @roleClient.
  ///
  /// In en, this message translates to:
  /// **'Client only'**
  String get roleClient;

  /// No description provided for @iosClientTitle.
  ///
  /// In en, this message translates to:
  /// **'Client mode on iPhone'**
  String get iosClientTitle;

  /// No description provided for @iosClientBody.
  ///
  /// In en, this message translates to:
  /// **'View activity and send encrypted commands from this phone. An Android phone provides the SIM.'**
  String get iosClientBody;

  /// No description provided for @createBridge.
  ///
  /// In en, this message translates to:
  /// **'Create a bridge'**
  String get createBridge;

  /// No description provided for @scanInvitation.
  ///
  /// In en, this message translates to:
  /// **'Scan invitation'**
  String get scanInvitation;

  /// No description provided for @enterCode.
  ///
  /// In en, this message translates to:
  /// **'Enter code'**
  String get enterCode;

  /// No description provided for @manualJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter invitation'**
  String get manualJoinTitle;

  /// No description provided for @manualJoinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use the details shown on the trusted phone.'**
  String get manualJoinSubtitle;

  /// No description provided for @recoveryCodeFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'52-character recovery code'**
  String get recoveryCodeFieldLabel;

  /// No description provided for @joinBridge.
  ///
  /// In en, this message translates to:
  /// **'Join bridge'**
  String get joinBridge;

  /// No description provided for @pairTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair another phone'**
  String get pairTitle;

  /// No description provided for @pairSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Scan the QR code or enter the details manually.'**
  String get pairSubtitle;

  /// No description provided for @pairMethods.
  ///
  /// In en, this message translates to:
  /// **'QR code or recovery code'**
  String get pairMethods;

  /// No description provided for @recoveryCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Recovery code'**
  String get recoveryCodeLabel;

  /// No description provided for @pairWarning.
  ///
  /// In en, this message translates to:
  /// **'Anyone with these details can decrypt this bridge. Share them only with a phone you trust.'**
  String get pairWarning;

  /// No description provided for @labelCopied.
  ///
  /// In en, this message translates to:
  /// **'{label} copied'**
  String labelCopied(String label);

  /// No description provided for @copyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyTooltip;

  /// No description provided for @tabActivity.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get tabActivity;

  /// No description provided for @tabDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get tabDevices;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @fabNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get fabNew;

  /// No description provided for @pairDeviceTooltip.
  ///
  /// In en, this message translates to:
  /// **'Pair another phone'**
  String get pairDeviceTooltip;

  /// No description provided for @bridgeHealthy.
  ///
  /// In en, this message translates to:
  /// **'Bridge is healthy'**
  String get bridgeHealthy;

  /// No description provided for @bridgeOffline.
  ///
  /// In en, this message translates to:
  /// **'Relay unreachable'**
  String get bridgeOffline;

  /// No description provided for @relayLatency.
  ///
  /// In en, this message translates to:
  /// **'Relay {milliseconds} ms · content stays encrypted'**
  String relayLatency(String milliseconds);

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Trying to reconnect securely…'**
  String get reconnecting;

  /// No description provided for @metricDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get metricDevices;

  /// No description provided for @metricGateway.
  ///
  /// In en, this message translates to:
  /// **'SIM gateway'**
  String get metricGateway;

  /// No description provided for @statusOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get statusOnline;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get statusOffline;

  /// No description provided for @recentActivity.
  ///
  /// In en, this message translates to:
  /// **'Recent activity'**
  String get recentActivity;

  /// No description provided for @eventsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 event} other{{count} events}}'**
  String eventsCount(int count);

  /// No description provided for @emptyActivityTitle.
  ///
  /// In en, this message translates to:
  /// **'Quiet for now'**
  String get emptyActivityTitle;

  /// No description provided for @emptyActivityBody.
  ///
  /// In en, this message translates to:
  /// **'Texts and calls that reach your gateway will appear here.'**
  String get emptyActivityBody;

  /// No description provided for @privateNumber.
  ///
  /// In en, this message translates to:
  /// **'Private number'**
  String get privateNumber;

  /// No description provided for @unknownSender.
  ///
  /// In en, this message translates to:
  /// **'Unknown sender'**
  String get unknownSender;

  /// No description provided for @callIncoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get callIncoming;

  /// No description provided for @callMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed call'**
  String get callMissed;

  /// No description provided for @callDialed.
  ///
  /// In en, this message translates to:
  /// **'Dialed on gateway'**
  String get callDialed;

  /// No description provided for @callActive.
  ///
  /// In en, this message translates to:
  /// **'Call in progress'**
  String get callActive;

  /// No description provided for @callOnHold.
  ///
  /// In en, this message translates to:
  /// **'Call on hold'**
  String get callOnHold;

  /// No description provided for @callEnded.
  ///
  /// In en, this message translates to:
  /// **'Call ended'**
  String get callEnded;

  /// No description provided for @callActivity.
  ///
  /// In en, this message translates to:
  /// **'Call activity'**
  String get callActivity;

  /// No description provided for @declineCall.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get declineCall;

  /// No description provided for @hangUpCall.
  ///
  /// In en, this message translates to:
  /// **'Hang up'**
  String get hangUpCall;

  /// No description provided for @smsStatusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent to carrier'**
  String get smsStatusSent;

  /// No description provided for @smsStatusWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for carrier confirmation'**
  String get smsStatusWaiting;

  /// No description provided for @smsStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed · {reason}'**
  String smsStatusFailed(String reason);

  /// No description provided for @smsFailureDefault.
  ///
  /// In en, this message translates to:
  /// **'The mobile network rejected this message'**
  String get smsFailureDefault;

  /// No description provided for @otpLabel.
  ///
  /// In en, this message translates to:
  /// **'Verification code'**
  String get otpLabel;

  /// No description provided for @otpCopied.
  ///
  /// In en, this message translates to:
  /// **'Verification code copied'**
  String get otpCopied;

  /// No description provided for @notificationOtpTitle.
  ///
  /// In en, this message translates to:
  /// **'Verification code {code}'**
  String notificationOtpTitle(String code);

  /// No description provided for @notificationMessageVia.
  ///
  /// In en, this message translates to:
  /// **'Message via {gateway}'**
  String notificationMessageVia(String gateway);

  /// No description provided for @notificationChannelName.
  ///
  /// In en, this message translates to:
  /// **'Bridged messages'**
  String get notificationChannelName;

  /// No description provided for @notificationChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Incoming messages from your SIM gateway'**
  String get notificationChannelDescription;

  /// No description provided for @composeTitle.
  ///
  /// In en, this message translates to:
  /// **'Use the remote SIM'**
  String get composeTitle;

  /// No description provided for @composeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose what to do with your line.'**
  String get composeSubtitle;

  /// No description provided for @actionSms.
  ///
  /// In en, this message translates to:
  /// **'Send a text'**
  String get actionSms;

  /// No description provided for @actionSmsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted, sent by your gateway'**
  String get actionSmsSubtitle;

  /// No description provided for @actionCall.
  ///
  /// In en, this message translates to:
  /// **'Place a call'**
  String get actionCall;

  /// No description provided for @actionCallSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Dials on the Android gateway — audio stays there'**
  String get actionCallSubtitle;

  /// No description provided for @smsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get smsSheetTitle;

  /// No description provided for @callSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Place a call'**
  String get callSheetTitle;

  /// No description provided for @smsSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sent privately through {gateway} · {sim}.'**
  String smsSheetSubtitle(String gateway, String sim);

  /// No description provided for @callSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Dials with {gateway} · {sim}. Audio stays on the gateway.'**
  String callSheetSubtitle(String gateway, String sim);

  /// No description provided for @phoneNumberLabel.
  ///
  /// In en, this message translates to:
  /// **'Phone number'**
  String get phoneNumberLabel;

  /// No description provided for @messageLabel.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messageLabel;

  /// No description provided for @encryptAndSend.
  ///
  /// In en, this message translates to:
  /// **'Encrypt & send'**
  String get encryptAndSend;

  /// No description provided for @dialOnGateway.
  ///
  /// In en, this message translates to:
  /// **'Dial on gateway'**
  String get dialOnGateway;

  /// No description provided for @queuedSms.
  ///
  /// In en, this message translates to:
  /// **'Encrypted request queued — waiting for carrier confirmation'**
  String get queuedSms;

  /// No description provided for @queuedCall.
  ///
  /// In en, this message translates to:
  /// **'Encrypted dial request queued — waiting for the gateway'**
  String get queuedCall;

  /// No description provided for @chooseSim.
  ///
  /// In en, this message translates to:
  /// **'Choose a SIM'**
  String get chooseSim;

  /// No description provided for @chooseSimSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select the line for this action.'**
  String get chooseSimSubtitle;

  /// No description provided for @defaultLine.
  ///
  /// In en, this message translates to:
  /// **'Default line'**
  String get defaultLine;

  /// No description provided for @simDetailsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'SIM details unavailable'**
  String get simDetailsUnavailable;

  /// No description provided for @unknownCarrier.
  ///
  /// In en, this message translates to:
  /// **'Unknown carrier'**
  String get unknownCarrier;

  /// No description provided for @simSlot.
  ///
  /// In en, this message translates to:
  /// **'Slot {number}'**
  String simSlot(int number);

  /// No description provided for @simNumber.
  ///
  /// In en, this message translates to:
  /// **'SIM {number}'**
  String simNumber(int number);

  /// No description provided for @devicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Your devices'**
  String get devicesTitle;

  /// No description provided for @devicesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Live presence across this bridge'**
  String get devicesSubtitle;

  /// No description provided for @thisPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get thisPhone;

  /// No description provided for @roleClientShort.
  ///
  /// In en, this message translates to:
  /// **'Client'**
  String get roleClientShort;

  /// No description provided for @unnamedPhone.
  ///
  /// In en, this message translates to:
  /// **'Unnamed phone'**
  String get unnamedPhone;

  /// No description provided for @simCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 SIM} other{{count} SIMs}}'**
  String simCount(int count);

  /// No description provided for @onlineNow.
  ///
  /// In en, this message translates to:
  /// **'Online now'**
  String get onlineNow;

  /// No description provided for @seenJustNow.
  ///
  /// In en, this message translates to:
  /// **'Seen just now'**
  String get seenJustNow;

  /// No description provided for @seenMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Seen 1 minute ago} other{Seen {count} minutes ago}}'**
  String seenMinutesAgo(int count);

  /// No description provided for @seenHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Seen 1 hour ago} other{Seen {count} hours ago}}'**
  String seenHoursAgo(int count);

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get timeJustNow;

  /// No description provided for @timeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String timeMinutesAgo(int count);

  /// No description provided for @timeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String timeHoursAgo(int count);

  /// No description provided for @timeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String timeDaysAgo(int count);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsRole.
  ///
  /// In en, this message translates to:
  /// **'Device role'**
  String get settingsRole;

  /// No description provided for @roleGatewayFull.
  ///
  /// In en, this message translates to:
  /// **'Android SIM gateway'**
  String get roleGatewayFull;

  /// No description provided for @roleClientIos.
  ///
  /// In en, this message translates to:
  /// **'iPhone client — the SIM stays on your Android gateway'**
  String get roleClientIos;

  /// No description provided for @settingsRelay.
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get settingsRelay;

  /// No description provided for @settingsEncryption.
  ///
  /// In en, this message translates to:
  /// **'Encryption'**
  String get settingsEncryption;

  /// No description provided for @settingsEncryptionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'AES-256-GCM · 256-bit key from your pairing'**
  String get settingsEncryptionSubtitle;

  /// No description provided for @settingsCallControl.
  ///
  /// In en, this message translates to:
  /// **'Remote call control'**
  String get settingsCallControl;

  /// No description provided for @callControlReady.
  ///
  /// In en, this message translates to:
  /// **'Decline and hang up from any phone'**
  String get callControlReady;

  /// No description provided for @callControlNeedsRole.
  ///
  /// In en, this message translates to:
  /// **'Requires the Android phone role'**
  String get callControlNeedsRole;

  /// No description provided for @settingsSims.
  ///
  /// In en, this message translates to:
  /// **'Active SIMs'**
  String get settingsSims;

  /// No description provided for @noActiveSim.
  ///
  /// In en, this message translates to:
  /// **'No active SIM detected'**
  String get noActiveSim;

  /// No description provided for @leaveBridge.
  ///
  /// In en, this message translates to:
  /// **'Leave bridge'**
  String get leaveBridge;

  /// No description provided for @leaveBridgeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Removes the keys and session from this phone'**
  String get leaveBridgeSubtitle;

  /// No description provided for @leaveBridgeTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave this bridge?'**
  String get leaveBridgeTitle;

  /// No description provided for @leaveBridgeWarning.
  ///
  /// In en, this message translates to:
  /// **'This phone\'s copy of the bridge key is erased. To use the bridge again you must pair it from another phone in the bridge, so do this only if you have one to hand.'**
  String get leaveBridgeWarning;

  /// No description provided for @leaveBridgeGatewayWarning.
  ///
  /// In en, this message translates to:
  /// **'This phone provides the SIM. After leaving, your other phones lose access to it until you pair again.'**
  String get leaveBridgeGatewayWarning;

  /// No description provided for @leaveBridgeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Leave and erase keys'**
  String get leaveBridgeConfirm;

  /// No description provided for @callAudioNote.
  ///
  /// In en, this message translates to:
  /// **'Call audio stays on the Android gateway. Sim Bridge shows call activity and can start or end calls, but mobile platforms do not expose cellular audio to apps.'**
  String get callAudioNote;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @removeDevice.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeDevice;

  /// No description provided for @removeDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String removeDeviceTitle(String name);

  /// No description provided for @removeDeviceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'That phone loses access to this bridge straight away.'**
  String get removeDeviceSubtitle;

  /// No description provided for @removeDeviceKeyWarning.
  ///
  /// In en, this message translates to:
  /// **'It still holds a copy of the bridge key, so it can read messages it already downloaded. To cut it off completely, create a new bridge and pair your phones again.'**
  String get removeDeviceKeyWarning;

  /// No description provided for @removeDeviceGatewayWarning.
  ///
  /// In en, this message translates to:
  /// **'This phone provides the SIM. Removing it also deletes the message history it sent to this bridge.'**
  String get removeDeviceGatewayWarning;

  /// No description provided for @removeDeviceRejoinWarning.
  ///
  /// In en, this message translates to:
  /// **'This bridge is open to new devices, so the removed phone could rejoin with the recovery code. Close enrollment below to prevent that.'**
  String get removeDeviceRejoinWarning;

  /// No description provided for @removeDeviceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this phone'**
  String get removeDeviceConfirm;

  /// No description provided for @deviceRemoved.
  ///
  /// In en, this message translates to:
  /// **'{name} was removed'**
  String deviceRemoved(String name);

  /// No description provided for @ownerBadge.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get ownerBadge;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @notificationsAllowed.
  ///
  /// In en, this message translates to:
  /// **'Allowed — codes and messages will alert you'**
  String get notificationsAllowed;

  /// No description provided for @notificationsBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked — allow notifications in system settings'**
  String get notificationsBlocked;

  /// No description provided for @notificationsUnknown.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications to see new messages'**
  String get notificationsUnknown;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get openSettings;

  /// No description provided for @testCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Test a verification code'**
  String get testCodeTitle;

  /// No description provided for @testCodeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notify this phone with a fake code, nothing is sent'**
  String get testCodeSubtitle;

  /// No description provided for @testCodeSent.
  ///
  /// In en, this message translates to:
  /// **'Test code {code} sent. Try a keyboard suggestion or paste it into a code field.'**
  String testCodeSent(String code);

  /// No description provided for @testMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Send a test message to your phones'**
  String get testMessageTitle;

  /// No description provided for @testMessageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A simulated incoming SMS, encrypted through the relay'**
  String get testMessageSubtitle;

  /// No description provided for @testMessageSent.
  ///
  /// In en, this message translates to:
  /// **'Test message with code {code} sent to your other phones.'**
  String testMessageSent(String code);

  /// No description provided for @testSender.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge test'**
  String get testSender;

  /// No description provided for @testCodeBody.
  ///
  /// In en, this message translates to:
  /// **'Your Sim Bridge verification code is {code}'**
  String testCodeBody(String code);

  /// No description provided for @testNotificationsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications for Sim Bridge first, then try again.'**
  String get testNotificationsUnavailable;

  /// No description provided for @simulatedBadge.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get simulatedBadge;

  /// No description provided for @settingsAutoCopy.
  ///
  /// In en, this message translates to:
  /// **'Verification codes'**
  String get settingsAutoCopy;

  /// No description provided for @autoCopyOn.
  ///
  /// In en, this message translates to:
  /// **'Copied automatically, ready to paste'**
  String get autoCopyOn;

  /// No description provided for @autoCopyOff.
  ///
  /// In en, this message translates to:
  /// **'Copy them yourself from the message'**
  String get autoCopyOff;

  /// No description provided for @settingsEnrollment.
  ///
  /// In en, this message translates to:
  /// **'New devices'**
  String get settingsEnrollment;

  /// No description provided for @enrollmentOpen.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the recovery code can join'**
  String get enrollmentOpen;

  /// No description provided for @enrollmentClosed.
  ///
  /// In en, this message translates to:
  /// **'Closed — no phone can join'**
  String get enrollmentClosed;

  /// No description provided for @enrollmentOpened.
  ///
  /// In en, this message translates to:
  /// **'This bridge now accepts new devices'**
  String get enrollmentOpened;

  /// No description provided for @enrollmentClosed2.
  ///
  /// In en, this message translates to:
  /// **'This bridge no longer accepts new devices'**
  String get enrollmentClosed2;

  /// No description provided for @ownerOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Only {name} can remove phones or change this.'**
  String ownerOnlyHint(String name);

  /// No description provided for @confirmJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'Join this bridge?'**
  String get confirmJoinTitle;

  /// No description provided for @confirmJoinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Check these details before your phone connects.'**
  String get confirmJoinSubtitle;

  /// No description provided for @confirmJoinGatewayWarning.
  ///
  /// In en, this message translates to:
  /// **'This phone will share its SIM: texts and call activity will be encrypted and sent to the relay above. Continue only if you set up that relay yourself.'**
  String get confirmJoinGatewayWarning;

  /// No description provided for @confirmJoinClientNote.
  ///
  /// In en, this message translates to:
  /// **'This phone will read activity from the bridge. Continue only if you recognise the relay above.'**
  String get confirmJoinClientNote;

  /// No description provided for @errorInvalidInvitation.
  ///
  /// In en, this message translates to:
  /// **'That invitation could not be read. Ask for a fresh QR code.'**
  String get errorInvalidInvitation;

  /// No description provided for @errorInvalidRecoveryCode.
  ///
  /// In en, this message translates to:
  /// **'That recovery code is not valid. Check all 52 characters and try again.'**
  String get errorInvalidRecoveryCode;

  /// No description provided for @errorInsecureRelay.
  ///
  /// In en, this message translates to:
  /// **'A relay outside your local network must use https.'**
  String get errorInsecureRelay;

  /// No description provided for @errorSmsFields.
  ///
  /// In en, this message translates to:
  /// **'Enter a phone number and a message'**
  String get errorSmsFields;

  /// No description provided for @errorPhoneField.
  ///
  /// In en, this message translates to:
  /// **'Enter a phone number'**
  String get errorPhoneField;

  /// No description provided for @errorNoGateway.
  ///
  /// In en, this message translates to:
  /// **'No Android gateway is connected'**
  String get errorNoGateway;

  /// No description provided for @errorCallGateway.
  ///
  /// In en, this message translates to:
  /// **'The gateway for this call is unavailable'**
  String get errorCallGateway;

  /// No description provided for @scanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan invitation'**
  String get scanTitle;

  /// No description provided for @scanHint.
  ///
  /// In en, this message translates to:
  /// **'Point this phone at the QR code on a trusted device.'**
  String get scanHint;

  /// No description provided for @testCodeKeyboardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Generate a test code, then try a keyboard suggestion or paste it here.'**
  String get testCodeKeyboardSubtitle;

  /// No description provided for @verificationCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Verification code'**
  String get verificationCodeLabel;

  /// No description provided for @sendTestCode.
  ///
  /// In en, this message translates to:
  /// **'Send test code'**
  String get sendTestCode;

  /// No description provided for @gatewayRuntimeTitle.
  ///
  /// In en, this message translates to:
  /// **'Background gateway'**
  String get gatewayRuntimeTitle;

  /// No description provided for @gatewayRuntimeRunning.
  ///
  /// In en, this message translates to:
  /// **'Running · relay connected'**
  String get gatewayRuntimeRunning;

  /// No description provided for @gatewayRuntimeWaiting.
  ///
  /// In en, this message translates to:
  /// **'Running · waiting to reconnect. Messages stay queued.'**
  String get gatewayRuntimeWaiting;

  /// No description provided for @gatewayRuntimeStopped.
  ///
  /// In en, this message translates to:
  /// **'Background runtime is stopped. Use Restart gateway below.'**
  String get gatewayRuntimeStopped;

  /// No description provided for @gatewayRuntimeUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Pairing credentials were rejected. Messages stay queued.'**
  String get gatewayRuntimeUnauthorized;

  /// No description provided for @gatewayRuntimePermissions.
  ///
  /// In en, this message translates to:
  /// **'Required phone permissions are missing. Messages stay queued.'**
  String get gatewayRuntimePermissions;

  /// No description provided for @gatewayBatteryTitle.
  ///
  /// In en, this message translates to:
  /// **'Battery settings'**
  String get gatewayBatteryTitle;

  /// No description provided for @gatewayBatteryUnrestricted.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization is off. Android can still stop the app.'**
  String get gatewayBatteryUnrestricted;

  /// No description provided for @gatewayBatteryRestricted.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization may delay syncing. Review background restrictions.'**
  String get gatewayBatteryRestricted;

  /// No description provided for @gatewayStopFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not stop the gateway safely. Pairing and queued messages were kept. Try again.'**
  String get gatewayStopFailed;

  /// No description provided for @commandOutcomeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Outcome unknown · not retried automatically'**
  String get commandOutcomeUnknown;

  /// No description provided for @testMessageQueued.
  ///
  /// In en, this message translates to:
  /// **'Test message with code {code} queued. It will upload when the gateway connects.'**
  String testMessageQueued(String code);

  /// No description provided for @pairingUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Stored pairing could not be opened. Unlock the phone and reopen the app. Existing pairing data has been kept.'**
  String get pairingUnavailable;

  /// No description provided for @gatewayClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not finish clearing this phone. Try again.'**
  String get gatewayClearFailed;

  /// No description provided for @gatewayRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart gateway'**
  String get gatewayRestart;

  /// No description provided for @gatewayRestartDescription.
  ///
  /// In en, this message translates to:
  /// **'Restart after the previous worker has stopped. Pairing and queued messages are kept.'**
  String get gatewayRestartDescription;

  /// No description provided for @gatewayNotSynced.
  ///
  /// In en, this message translates to:
  /// **'Not yet'**
  String get gatewayNotSynced;

  /// No description provided for @gatewayRuntimeDetails.
  ///
  /// In en, this message translates to:
  /// **'{status}\nQueued: {pending} · Last sync: {time}'**
  String gatewayRuntimeDetails(String status, int pending, String time);

  /// No description provided for @gatewayAutostartTitle.
  ///
  /// In en, this message translates to:
  /// **'Background autostart'**
  String get gatewayAutostartTitle;

  /// No description provided for @gatewayAutostartDescription.
  ///
  /// In en, this message translates to:
  /// **'Enable Sim Bridge in your device’s system settings. This app cannot confirm that setting.'**
  String get gatewayAutostartDescription;

  /// No description provided for @gatewaySettingsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'System settings could not be opened. Open this app’s settings manually.'**
  String get gatewaySettingsUnavailable;

  /// No description provided for @gatewayChecksTitle.
  ///
  /// In en, this message translates to:
  /// **'Gateway checks'**
  String get gatewayChecksTitle;

  /// No description provided for @gatewayNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Gateway needs attention'**
  String get gatewayNeedsAttention;

  /// No description provided for @gatewayReviewSetup.
  ///
  /// In en, this message translates to:
  /// **'Review setup'**
  String get gatewayReviewSetup;

  /// No description provided for @gatewayCheckedNow.
  ///
  /// In en, this message translates to:
  /// **'Checked just now'**
  String get gatewayCheckedNow;

  /// No description provided for @gatewayNotChecked.
  ///
  /// In en, this message translates to:
  /// **'Not checked'**
  String get gatewayNotChecked;

  /// No description provided for @gatewayChecksSubtitle.
  ///
  /// In en, this message translates to:
  /// **'These checks show current device settings. Android can still restrict background activity.'**
  String get gatewayChecksSubtitle;

  /// No description provided for @gatewayCheckReceive.
  ///
  /// In en, this message translates to:
  /// **'Receive SMS'**
  String get gatewayCheckReceive;

  /// No description provided for @gatewayCheckSend.
  ///
  /// In en, this message translates to:
  /// **'Send SMS'**
  String get gatewayCheckSend;

  /// No description provided for @gatewayCheckSim.
  ///
  /// In en, this message translates to:
  /// **'SIM access'**
  String get gatewayCheckSim;

  /// No description provided for @gatewayPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Permission granted'**
  String get gatewayPermissionGranted;

  /// No description provided for @gatewayReceiveMissing.
  ///
  /// In en, this message translates to:
  /// **'Incoming SMS permission is missing. New SMS cannot be captured.'**
  String get gatewayReceiveMissing;

  /// No description provided for @gatewaySendMissing.
  ///
  /// In en, this message translates to:
  /// **'SMS sending permission is missing. Remote SMS cannot be sent.'**
  String get gatewaySendMissing;

  /// No description provided for @gatewaySimMissing.
  ///
  /// In en, this message translates to:
  /// **'Phone state permission is missing. SIM access is unavailable.'**
  String get gatewaySimMissing;

  /// No description provided for @gatewayAllowPermissions.
  ///
  /// In en, this message translates to:
  /// **'Allow permissions'**
  String get gatewayAllowPermissions;

  /// No description provided for @gatewayOpenPermissions.
  ///
  /// In en, this message translates to:
  /// **'Open app permissions'**
  String get gatewayOpenPermissions;

  /// No description provided for @gatewayCheckBackground.
  ///
  /// In en, this message translates to:
  /// **'Background activity'**
  String get gatewayCheckBackground;

  /// No description provided for @gatewayBackgroundAllowed.
  ///
  /// In en, this message translates to:
  /// **'No system background restriction detected'**
  String get gatewayBackgroundAllowed;

  /// No description provided for @gatewayBackgroundRestricted.
  ///
  /// In en, this message translates to:
  /// **'Background activity is restricted. Review this app’s system settings.'**
  String get gatewayBackgroundRestricted;

  /// No description provided for @gatewayNotificationsVisible.
  ///
  /// In en, this message translates to:
  /// **'Gateway notifications are visible'**
  String get gatewayNotificationsVisible;

  /// No description provided for @gatewayNotificationsHidden.
  ///
  /// In en, this message translates to:
  /// **'Gateway notifications are hidden. The worker may still run, but its status is not visible.'**
  String get gatewayNotificationsHidden;

  /// No description provided for @gatewayAutostartPending.
  ///
  /// In en, this message translates to:
  /// **'Check the device’s autostart setting and enable Sim Bridge. The app cannot read this switch.'**
  String get gatewayAutostartPending;

  /// No description provided for @gatewayAutostartManual.
  ///
  /// In en, this message translates to:
  /// **'Confirmed by you · Not checked by the app'**
  String get gatewayAutostartManual;

  /// No description provided for @gatewayOpenAutostart.
  ///
  /// In en, this message translates to:
  /// **'Open autostart settings'**
  String get gatewayOpenAutostart;

  /// No description provided for @gatewayConfirmAutostart.
  ///
  /// In en, this message translates to:
  /// **'I enabled autostart'**
  String get gatewayConfirmAutostart;

  /// No description provided for @gatewayCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get gatewayCheckAgain;

  /// No description provided for @gatewayCheckActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update gateway setup. Try again.'**
  String get gatewayCheckActionFailed;

  /// No description provided for @gatewayRelayConnected.
  ///
  /// In en, this message translates to:
  /// **'Relay connected'**
  String get gatewayRelayConnected;

  /// No description provided for @gatewayQueuedWarning.
  ///
  /// In en, this message translates to:
  /// **'{count} events are waiting to upload.'**
  String gatewayQueuedWarning(int count);

  /// No description provided for @gatewayRuntimeUnpaired.
  ///
  /// In en, this message translates to:
  /// **'Local pairing is unavailable. Unlock this phone and review its pairing settings. Stored data has been kept.'**
  String get gatewayRuntimeUnpaired;

  /// No description provided for @gatewayReviewPairing.
  ///
  /// In en, this message translates to:
  /// **'Review pairing settings'**
  String get gatewayReviewPairing;

  /// No description provided for @defaultDeviceNameMac.
  ///
  /// In en, this message translates to:
  /// **'My Mac'**
  String get defaultDeviceNameMac;

  /// No description provided for @defaultDeviceNameWindows.
  ///
  /// In en, this message translates to:
  /// **'My Windows PC'**
  String get defaultDeviceNameWindows;

  /// No description provided for @defaultDeviceNameLinux.
  ///
  /// In en, this message translates to:
  /// **'My Linux PC'**
  String get defaultDeviceNameLinux;

  /// No description provided for @desktopClientTitle.
  ///
  /// In en, this message translates to:
  /// **'A client on your computer'**
  String get desktopClientTitle;

  /// No description provided for @desktopClientBody.
  ///
  /// In en, this message translates to:
  /// **'Read messages, copy verification codes, and send SMS or call requests through your paired Android gateway. This computer cannot share a SIM.'**
  String get desktopClientBody;

  /// No description provided for @desktopOnboardingHeadline.
  ///
  /// In en, this message translates to:
  /// **'Your SIM.\nOn your computer.'**
  String get desktopOnboardingHeadline;

  /// No description provided for @desktopOnboardingTagline.
  ///
  /// In en, this message translates to:
  /// **'Keep your Android SIM connected and bring its messages and verification codes to your desk. Only your paired devices can read them.'**
  String get desktopOnboardingTagline;

  /// No description provided for @desktopSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Join your existing bridge using its relay URL and recovery code. Create a new bridge on its Android SIM gateway first.'**
  String get desktopSetupSubtitle;

  /// No description provided for @desktopAvailabilityTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep Sim Bridge open'**
  String get desktopAvailabilityTitle;

  /// No description provided for @desktopAvailabilityBody.
  ///
  /// In en, this message translates to:
  /// **'Sync and notifications work while the app is running, including when minimized. They pause when you quit the app or your computer sleeps. There is no desktop background service or remote push.'**
  String get desktopAvailabilityBody;

  /// No description provided for @desktopRole.
  ///
  /// In en, this message translates to:
  /// **'Desktop client · Android gateway required'**
  String get desktopRole;

  /// No description provided for @desktopThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get desktopThisDevice;

  /// No description provided for @desktopClipboardBody.
  ///
  /// In en, this message translates to:
  /// **'Automatic copying is optional and off by default. Windows and Linux use the system clipboard without automatic expiry; clipboard history or other apps may retain codes.'**
  String get desktopClipboardBody;

  /// No description provided for @desktopNotificationsUnknown.
  ///
  /// In en, this message translates to:
  /// **'System notification permission cannot be checked here. Try a test notification and review your system notification settings.'**
  String get desktopNotificationsUnknown;

  /// No description provided for @desktopNotificationsAvailable.
  ///
  /// In en, this message translates to:
  /// **'Connected to the system notification service. Whether alerts are shown depends on your system settings.'**
  String get desktopNotificationsAvailable;

  /// No description provided for @desktopNotificationAction.
  ///
  /// In en, this message translates to:
  /// **'Open Sim Bridge'**
  String get desktopNotificationAction;

  /// No description provided for @desktopNotificationSettingsHelp.
  ///
  /// In en, this message translates to:
  /// **'Review Sim Bridge in your system notification settings.'**
  String get desktopNotificationSettingsHelp;

  /// No description provided for @desktopCodeTestSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show a local test alert. Copies a code only when automatic copying is enabled.'**
  String get desktopCodeTestSubtitle;

  /// No description provided for @desktopSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up this computer'**
  String get desktopSetupTitle;

  /// No description provided for @desktopTrustKeys.
  ///
  /// In en, this message translates to:
  /// **'Keys stay on your devices'**
  String get desktopTrustKeys;

  /// No description provided for @desktopPairTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair another device'**
  String get desktopPairTitle;

  /// No description provided for @desktopPairWarning.
  ///
  /// In en, this message translates to:
  /// **'Anyone with these details can decrypt this bridge. Share them only with a device you trust.'**
  String get desktopPairWarning;

  /// No description provided for @desktopManualJoinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use the details shown on a trusted paired device.'**
  String get desktopManualJoinSubtitle;

  /// No description provided for @desktopConfirmJoinSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Check these details before your computer connects.'**
  String get desktopConfirmJoinSubtitle;

  /// No description provided for @desktopConfirmJoinClientNote.
  ///
  /// In en, this message translates to:
  /// **'This computer will read activity from the bridge. Continue only if you recognise the relay above.'**
  String get desktopConfirmJoinClientNote;

  /// No description provided for @desktopLeaveBridgeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Removes the keys and session from this computer'**
  String get desktopLeaveBridgeSubtitle;

  /// No description provided for @desktopLeaveBridgeWarning.
  ///
  /// In en, this message translates to:
  /// **'This computer’s copy of the bridge key is erased. To join again, use the recovery details from another paired device.'**
  String get desktopLeaveBridgeWarning;

  /// No description provided for @desktopPairingUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Stored pairing could not be opened. Unlock your computer or credential store and reopen the app. Existing pairing data has been kept.'**
  String get desktopPairingUnavailable;

  /// No description provided for @desktopUnnamedDevice.
  ///
  /// In en, this message translates to:
  /// **'Unnamed device'**
  String get desktopUnnamedDevice;

  /// No description provided for @pairingRecoveryWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the Android gateway to restore secure pairing. Your keys and local history are preserved.'**
  String get pairingRecoveryWaiting;

  /// No description provided for @pairingLegacyMigration.
  ///
  /// In en, this message translates to:
  /// **'This pairing needs an operator-approved upgrade. Your credentials and gateway journal are preserved.'**
  String get pairingLegacyMigration;

  /// No description provided for @gatewayCreationRequired.
  ///
  /// In en, this message translates to:
  /// **'Create the bridge on its Android SIM gateway, then pair this device.'**
  String get gatewayCreationRequired;

  /// No description provided for @pairExistingBridge.
  ///
  /// In en, this message translates to:
  /// **'Pair an existing bridge'**
  String get pairExistingBridge;

  /// No description provided for @leavePolicyPending.
  ///
  /// In en, this message translates to:
  /// **'Removal is not confirmed. Keep the Android gateway connected and try again; your credentials and journal are preserved.'**
  String get leavePolicyPending;

  /// No description provided for @operatorRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Operator pairing recovery'**
  String get operatorRecoveryTitle;

  /// No description provided for @operatorRecoveryBody.
  ///
  /// In en, this message translates to:
  /// **'Send these public identity details to your relay operator. Paste their certificate and, for the Android authority gateway, its approved policy. Existing keys, IDs and journals stay on this device.'**
  String get operatorRecoveryBody;

  /// No description provided for @operatorRecoveryCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy public identity'**
  String get operatorRecoveryCopy;

  /// No description provided for @operatorRecoveryCertificate.
  ///
  /// In en, this message translates to:
  /// **'Operator-issued certificate'**
  String get operatorRecoveryCertificate;

  /// No description provided for @operatorRecoveryPolicy.
  ///
  /// In en, this message translates to:
  /// **'Gateway policy JSON'**
  String get operatorRecoveryPolicy;

  /// No description provided for @operatorRecoveryApply.
  ///
  /// In en, this message translates to:
  /// **'Apply approved recovery'**
  String get operatorRecoveryApply;

  /// No description provided for @operatorRecoverySummary.
  ///
  /// In en, this message translates to:
  /// **'Upgrade an existing pairing after operator approval'**
  String get operatorRecoverySummary;

  /// No description provided for @operatorRecoveryRejected.
  ///
  /// In en, this message translates to:
  /// **'Recovery was not accepted. Check the operator-issued certificate and policy; existing credentials are preserved.'**
  String get operatorRecoveryRejected;

  /// No description provided for @operatorPrivateVerifier.
  ///
  /// In en, this message translates to:
  /// **'Copy private enrollment verifier'**
  String get operatorPrivateVerifier;

  /// No description provided for @operatorPrivateVerifierWarning.
  ///
  /// In en, this message translates to:
  /// **'This verifier can authorize enrollment when the operator opens the bridge. Share it only with your trusted relay operator. Encryption keys, device tokens and signing seeds are excluded.'**
  String get operatorPrivateVerifierWarning;

  /// No description provided for @operatorIdentityPending.
  ///
  /// In en, this message translates to:
  /// **'The gateway has not prepared its protected signing identity yet. Keep the gateway service available and try again. No new key was created by this screen.'**
  String get operatorIdentityPending;

  /// No description provided for @authorityRemovalWarning.
  ///
  /// In en, this message translates to:
  /// **'Removing this authority gateway permanently deactivates the entire bridge. Every paired device loses access.'**
  String get authorityRemovalWarning;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the relay. Check the address and your connection, then try again.'**
  String get errorRelayUnreachable;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The relay no longer accepts this device. Pair it again from your gateway.'**
  String get errorRelayUnauthorized;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The relay refused this request.'**
  String get errorRelayRefused;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The relay does not know this bridge. Check the relay address.'**
  String get errorRelayNotFound;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The Android gateway has to confirm this first. Keep it online and try again.'**
  String get errorGatewayBusy;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a minute and try again.'**
  String get errorRelayBusy;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The relay could not complete the request. Try again later.'**
  String get errorRelayFailure;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'The relay sent an unexpected response. Check that the address points to a Sim Bridge relay.'**
  String get errorRelayResponse;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge needs a permission for this. Allow it in the system settings.'**
  String get errorPermissionDenied;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'This device could not complete the action. Try again.'**
  String get errorDeviceAction;

  /// User-facing message for a failed relay, network or device operation.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Try again.'**
  String get errorUnexpected;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updatesTitle;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String updatesCurrentVersion(String version);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available'**
  String updatesAvailableSubtitle(String version);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get updatesChecking;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge {version} is up to date'**
  String updatesUpToDate(String version);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates. Check your connection and try again.'**
  String get updatesCheckFailed;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically'**
  String get updatesAutomatic;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Once a day, from the Sim Bridge releases on GitHub'**
  String get updatesAutomaticSubtitle;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge {version} is available'**
  String updatesAvailableTitle(String version);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge downloads and verifies the update, closes, installs it and starts again. Your pairing and settings are kept.'**
  String get updatesInstallBody;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge downloads and verifies the new version and saves it in your Downloads folder. Then quit Sim Bridge and replace it with the new version. Your pairing and settings are kept.'**
  String get updatesDownloadBody;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Install and restart'**
  String get updatesInstall;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get updatesDownload;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updatesLater;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Release notes'**
  String get updatesReleaseNotes;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Downloading and verifying the update…'**
  String get updatesDownloading;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Saved {file} in your Downloads folder'**
  String updatesDownloaded(String file);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'The update could not be downloaded or verified. Try again later.'**
  String get updatesFailed;

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Sim Bridge {version} is available'**
  String updatesNotice(String version);

  /// Desktop in-app update text.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updatesShow;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'About Sim Bridge'**
  String get aboutTitle;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'About, updates and licenses'**
  String get aboutTooltip;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Your Android SMS and verification codes on every device, end-to-end encrypted, through a relay you run yourself.'**
  String get aboutTagline;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Free and open source under the MIT License.'**
  String get aboutLegalese;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Website'**
  String get aboutWebsite;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Source code'**
  String get aboutSource;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get aboutPrivacy;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Licenses'**
  String get aboutLicenses;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updatesCheckNow;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Updates are managed by the renner.dev launcher'**
  String get updatesManaged;

  /// About screen and update text.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
