// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get relayPairingExpired =>
      'Dieses Gerät ist vom Gateway nicht mehr autorisiert. Schlüssel und lokaler Verlauf bleiben erhalten. Verwende die Betreiber-Wiederherstellung nur nach dessen Freigabe.';

  @override
  String get relayEventReconnecting =>
      'Verbindung zum Relay-Ereignisstream wird wiederhergestellt…';

  @override
  String get appTitle => 'Sim Bridge';

  @override
  String get onboardingHeadline => 'Eine SIM.\nJedes Telefon.';

  @override
  String get onboardingTagline =>
      'SMS, Bestätigungscodes und Anrufe deiner SIM auf jedem deiner Telefone. Ende-zu-Ende-verschlüsselt — das Relay kann nichts davon lesen.';

  @override
  String get trustEncrypted => 'Ende-zu-Ende-verschlüsselt';

  @override
  String get trustKeysLocal => 'Schlüssel bleiben auf deinen Telefonen';

  @override
  String get setupTitle => 'Dieses Telefon einrichten';

  @override
  String get setupSubtitle =>
      'Verbinde dich mit deinem privaten Relay, um zu starten.';

  @override
  String get relayUrlLabel => 'Relay-URL';

  @override
  String get relayKeyLabel => 'Relay-Zugangsschlüssel';

  @override
  String get deviceNameLabel => 'Gerätename';

  @override
  String get defaultDeviceNameIos => 'iPhone';

  @override
  String get defaultDeviceNameAndroid => 'Android-Gateway';

  @override
  String get discoverySearching => 'Suche nach Relays in diesem Netzwerk…';

  @override
  String get discoveryNone => 'Kein Relay in diesem Netzwerk gefunden';

  @override
  String get discoveryRetry => 'Erneut suchen';

  @override
  String discoveryUnavailable(String details) {
    return 'Lokale Relay-Suche nicht verfügbar: $details';
  }

  @override
  String get roleGateway => 'SIM-Gateway';

  @override
  String get roleClient => 'Nur Client';

  @override
  String get iosClientTitle => 'Client-Modus auf dem iPhone';

  @override
  String get iosClientBody =>
      'Sieh Aktivitäten ein und sende verschlüsselte Befehle von diesem Telefon. Ein Android-Telefon stellt die SIM bereit.';

  @override
  String get createBridge => 'Bridge erstellen';

  @override
  String get scanInvitation => 'Einladung scannen';

  @override
  String get enterCode => 'Code eingeben';

  @override
  String get manualJoinTitle => 'Einladung eingeben';

  @override
  String get manualJoinSubtitle =>
      'Verwende die Angaben vom vertrauenswürdigen Telefon.';

  @override
  String get recoveryCodeFieldLabel => '52-stelliger Wiederherstellungscode';

  @override
  String get joinBridge => 'Bridge beitreten';

  @override
  String get pairTitle => 'Weiteres Telefon koppeln';

  @override
  String get pairSubtitle =>
      'Scanne den QR-Code oder gib die Angaben manuell ein.';

  @override
  String get pairMethods => 'QR-Code oder Wiederherstellungscode';

  @override
  String get recoveryCodeLabel => 'Wiederherstellungscode';

  @override
  String get pairWarning =>
      'Wer diese Angaben besitzt, kann diese Bridge entschlüsseln. Teile sie nur mit einem Telefon, dem du vertraust.';

  @override
  String labelCopied(String label) {
    return '$label kopiert';
  }

  @override
  String get copyTooltip => 'Kopieren';

  @override
  String get tabActivity => 'Aktivität';

  @override
  String get tabDevices => 'Geräte';

  @override
  String get tabSettings => 'Einstellungen';

  @override
  String get fabNew => 'Neu';

  @override
  String get pairDeviceTooltip => 'Weiteres Telefon koppeln';

  @override
  String get bridgeHealthy => 'Bridge ist gesund';

  @override
  String get bridgeOffline => 'Relay nicht erreichbar';

  @override
  String relayLatency(String milliseconds) {
    return 'Relay $milliseconds ms · Inhalte bleiben verschlüsselt';
  }

  @override
  String get reconnecting => 'Sichere Verbindung wird wiederhergestellt…';

  @override
  String get metricDevices => 'Geräte';

  @override
  String get metricGateway => 'SIM-Gateway';

  @override
  String get statusOnline => 'Online';

  @override
  String get statusOffline => 'Offline';

  @override
  String get recentActivity => 'Letzte Aktivität';

  @override
  String eventsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Ereignisse',
      one: '1 Ereignis',
    );
    return '$_temp0';
  }

  @override
  String get emptyActivityTitle => 'Gerade ist es ruhig';

  @override
  String get emptyActivityBody =>
      'SMS und Anrufe, die dein Gateway erreichen, erscheinen hier.';

  @override
  String get privateNumber => 'Private Nummer';

  @override
  String get unknownSender => 'Unbekannter Absender';

  @override
  String get callIncoming => 'Eingehender Anruf';

  @override
  String get callMissed => 'Verpasster Anruf';

  @override
  String get callDialed => 'Auf dem Gateway gewählt';

  @override
  String get callActive => 'Anruf läuft';

  @override
  String get callOnHold => 'Anruf gehalten';

  @override
  String get callEnded => 'Anruf beendet';

  @override
  String get callActivity => 'Anrufaktivität';

  @override
  String get declineCall => 'Ablehnen';

  @override
  String get hangUpCall => 'Auflegen';

  @override
  String get smsStatusSent => 'An Mobilfunknetz übergeben';

  @override
  String get smsStatusWaiting => 'Warte auf Bestätigung des Mobilfunknetzes';

  @override
  String smsStatusFailed(String reason) {
    return 'Fehlgeschlagen · $reason';
  }

  @override
  String get smsFailureDefault =>
      'Das Mobilfunknetz hat diese Nachricht abgelehnt';

  @override
  String get otpLabel => 'Bestätigungscode';

  @override
  String get otpCopied => 'Bestätigungscode kopiert';

  @override
  String notificationOtpTitle(String code) {
    return 'Bestätigungscode $code';
  }

  @override
  String notificationMessageVia(String gateway) {
    return 'Nachricht über $gateway';
  }

  @override
  String get notificationChannelName => 'Überbrückte Nachrichten';

  @override
  String get notificationChannelDescription =>
      'Eingehende Nachrichten von deinem SIM-Gateway';

  @override
  String get composeTitle => 'Entfernte SIM verwenden';

  @override
  String get composeSubtitle =>
      'Wähle, was du mit deiner Leitung tun möchtest.';

  @override
  String get actionSms => 'SMS senden';

  @override
  String get actionSmsSubtitle =>
      'Ende-zu-Ende-verschlüsselt, gesendet von deinem Gateway';

  @override
  String get actionCall => 'Anruf starten';

  @override
  String get actionCallSubtitle =>
      'Wählt auf dem Android-Gateway — der Ton bleibt dort';

  @override
  String get smsSheetTitle => 'Neue Nachricht';

  @override
  String get callSheetTitle => 'Anruf starten';

  @override
  String smsSheetSubtitle(String gateway, String sim) {
    return 'Privat gesendet über $gateway · $sim.';
  }

  @override
  String callSheetSubtitle(String gateway, String sim) {
    return 'Wählt mit $gateway · $sim. Der Ton bleibt auf dem Gateway.';
  }

  @override
  String get phoneNumberLabel => 'Telefonnummer';

  @override
  String get messageLabel => 'Nachricht';

  @override
  String get encryptAndSend => 'Verschlüsseln & senden';

  @override
  String get dialOnGateway => 'Auf Gateway wählen';

  @override
  String get queuedSms =>
      'Verschlüsselte Anfrage eingereiht — warte auf Bestätigung des Mobilfunknetzes';

  @override
  String get queuedCall =>
      'Verschlüsselte Wählanfrage eingereiht — warte auf das Gateway';

  @override
  String get chooseSim => 'SIM auswählen';

  @override
  String get chooseSimSubtitle => 'Wähle die Leitung für diese Aktion.';

  @override
  String get defaultLine => 'Standardleitung';

  @override
  String get simDetailsUnavailable => 'SIM-Details nicht verfügbar';

  @override
  String get unknownCarrier => 'Unbekannter Anbieter';

  @override
  String simSlot(int number) {
    return 'Steckplatz $number';
  }

  @override
  String simNumber(int number) {
    return 'SIM $number';
  }

  @override
  String get devicesTitle => 'Deine Geräte';

  @override
  String get devicesSubtitle => 'Live-Präsenz in dieser Bridge';

  @override
  String get thisPhone => 'Dieses Telefon';

  @override
  String get roleClientShort => 'Client';

  @override
  String get unnamedPhone => 'Unbenanntes Telefon';

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
  String get onlineNow => 'Jetzt online';

  @override
  String get seenJustNow => 'Gerade eben gesehen';

  @override
  String seenMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Vor $count Minuten gesehen',
      one: 'Vor 1 Minute gesehen',
    );
    return '$_temp0';
  }

  @override
  String seenHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Vor $count Stunden gesehen',
      one: 'Vor 1 Stunde gesehen',
    );
    return '$_temp0';
  }

  @override
  String get timeJustNow => 'Gerade eben';

  @override
  String timeMinutesAgo(int count) {
    return 'vor $count Min.';
  }

  @override
  String timeHoursAgo(int count) {
    return 'vor $count Std.';
  }

  @override
  String timeDaysAgo(int count) {
    return 'vor $count Tagen';
  }

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get settingsRole => 'Geräterolle';

  @override
  String get roleGatewayFull => 'Android-SIM-Gateway';

  @override
  String get roleClientIos =>
      'iPhone-Client — die SIM bleibt auf deinem Android-Gateway';

  @override
  String get settingsRelay => 'Relay';

  @override
  String get settingsEncryption => 'Verschlüsselung';

  @override
  String get settingsEncryptionSubtitle =>
      'AES-256-GCM · 256-Bit-Schlüssel aus deiner Kopplung';

  @override
  String get settingsCallControl => 'Fernsteuerung für Anrufe';

  @override
  String get callControlReady => 'Von jedem Telefon ablehnen und auflegen';

  @override
  String get callControlNeedsRole => 'Benötigt die Android-Telefonrolle';

  @override
  String get settingsSims => 'Aktive SIMs';

  @override
  String get noActiveSim => 'Keine aktive SIM erkannt';

  @override
  String get leaveBridge => 'Bridge verlassen';

  @override
  String get leaveBridgeSubtitle =>
      'Entfernt Schlüssel und Sitzung von diesem Telefon';

  @override
  String get leaveBridgeTitle => 'Diese Bridge verlassen?';

  @override
  String get leaveBridgeWarning =>
      'Die Kopie des Bridge-Schlüssels auf diesem Telefon wird gelöscht. Um die Bridge wieder zu nutzen, musst du sie von einem anderen Telefon der Bridge aus koppeln — mach das also nur, wenn du eines zur Hand hast.';

  @override
  String get leaveBridgeGatewayWarning =>
      'Dieses Telefon stellt die SIM bereit. Nach dem Verlassen verlieren deine anderen Telefone den Zugriff darauf, bis du erneut koppelst.';

  @override
  String get leaveBridgeConfirm => 'Verlassen und Schlüssel löschen';

  @override
  String get callAudioNote =>
      'Der Anrufton bleibt auf dem Android-Gateway. Sim Bridge zeigt Anrufaktivität und kann Anrufe starten oder beenden, aber mobile Plattformen geben den Mobilfunkton nicht an Apps weiter.';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get removeDevice => 'Entfernen';

  @override
  String removeDeviceTitle(String name) {
    return '$name entfernen?';
  }

  @override
  String get removeDeviceSubtitle =>
      'Dieses Telefon verliert sofort den Zugriff auf diese Bridge.';

  @override
  String get removeDeviceKeyWarning =>
      'Es besitzt weiterhin eine Kopie des Bridge-Schlüssels und kann bereits geladene Nachrichten lesen. Um es vollständig auszuschließen, erstelle eine neue Bridge und koppele deine Telefone erneut.';

  @override
  String get removeDeviceGatewayWarning =>
      'Dieses Telefon stellt die SIM bereit. Beim Entfernen wird auch der Nachrichtenverlauf gelöscht, den es an diese Bridge gesendet hat.';

  @override
  String get removeDeviceRejoinWarning =>
      'Diese Bridge ist für neue Geräte offen, das entfernte Telefon könnte also mit dem Wiederherstellungscode erneut beitreten. Schließe unten die Anmeldung, um das zu verhindern.';

  @override
  String get removeDeviceConfirm => 'Dieses Telefon entfernen';

  @override
  String deviceRemoved(String name) {
    return '$name wurde entfernt';
  }

  @override
  String get ownerBadge => 'Besitzer';

  @override
  String get settingsNotifications => 'Benachrichtigungen';

  @override
  String get notificationsAllowed =>
      'Erlaubt — Codes und Nachrichten melden sich';

  @override
  String get notificationsBlocked =>
      'Blockiert — erlaube Benachrichtigungen in den Systemeinstellungen';

  @override
  String get notificationsUnknown =>
      'Erlaube Benachrichtigungen für neue Nachrichten';

  @override
  String get openSettings => 'Einstellungen öffnen';

  @override
  String get testCodeTitle => 'Bestätigungscode testen';

  @override
  String get testCodeSubtitle =>
      'Benachrichtigt dieses Telefon mit einem Testcode, nichts wird gesendet';

  @override
  String testCodeSent(String code) {
    return 'Testcode $code gesendet. Probiere einen Tastaturvorschlag oder füge ihn in ein Code-Feld ein.';
  }

  @override
  String get testMessageTitle => 'Testnachricht an deine Telefone senden';

  @override
  String get testMessageSubtitle =>
      'Eine simulierte eingehende SMS, verschlüsselt über das Relay';

  @override
  String testMessageSent(String code) {
    return 'Testnachricht mit Code $code an deine anderen Telefone gesendet.';
  }

  @override
  String get testSender => 'Sim Bridge Test';

  @override
  String testCodeBody(String code) {
    return 'Dein Sim Bridge Bestätigungscode lautet $code';
  }

  @override
  String get testNotificationsUnavailable =>
      'Erlaube zuerst Benachrichtigungen für Sim Bridge und versuche es erneut.';

  @override
  String get simulatedBadge => 'Test';

  @override
  String get settingsAutoCopy => 'Bestätigungscodes';

  @override
  String get autoCopyOn => 'Automatisch kopiert, bereit zum Einfügen';

  @override
  String get autoCopyOff => 'Selbst aus der Nachricht kopieren';

  @override
  String get settingsEnrollment => 'Neue Geräte';

  @override
  String get enrollmentOpen =>
      'Jeder mit dem Wiederherstellungscode kann beitreten';

  @override
  String get enrollmentClosed => 'Geschlossen — kein Telefon kann beitreten';

  @override
  String get enrollmentOpened => 'Diese Bridge akzeptiert jetzt neue Geräte';

  @override
  String get enrollmentClosed2 =>
      'Diese Bridge akzeptiert keine neuen Geräte mehr';

  @override
  String ownerOnlyHint(String name) {
    return 'Nur $name kann Telefone entfernen oder dies ändern.';
  }

  @override
  String get confirmJoinTitle => 'Dieser Bridge beitreten?';

  @override
  String get confirmJoinSubtitle =>
      'Prüfe diese Angaben, bevor dein Telefon sich verbindet.';

  @override
  String get confirmJoinGatewayWarning =>
      'Dieses Telefon teilt seine SIM: SMS und Anrufaktivität werden verschlüsselt an das oben genannte Relay gesendet. Fahre nur fort, wenn du dieses Relay selbst eingerichtet hast.';

  @override
  String get confirmJoinClientNote =>
      'Dieses Telefon liest Aktivitäten aus der Bridge. Fahre nur fort, wenn du das oben genannte Relay kennst.';

  @override
  String get errorInvalidInvitation =>
      'Diese Einladung konnte nicht gelesen werden. Lass dir einen neuen QR-Code anzeigen.';

  @override
  String get errorInvalidRecoveryCode =>
      'Dieser Wiederherstellungscode ist ungültig. Prüfe alle 52 Zeichen und versuche es erneut.';

  @override
  String get errorInsecureRelay =>
      'Ein Relay außerhalb deines lokalen Netzwerks muss https verwenden.';

  @override
  String get errorSmsFields => 'Gib eine Telefonnummer und eine Nachricht ein';

  @override
  String get errorPhoneField => 'Gib eine Telefonnummer ein';

  @override
  String get errorNoGateway => 'Kein Android-Gateway ist verbunden';

  @override
  String get errorCallGateway =>
      'Das Gateway für diesen Anruf ist nicht erreichbar';

  @override
  String get scanTitle => 'Einladung scannen';

  @override
  String get scanHint =>
      'Richte dieses Telefon auf den QR-Code eines vertrauenswürdigen Geräts.';

  @override
  String get testCodeKeyboardSubtitle =>
      'Erzeuge einen Testcode und probiere dann einen Tastaturvorschlag oder füge ihn hier ein.';

  @override
  String get verificationCodeLabel => 'Bestätigungscode';

  @override
  String get sendTestCode => 'Testcode senden';

  @override
  String get gatewayRuntimeTitle => 'Gateway im Hintergrund';

  @override
  String get gatewayRuntimeRunning => 'Läuft · Relay verbunden';

  @override
  String get gatewayRuntimeWaiting =>
      'Läuft · wartet auf Verbindung. Nachrichten bleiben gespeichert.';

  @override
  String get gatewayRuntimeStopped =>
      'Der Hintergrunddienst ist gestoppt. Nutze „Gateway neu starten“ unten.';

  @override
  String get gatewayRuntimeUnauthorized =>
      'Die Kopplungsdaten wurden abgelehnt. Nachrichten bleiben gespeichert.';

  @override
  String get gatewayRuntimePermissions =>
      'Erforderliche Telefonberechtigungen fehlen. Nachrichten bleiben gespeichert.';

  @override
  String get gatewayBatteryTitle => 'Akkueinstellungen';

  @override
  String get gatewayBatteryUnrestricted =>
      'Akkuoptimierung ist aus. Android kann die App trotzdem stoppen.';

  @override
  String get gatewayBatteryRestricted =>
      'Akkuoptimierung kann die Synchronisierung verzögern. Prüfe die Hintergrundbeschränkungen.';

  @override
  String get gatewayStopFailed =>
      'Das Gateway konnte nicht sicher gestoppt werden. Kopplung und gespeicherte Nachrichten bleiben erhalten. Versuche es erneut.';

  @override
  String get commandOutcomeUnknown =>
      'Ergebnis unbekannt · kein automatischer Wiederholungsversuch';

  @override
  String testMessageQueued(String code) {
    return 'Testnachricht mit Code $code gespeichert. Sie wird hochgeladen, sobald das Gateway verbunden ist.';
  }

  @override
  String get pairingUnavailable =>
      'Die gespeicherte Kopplung konnte nicht geöffnet werden. Entsperre das Telefon und öffne die App erneut. Vorhandene Kopplungsdaten bleiben erhalten.';

  @override
  String get gatewayClearFailed =>
      'Die Daten auf diesem Telefon konnten nicht vollständig gelöscht werden. Versuche es erneut.';

  @override
  String get gatewayRestart => 'Gateway neu starten';

  @override
  String get gatewayRestartDescription =>
      'Starte neu, sobald der bisherige Dienst gestoppt ist. Kopplung und gespeicherte Nachrichten bleiben erhalten.';

  @override
  String get gatewayNotSynced => 'Noch nicht';

  @override
  String gatewayRuntimeDetails(String status, int pending, String time) {
    return '$status\nGespeichert: $pending · Letzte Synchronisierung: $time';
  }

  @override
  String get gatewayAutostartTitle => 'Autostart im Hintergrund';

  @override
  String get gatewayAutostartDescription =>
      'Aktiviere Sim Bridge in den Systemeinstellungen deines Geräts. Die App kann diese Einstellung nicht überprüfen.';

  @override
  String get gatewaySettingsUnavailable =>
      'Die Systemeinstellungen konnten nicht geöffnet werden. Öffne die Einstellungen dieser App manuell.';

  @override
  String get gatewayChecksTitle => 'Gateway-Prüfung';

  @override
  String get gatewayNeedsAttention => 'Gateway prüfen';

  @override
  String get gatewayReviewSetup => 'Einrichtung prüfen';

  @override
  String get gatewayCheckedNow => 'Gerade geprüft';

  @override
  String get gatewayNotChecked => 'Nicht geprüft';

  @override
  String get gatewayChecksSubtitle =>
      'Diese Prüfungen zeigen die aktuellen Geräteeinstellungen. Android kann Hintergrundaktivität trotzdem einschränken.';

  @override
  String get gatewayCheckReceive => 'SMS empfangen';

  @override
  String get gatewayCheckSend => 'SMS senden';

  @override
  String get gatewayCheckSim => 'SIM-Zugriff';

  @override
  String get gatewayPermissionGranted => 'Berechtigung erteilt';

  @override
  String get gatewayReceiveMissing =>
      'Die Berechtigung zum SMS-Empfang fehlt. Neue SMS können nicht erfasst werden.';

  @override
  String get gatewaySendMissing =>
      'Die Berechtigung zum SMS-Senden fehlt. SMS können nicht aus der Ferne gesendet werden.';

  @override
  String get gatewaySimMissing =>
      'Die Berechtigung für den Telefonstatus fehlt. SIM-Zugriff ist nicht verfügbar.';

  @override
  String get gatewayAllowPermissions => 'Berechtigungen erlauben';

  @override
  String get gatewayOpenPermissions => 'App-Berechtigungen öffnen';

  @override
  String get gatewayCheckBackground => 'Hintergrundaktivität';

  @override
  String get gatewayBackgroundAllowed =>
      'Keine Einschränkung durch das System erkannt';

  @override
  String get gatewayBackgroundRestricted =>
      'Hintergrundaktivität ist eingeschränkt. Prüfe die Systemeinstellungen dieser App.';

  @override
  String get gatewayNotificationsVisible =>
      'Gateway-Benachrichtigungen sind sichtbar';

  @override
  String get gatewayNotificationsHidden =>
      'Gateway-Benachrichtigungen sind ausgeblendet. Der Dienst kann trotzdem laufen, aber sein Status ist nicht sichtbar.';

  @override
  String get gatewayAutostartPending =>
      'Prüfe die Autostart-Einstellung des Geräts und aktiviere Sim Bridge. Die App kann diesen Schalter nicht auslesen.';

  @override
  String get gatewayAutostartManual =>
      'Von dir bestätigt · Nicht von der App geprüft';

  @override
  String get gatewayOpenAutostart => 'Autostart-Einstellungen öffnen';

  @override
  String get gatewayConfirmAutostart => 'Autostart ist aktiviert';

  @override
  String get gatewayCheckAgain => 'Erneut prüfen';

  @override
  String get gatewayCheckActionFailed =>
      'Die Gateway-Einrichtung konnte nicht aktualisiert werden. Versuche es erneut.';

  @override
  String get gatewayRelayConnected => 'Relay verbunden';

  @override
  String gatewayQueuedWarning(int count) {
    return '$count Ereignisse warten auf den Upload.';
  }

  @override
  String get gatewayRuntimeUnpaired =>
      'Die lokale Kopplung ist nicht verfügbar. Entsperre dieses Telefon und prüfe die Kopplungseinstellungen. Gespeicherte Daten bleiben erhalten.';

  @override
  String get gatewayReviewPairing => 'Kopplungseinstellungen prüfen';

  @override
  String get defaultDeviceNameMac => 'Mein Mac';

  @override
  String get defaultDeviceNameWindows => 'Mein Windows-PC';

  @override
  String get defaultDeviceNameLinux => 'Mein Linux-PC';

  @override
  String get desktopClientTitle => 'Ein Client auf deinem Computer';

  @override
  String get desktopClientBody =>
      'Lies Nachrichten, kopiere Bestätigungscodes und sende SMS- oder Anrufanfragen über dein gekoppeltes Android-Gateway. Dieser Computer kann keine SIM teilen.';

  @override
  String get desktopOnboardingHeadline => 'Deine SIM.\nAuf deinem Computer.';

  @override
  String get desktopOnboardingTagline =>
      'Lass deine Android-SIM verbunden und hole ihre Nachrichten und Bestätigungscodes an deinen Schreibtisch. Nur deine gekoppelten Geräte können sie lesen.';

  @override
  String get desktopSetupSubtitle =>
      'Tritt deiner bestehenden Brücke mit Relay-URL und Wiederherstellungscode bei. Erstelle eine neue Brücke zuerst auf ihrem Android-SIM-Gateway.';

  @override
  String get desktopAvailabilityTitle => 'Sim Bridge geöffnet lassen';

  @override
  String get desktopAvailabilityBody =>
      'Synchronisierung und Benachrichtigungen funktionieren, solange die App läuft, auch minimiert. Sie pausieren, wenn du die App beendest oder dein Computer schläft. Es gibt keinen Desktop-Hintergrunddienst und keinen Remote-Push.';

  @override
  String get desktopRole => 'Desktop-Client · Android-Gateway erforderlich';

  @override
  String get desktopThisDevice => 'Dieser Computer';

  @override
  String get desktopClipboardBody =>
      'Automatisches Kopieren ist optional und standardmäßig aus. Windows und Linux verwenden die Systemzwischenablage ohne automatisches Ablaufdatum; der Verlauf oder andere Apps können Codes behalten.';

  @override
  String get desktopNotificationsUnknown =>
      'Die Systemberechtigung für Benachrichtigungen lässt sich hier nicht prüfen. Teste eine Benachrichtigung und prüfe die Systemeinstellungen.';

  @override
  String get desktopNotificationsAvailable =>
      'Mit dem Benachrichtigungsdienst des Systems verbunden. Ob Hinweise erscheinen, hängt von deinen Systemeinstellungen ab.';

  @override
  String get desktopNotificationAction => 'Sim Bridge öffnen';

  @override
  String get desktopNotificationSettingsHelp =>
      'Prüfe Sim Bridge in den Benachrichtigungseinstellungen deines Systems.';

  @override
  String get desktopCodeTestSubtitle =>
      'Zeigt eine lokale Testbenachrichtigung. Kopiert einen Code nur bei aktiviertem automatischem Kopieren.';

  @override
  String get desktopSetupTitle => 'Diesen Computer einrichten';

  @override
  String get desktopTrustKeys => 'Schlüssel bleiben auf deinen Geräten';

  @override
  String get desktopPairTitle => 'Weiteres Gerät koppeln';

  @override
  String get desktopPairWarning =>
      'Mit diesen Angaben kann jeder diese Brücke entschlüsseln. Teile sie nur mit einem Gerät, dem du vertraust.';

  @override
  String get desktopManualJoinSubtitle =>
      'Verwende die Angaben auf einem vertrauenswürdigen gekoppelten Gerät.';

  @override
  String get desktopConfirmJoinSubtitle =>
      'Prüfe diese Angaben, bevor sich dein Computer verbindet.';

  @override
  String get desktopConfirmJoinClientNote =>
      'Dieser Computer liest Aktivitäten aus der Brücke. Fahre nur fort, wenn du das oben angezeigte Relay kennst.';

  @override
  String get desktopLeaveBridgeSubtitle =>
      'Entfernt Schlüssel und Sitzung von diesem Computer';

  @override
  String get desktopLeaveBridgeWarning =>
      'Der Brückenschlüssel auf diesem Computer wird gelöscht. Verwende zum erneuten Beitritt die Wiederherstellungsdaten von einem anderen gekoppelten Gerät.';

  @override
  String get desktopPairingUnavailable =>
      'Die gespeicherte Kopplung konnte nicht geöffnet werden. Entsperre deinen Computer oder Schlüsselspeicher und öffne die App erneut. Bestehende Kopplungsdaten bleiben erhalten.';

  @override
  String get desktopUnnamedDevice => 'Unbenanntes Gerät';

  @override
  String get pairingRecoveryWaiting =>
      'Warte auf das Android-Gateway zur Wiederherstellung der sicheren Kopplung. Schlüssel und lokaler Verlauf bleiben erhalten.';

  @override
  String get pairingLegacyMigration =>
      'Diese Kopplung benötigt ein vom Betreiber bestätigtes Upgrade. Zugangsdaten und Gateway-Journal bleiben erhalten.';

  @override
  String get gatewayCreationRequired =>
      'Erstelle die Bridge auf ihrem Android-SIM-Gateway und kopple anschließend dieses Gerät.';

  @override
  String get pairExistingBridge => 'Mit bestehender Bridge koppeln';

  @override
  String get leavePolicyPending =>
      'Die Entfernung ist nicht bestätigt. Halte das Android-Gateway verbunden und versuche es erneut. Zugangsdaten und Journal bleiben erhalten.';

  @override
  String get operatorRecoveryTitle =>
      'Kopplung durch Betreiber wiederherstellen';

  @override
  String get operatorRecoveryBody =>
      'Sende diese öffentlichen Identitätsdaten an deinen Relay-Betreiber. Füge dessen Zertifikat und für das Android-Gateway die bestätigte Richtlinie ein. Schlüssel, IDs und Journal bleiben auf diesem Gerät.';

  @override
  String get operatorRecoveryCopy => 'Öffentliche Identität kopieren';

  @override
  String get operatorRecoveryCertificate => 'Zertifikat des Betreibers';

  @override
  String get operatorRecoveryPolicy => 'Gateway-Richtlinie als JSON';

  @override
  String get operatorRecoveryApply => 'Bestätigte Wiederherstellung anwenden';

  @override
  String get operatorRecoverySummary =>
      'Bestehende Kopplung nach Betreiberfreigabe aktualisieren';

  @override
  String get operatorRecoveryRejected =>
      'Wiederherstellung abgelehnt. Prüfe Zertifikat und Richtlinie. Bestehende Zugangsdaten bleiben erhalten.';

  @override
  String get operatorPrivateVerifier =>
      'Privaten Aufnahme-Verifikator kopieren';

  @override
  String get operatorPrivateVerifierWarning =>
      'Dieser Verifikator kann die Aufnahme erlauben, wenn der Betreiber die Bridge öffnet. Teile ihn nur mit deinem vertrauenswürdigen Relay-Betreiber. Verschlüsselungsschlüssel, Gerätetokens und Signaturschlüssel sind nicht enthalten.';

  @override
  String get operatorIdentityPending =>
      'Das Gateway hat seine geschützte Signaturidentität noch nicht vorbereitet. Halte den Gateway-Dienst verfügbar und versuche es erneut. Diese Ansicht hat keinen neuen Schlüssel erzeugt.';

  @override
  String get authorityRemovalWarning =>
      'Das Entfernen dieses autoritativen Gateways deaktiviert die gesamte Bridge dauerhaft. Alle gekoppelten Geräte verlieren den Zugriff.';

  @override
  String get errorRelayUnreachable =>
      'Das Relay ist nicht erreichbar. Prüfe die Adresse und deine Verbindung und versuche es erneut.';

  @override
  String get errorRelayUnauthorized =>
      'Das Relay akzeptiert dieses Gerät nicht mehr. Kopple es erneut über dein Gateway.';

  @override
  String get errorRelayRefused => 'Das Relay hat diese Anfrage abgelehnt.';

  @override
  String get errorRelayNotFound =>
      'Das Relay kennt diese Bridge nicht. Prüfe die Relay-Adresse.';

  @override
  String get errorGatewayBusy =>
      'Das Android-Gateway muss dies zuerst bestätigen. Lass es online und versuche es erneut.';

  @override
  String get errorRelayBusy =>
      'Zu viele Versuche. Warte eine Minute und versuche es erneut.';

  @override
  String get errorRelayFailure =>
      'Das Relay konnte die Anfrage nicht abschließen. Versuche es später erneut.';

  @override
  String get errorRelayResponse =>
      'Das Relay hat unerwartet geantwortet. Prüfe, ob die Adresse auf ein Sim-Bridge-Relay zeigt.';

  @override
  String get errorPermissionDenied =>
      'Sim Bridge benötigt dafür eine Berechtigung. Erlaube sie in den Systemeinstellungen.';

  @override
  String get errorDeviceAction =>
      'Dieses Gerät konnte die Aktion nicht ausführen. Versuche es erneut.';

  @override
  String get errorUnexpected => 'Etwas ist schiefgelaufen. Versuche es erneut.';

  @override
  String get updatesTitle => 'Updates';

  @override
  String updatesCurrentVersion(String version) {
    return 'Version $version';
  }

  @override
  String updatesAvailableSubtitle(String version) {
    return 'Version $version ist verfügbar';
  }

  @override
  String get updatesChecking => 'Suche nach Updates …';

  @override
  String updatesUpToDate(String version) {
    return 'Sim Bridge $version ist aktuell';
  }

  @override
  String get updatesCheckFailed =>
      'Updates konnten nicht geprüft werden. Prüfe deine Verbindung und versuche es erneut.';

  @override
  String get updatesAutomatic => 'Automatisch nach Updates suchen';

  @override
  String get updatesAutomaticSubtitle =>
      'Einmal täglich, aus den Sim-Bridge-Releases auf GitHub';

  @override
  String updatesAvailableTitle(String version) {
    return 'Sim Bridge $version ist verfügbar';
  }

  @override
  String get updatesInstallBody =>
      'Sim Bridge lädt das Update herunter, prüft es, schließt sich, installiert es und startet neu. Kopplung und Einstellungen bleiben erhalten.';

  @override
  String get updatesDownloadBody =>
      'Sim Bridge lädt die neue Version herunter, prüft sie und speichert sie in deinem Downloads-Ordner. Beende danach Sim Bridge und ersetze die App durch die neue Version. Kopplung und Einstellungen bleiben erhalten.';

  @override
  String get updatesInstall => 'Installieren und neu starten';

  @override
  String get updatesDownload => 'Herunterladen';

  @override
  String get updatesLater => 'Später';

  @override
  String get updatesReleaseNotes => 'Versionshinweise';

  @override
  String get updatesDownloading => 'Update wird heruntergeladen und geprüft …';

  @override
  String updatesDownloaded(String file) {
    return '$file wurde in deinem Downloads-Ordner gespeichert';
  }

  @override
  String get updatesFailed =>
      'Das Update konnte nicht heruntergeladen oder geprüft werden. Versuche es später erneut.';

  @override
  String updatesNotice(String version) {
    return 'Sim Bridge $version ist verfügbar';
  }

  @override
  String get updatesShow => 'Aktualisieren';
}
