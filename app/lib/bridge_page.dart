import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'authorization_coordinator.dart';
import 'desktop_updater.dart';
import 'device_authorization.dart';
import 'gateway_runtime.dart';
import 'gateway_readiness.dart';
import 'session_store.dart';
import 'l10n/app_localizations.dart';
import 'logging.dart';
import 'protocol.dart';
import 'platform_support.dart';
import 'scanner.dart';
import 'security.dart';
import 'theme.dart';
import 'widgets.dart';

/// How much decrypted history a phone keeps in memory for the activity list.
const _maxLocalEvents = 500;
const _discoveryWindow = Duration(seconds: 6);
const _presenceWindow = Duration(seconds: 16);
const _mdnsServiceType = '_simbridge._tcp';
const _desktopBreakpoint = 900.0;
const _desktopContentWidth = 900.0;
const _desktopFormWidth = 720.0;
const _desktopSheetWidth = 640.0;
const _notificationChannelId = 'sim_bridge_messages';

class BridgePage extends StatefulWidget {
  const BridgePage({super.key, this.platformOverride});
  final BridgePlatform? platformOverride;
  @override
  State<BridgePage> createState() => _BridgePageState();
}

class _BridgePageState extends State<BridgePage> with WidgetsBindingObserver {
  static const platform = MethodChannel('app.simbridge/sms');
  static const clipboard = MethodChannel('app.simbridge/clipboard');
  static final notifications = FlutterLocalNotificationsPlugin();
  final server = TextEditingController();
  BridgePlatform get host => widget.platformOverride ?? BridgePlatform.current;
  // Bridge creation requires the operator's owner key in every build mode.
  final relayKey = TextEditingController();
  final deviceName = TextEditingController();
  Session? session;
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> simProfiles = [];
  List<dynamic> devices = [];
  RelayEvents? _relayEvents;
  StreamSubscription<RelayEvent>? _relaySubscription;
  Timer? _syncRetry;
  bool _messagesPending = false, _rosterPending = false;
  bool _streamConnected = false, _pairingRejected = false;
  Completer<void>? _syncDone;
  Timer? _recoveryRetry;
  bool _recoveringPairing = false, _pairingRecoveryPending = false;
  int _recoveryFailures = 0;
  bool _operatorRecoveryPending = false, _leaving = false;
  Completer<void>? _pairingRecoveryDone, _operatorWriteDone;
  int _syncFailures = 0;
  bool gateway = false;
  bool busy = false;
  bool relayOnline = false;
  bool phoneRole = false;
  bool bridgeJoinable = true;
  bool autoCopyCodes = false;
  bool _notificationServiceAvailable = false;
  bool? notificationsAllowed;

  /// True until the stored session has been looked up. Without this the setup
  /// form renders first and an already-paired phone appears unpaired for a
  /// moment on every launch.
  bool _restoring = true;
  bool _pairingUnavailable = false;
  bool _gatewayRestarting = false;
  int? relayLatency;
  // Desktop updates: the installed version, an available release, and whether
  // a check or download is running.
  String? _appVersion;
  DesktopRelease? _availableUpdate;
  bool _autoUpdateCheck = true, _updateBusy = false;
  static const _autoUpdatePreference = 'autoUpdateCheck';
  static const _lastUpdateCheckPreference = 'lastUpdateCheckAt';
  int tab = 0;
  String? error;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  final List<BonsoirService> discoveredRelays = [];
  bool discoveringRelays = false;
  bool _syncing = false;
  bool _notificationsReady = false;
  bool _pushBridgeReady = false;
  String? _registeredPushToken;
  bool _defaultsApplied = false;
  static const _gatewayLifecycle = MethodChannel('app.simbridge/gateway');
  final _sessionStore = SessionStore();
  Map<String, dynamic> _gatewayStatus = {};
  Stopwatch? _gatewayCheckClock;
  String? _autostartConfirmedFingerprint;
  DateTime? _autostartConfirmedAt;
  bool _checkingGateway = false;
  final _gatewayChecksRevision = ValueNotifier<int>(0);
  NotifiedMessages? _notifiedMessages;

  /// Highest decrypted sequence; event-triggered catch-up asks only for new data.
  int _lastMessageSeq = 0;
  final Map<String, List<Map<String, dynamic>>> _profilesByGateway = {};
  late final Future<void> _notificationInitialization;

  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    server.text = host.defaultRelayUrl;
    gateway = host.canGateway;
    autoCopyCodes = host.defaultAutoCopy;
    _notificationInitialization = _initializeNotifications();
    unawaited(Log.initialize());
    _restore();
    // Widget tests never reach the network for updates.
    if (host.isDesktop && !Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(_initializeUpdates());
    }
  }

  Future<void> _initializeUpdates() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        _autoUpdateCheck = prefs.getBool(_autoUpdatePreference) ?? true;
      });
      final last = DateTime.tryParse(
        prefs.getString(_lastUpdateCheckPreference) ?? '',
      );
      if (_autoUpdateCheck &&
          (last == null ||
              DateTime.now().difference(last) >= updateCheckInterval)) {
        await _checkForUpdates(automatic: true);
      }
    } catch (failure) {
      Log.warn('Update check unavailable', failure);
    }
  }

  Future<void> _checkForUpdates({bool automatic = false}) async {
    final version = _appVersion;
    if (version == null || _updateBusy) return;
    setState(() => _updateBusy = true);
    final updater = DesktopUpdater(currentVersion: version);
    try {
      // Record the attempt first, so a failing network also respects the daily limit.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastUpdateCheckPreference,
        DateTime.now().toIso8601String(),
      );
      final release = await updater.check();
      if (!mounted) return;
      setState(() => _availableUpdate = release);
      if (release != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.updatesNotice(release.version)),
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: l10n.updatesShow,
              onPressed: () => unawaited(_offerUpdate(release)),
            ),
          ),
        );
      } else if (!automatic) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.updatesUpToDate(version))));
      }
    } catch (failure) {
      Log.warn('Update check failed', failure);
      if (mounted && !automatic) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.updatesCheckFailed)));
      }
    } finally {
      updater.close();
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _offerUpdate(DesktopRelease release) async {
    final install = release.method == UpdateMethod.install;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.updatesAvailableTitle(release.version)),
        content: Text(
          install ? l10n.updatesInstallBody : l10n.updatesDownloadBody,
        ),
        actions: [
          TextButton(
            onPressed: () => unawaited(
              launchUrl(release.pageUrl, mode: LaunchMode.externalApplication),
            ),
            child: Text(l10n.updatesReleaseNotes),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.updatesLater),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(install ? l10n.updatesInstall : l10n.updatesDownload),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _applyUpdate(release);
  }

  Future<void> _applyUpdate(DesktopRelease release) async {
    final version = _appVersion;
    if (version == null || _updateBusy) return;
    setState(() => _updateBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.updatesDownloading),
        duration: const Duration(minutes: 10),
      ),
    );
    final updater = DesktopUpdater(currentVersion: version);
    try {
      if (release.method == UpdateMethod.install) {
        final folder = await getTemporaryDirectory();
        final setup = await updater.download(
          release,
          Directory('${folder.path}${Platform.pathSeparator}sim-bridge-update'),
        );
        await DesktopUpdater.startWindowsInstaller(setup);
        // The installer waits for this window to close, then restarts Sim Bridge.
        exit(0);
      }
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw const UpdateException('no_downloads_folder');
      final file = await updater.download(release, downloads);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.updatesDownloaded(file.uri.pathSegments.last)),
        ),
      );
      await launchUrl(Uri.directory(downloads.path));
    } catch (failure) {
      Log.warn('Update download failed', failure);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(l10n.updatesFailed)));
    } finally {
      updater.close();
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _setAutoUpdateCheck(bool enabled) async {
    setState(() => _autoUpdateCheck = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoUpdatePreference, enabled);
  }

  Widget _updatesCard() {
    final version = _appVersion;
    final update = _availableUpdate;
    return Card(
      child: Column(
        children: [
          SettingsTile(
            icon: update != null
                ? Icons.system_update_alt_rounded
                : Icons.verified_outlined,
            title: l10n.updatesTitle,
            subtitle: _updateBusy
                ? l10n.updatesChecking
                : update != null
                ? l10n.updatesAvailableSubtitle(update.version)
                : l10n.updatesCurrentVersion(version ?? '…'),
            trailing: _updateBusy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _updateBusy || version == null
                ? null
                : update != null
                ? () => unawaited(_offerUpdate(update))
                : () => unawaited(_checkForUpdates()),
          ),
          const Divider(height: 1, indent: 56),
          SwitchListTile(
            secondary: const Icon(Icons.update_rounded, color: Palette.fir),
            title: Text(
              l10n.updatesAutomatic,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              l10n.updatesAutomaticSubtitle,
              style: const TextStyle(color: Palette.haze, fontSize: 12),
            ),
            value: _autoUpdateCheck,
            onChanged: (value) => unawaited(_setAutoUpdateCheck(value)),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_defaultsApplied) {
      _defaultsApplied = true;
      if (deviceName.text.isEmpty) {
        deviceName.text = host.defaultDeviceName(l10n);
      }
    }
  }

  Future<void> _initializeNotifications() async {
    try {
      final initialized = await notifications.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(
            defaultActionName: lookupAppLocalizations(
              WidgetsBinding.instance.platformDispatcher.locale.languageCode ==
                      'de'
                  ? const Locale('de')
                  : const Locale('en'),
            ).desktopNotificationAction,
            defaultIcon: ThemeLinuxIcon('sim-bridge'),
          ),
          windows: const WindowsInitializationSettings(
            appName: 'Sim Bridge',
            appUserModelId: 'dev.renner.simbridge.desktop',
            guid: 'a7d21fe8-45d2-4f86-9f0d-8127e6c0b981',
          ),
        ),
      );
      // Windows/Linux return false when native setup fails. That is different
      // from Darwin's permission result: keep its request flow available.
      final requiresNativeReady =
          host.target == TargetPlatform.windows ||
          host.target == TargetPlatform.linux;
      _notificationsReady = !requiresNativeReady || initialized == true;
      if (!_notificationsReady) {
        Log.warn('The native notification service did not initialize');
        return;
      }
    } catch (exception) {
      Log.error('Notifications could not be initialised', exception);
      _notificationsReady = false;
      return;
    }
    // Read the state directly: going through _refreshNotificationPermission
    // here would await the very future this function is completing.
    await _readNotificationPermission();
  }

  /// Asks for permission and records the answer.
  ///
  /// iOS only ever shows this prompt once per install; if it was dismissed or
  /// declined, every later request returns false silently and notifications
  /// simply never appear. So the result is kept and surfaced in Settings
  /// rather than assumed.
  Future<bool> _requestNotificationPermission() async {
    await _notificationInitialization;
    if (!_notificationsReady) return false;
    bool? granted;
    if (Platform.isIOS) {
      granted = await notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isMacOS) {
      granted = await notifications
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isAndroid) {
      granted = await notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
    await _refreshNotificationPermission();
    if (Platform.isIOS && notificationsAllowed == true) {
      unawaited(_preparePush());
    }
    // Windows/Linux have no permission read API. Allow a functional test,
    // while keeping the displayed permission state explicitly unknown.
    if (Platform.isWindows || Platform.isLinux) {
      return _notificationServiceAvailable;
    }
    return granted ?? notificationsAllowed == true;
  }

  Future<void> _preparePush() async {
    final current = session;
    if (!Platform.isIOS || current == null) return;
    try {
      _pushBridgeReady =
          await clipboard.invokeMethod<bool>('setPushBridge', {
            'bridgeId': current.bridgeId,
            'key': base64Encode(current.key),
          }) ??
          false;
      if (_pushBridgeReady && notificationsAllowed == true) {
        await clipboard.invokeMethod('registerForPush');
      }
    } catch (exception) {
      _pushBridgeReady = false;
      Log.warn('Could not prepare encrypted push notifications', exception);
    }
  }

  Future<bool> _claimLocalNotification(String? eventId) async {
    if (!Platform.isIOS || eventId == null || eventId.isEmpty) return true;
    try {
      return await clipboard.invokeMethod<bool>(
            'claimLocalNotification',
            eventId,
          ) ??
          true;
    } catch (exception) {
      Log.warn('Could not coordinate local and push notifications', exception);
      return true;
    }
  }

  Future<void> _syncPushRegistration(Session current, BridgeApi api) async {
    if (!Platform.isIOS || !_pushBridgeReady || notificationsAllowed != true) {
      return;
    }
    try {
      final registration = await clipboard.invokeMapMethod<String, String>(
        'pushRegistration',
      );
      final token = registration?['token'] ?? '';
      final environment = registration?['environment'] ?? '';
      if (token.isEmpty || environment.isEmpty) return;
      final identity = '$environment:$token';
      if (_registeredPushToken == identity) return;
      await api.registerPush(current, token, environment);
      _registeredPushToken = identity;
      Log.info('Registered this iPhone for encrypted push notifications');
    } catch (exception) {
      Log.warn(
        'Could not register push notifications with the relay',
        exception,
      );
    }
  }

  Future<Set<String>> _deliveredPushIds() async {
    if (!Platform.isIOS) return <String>{};
    try {
      return (await clipboard.invokeListMethod<String>(
                'deliveredPushMessageIds',
              ) ??
              <String>[])
          .toSet();
    } catch (exception) {
      Log.warn('Could not read delivered push identifiers', exception);
      return <String>{};
    }
  }

  /// Reads the current authorisation state, once notifications are ready.
  Future<void> _refreshNotificationPermission() async {
    await _notificationInitialization;
    await _readNotificationPermission();
  }

  /// The platform read on its own. Never awaits initialisation, so it is safe
  /// to call from inside it.
  Future<void> _readNotificationPermission() async {
    if (!_notificationsReady) return;
    bool? allowed;
    final serviceWasAvailable = _notificationServiceAvailable;
    try {
      if (Platform.isIOS) {
        final options = await notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions();
        allowed = options?.isEnabled;
      } else if (Platform.isMacOS) {
        final options = await notifications
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions();
        allowed = options?.isEnabled;
      } else if (Platform.isLinux) {
        final linux = notifications
            .resolvePlatformSpecificImplementation<
              LinuxFlutterLocalNotificationsPlugin
            >();
        if (linux != null) {
          await linux.getCapabilities();
          _notificationServiceAvailable = true;
        }
      } else if (Platform.isWindows) {
        _notificationServiceAvailable = true;
      } else if (Platform.isAndroid) {
        allowed = await notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.areNotificationsEnabled();
      }
    } catch (exception) {
      Log.warn('Could not read the notification permission', exception);
      _notificationServiceAvailable = false;
      notificationsAllowed = null;
      if (mounted) setState(() {});
      return;
    }
    final wasAllowed = notificationsAllowed;
    if (allowed != null && allowed != notificationsAllowed) {
      Log.info('Notification permission is ${allowed ? 'granted' : 'denied'}');
      notificationsAllowed = allowed;
      if (mounted) setState(() {});
    } else {
      notificationsAllowed = allowed;
    }
    if (serviceWasAvailable != _notificationServiceAvailable && mounted) {
      setState(() {});
    }
    if (Platform.isIOS &&
        allowed == true &&
        wasAllowed == false &&
        session != null) {
      unawaited(_preparePush());
    }
  }

  /// Opens this app's page in the system settings, the only route back once
  /// iOS has stopped showing its prompt.
  Future<void> _openSystemNotificationSettings() async {
    try {
      final opened = await clipboard.invokeMethod<bool>(
        'openNotificationSettings',
      );
      if (host.isDesktop && opened != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.desktopNotificationSettingsHelp)),
        );
      }
    } catch (exception) {
      Log.warn('Could not open the system settings', exception);
      if (host.isDesktop && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.desktopNotificationSettingsHelp)),
        );
      }
    }
  }

  @override
  void dispose() {
    _recoveryRetry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _syncRetry?.cancel();
    unawaited(_stopRelayEvents());
    _discoverySubscription?.cancel();
    _discovery?.stop();
    server.dispose();
    relayKey.dispose();
    deviceName.dispose();
    _gatewayChecksRevision.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!host.isDesktop &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      unawaited(_stopRelayEvents());
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refreshGatewayStatus());
    if (session != null && !_pairingRejected) _startRelayEvents();
    unawaited(_sync());
    // The user may have just changed it in the system settings.
    unawaited(_refreshNotificationPermission());
  }

  Future<void> _restore() async {
    try {
      await _restoreSession();
    } finally {
      // Whatever happened, stop showing the placeholder.
      _restoring = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    server.text = prefs.getString('server') ?? server.text;
    autoCopyCodes = prefs.getBool('autoCopyCodes') ?? host.defaultAutoCopy;
    _autostartConfirmedFingerprint = prefs.getString(
      'gatewayAutostartConfirmedFingerprint',
    );
    final confirmedMillis = prefs.getInt('gatewayAutostartConfirmedAt');
    _autostartConfirmedAt = confirmedMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(confirmedMillis);
    try {
      final stored = await _sessionStore.load();
      if (stored != null) {
        session = stored.session;
        gateway = host.restoreGateway(stored.gateway);
        if (!(gateway && Platform.isAndroid)) {
          final coordinator = AuthorizationCoordinator(_sessionStore);
          final staged = await _sessionStore.stagedOperatorRecovery(
            session!,
            gateway: gateway,
          );
          if (staged != null) {
            _operatorRecoveryPending = true;
            session = await coordinator.installStagedOperatorRecovery(
              session!,
              gateway: gateway,
            );
            _operatorRecoveryPending = false;
          } else {
            session = await coordinator.upgradeIfSupported(session!);
          }
        }
        _start();
        if (Platform.isAndroid && gateway) {
          final started = await _gatewayLifecycle.invokeMethod<bool>('start', {
            'bridgeId': session!.bridgeId,
            'deviceId': session!.deviceId,
          });
          if (started != true) error = l10n.gatewayRuntimeStopped;
        }
        unawaited(_requestNotificationPermission());
      }
    } on RelayRequestException catch (failure) {
      if (session != null && failure.recoveryRequired) {
        unawaited(_recoverPairing(session!, failure));
      } else if (session != null && failure.status == 401) {
        _rejectPairing(legacy: failure.code == 'legacy_upgrade_required');
      } else if (session != null) {
        _start();
      }
    } catch (_) {
      if (session != null && _operatorRecoveryPending) {
        unawaited(
          _recoverPairing(
            session!,
            const RelayRequestException(
              409,
              'Operator recovery pending',
              code: 'gateway_unavailable',
            ),
          ),
        );
      } else if (session != null) {
        _start();
      } else {
        _pairingUnavailable = true;
        error = host.isDesktop
            ? l10n.desktopPairingUnavailable
            : l10n.pairingUnavailable;
        Log.warn('Could not restore pairing; stored credentials preserved');
        return;
      }
    }
    if (session == null && Platform.isIOS) {
      _pushBridgeReady = false;
      _registeredPushToken = null;
      await clipboard.invokeMethod('clearPushBridge');
    }
    if (mounted) setState(() {});
    if (session == null) unawaited(_discoverRelays());
  }

  Future<void> _discoverRelays() async {
    await _discoverySubscription?.cancel();
    await _discovery?.stop();
    discoveredRelays.clear();
    if (mounted) setState(() => discoveringRelays = true);
    final discovery = BonsoirDiscovery(type: _mdnsServiceType);
    _discovery = discovery;
    try {
      await discovery.initialize();
      _discoverySubscription = discovery.eventStream!.listen((event) async {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          event.service.resolve(discovery.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final service = event.service;
          final host = service.host;
          if (host == null || service.attributes['version'] != '1') return;
          final cleanHost = host.endsWith('.')
              ? host.substring(0, host.length - 1)
              : host;
          final urlHost = cleanHost.contains(':') ? '[$cleanHost]' : cleanHost;
          final scheme = service.attributes['scheme'] == 'https'
              ? 'https'
              : 'http';
          final url = '$scheme://$urlHost:${service.port}';
          try {
            await BridgeApi(url).health();
          } catch (_) {
            return;
          }
          if (!mounted) return;
          setState(() {
            discoveredRelays.removeWhere(
              (item) =>
                  item.attributes['relayId'] == service.attributes['relayId'],
            );
            discoveredRelays.add(service);
            if (discoveredRelays.length == 1 &&
                (server.text.contains('127.0.0.1') ||
                    server.text.contains('10.0.2.2'))) {
              server.text = url;
            }
          });
        }
      });
      await discovery.start();
      await Future<void>.delayed(_discoveryWindow);
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = l10n.discoveryUnavailable('$exception');
        });
      }
    } finally {
      if (mounted) setState(() => discoveringRelays = false);
    }
  }

  String _relayUrl(BonsoirService service) {
    var host = service.host ?? '';
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host.contains(':')) host = '[$host]';
    final scheme = service.attributes['scheme'] == 'https' ? 'https' : 'http';
    return '$scheme://$host:${service.port}';
  }

  Future<void> _create() async {
    if (!host.canGateway || !gateway || !Platform.isAndroid) {
      setState(() => error = l10n.gatewayCreationRequired);
      return;
    }
    if (!isSafeRelayUrl(server.text.trim())) {
      setState(() => error = l10n.errorInsecureRelay);
      return;
    }
    await _connect(() async {
      final pending = await _sessionStore.prepareEnrollment(server.text.trim());
      final key = pending.key;
      final signing = pending.identity;
      final identity = await BridgeIdentity.derive(key);
      final api = BridgeApi(server.text.trim(), relayKey.text);
      final data = await api.create(
        identity,
        deviceName.text,
        host.restoreGateway(gateway),
        signingIdentity: signing,
        authority: true,
      );
      if (data['certificate'] is! String || data['policyJson'] is! String) {
        throw const FormatException('Gateway authorization missing');
      }
      return Session(
        server: server.text.trim(),
        token: data['token'],
        deviceId: data['device']['id'],
        bridgeId: identity.bridgeId,
        key: key,
        authorization: DeviceAuthorization(
          identity: signing,
          certificate: data['certificate'],
          policyJson: data['policyJson'],
          bootId: data['bootId'],
        ),
      );
    });
    if (session != null && mounted) _showPairing();
  }

  Future<void> _scan() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const InviteScanner()),
    );
    if (raw == null || !mounted) return;
    final BridgeInvite invite;
    try {
      invite = BridgeInvite.decode(raw);
    } on FormatException catch (failure) {
      Log.warn('Rejected a scanned invitation', failure.message);
      setState(() => error = l10n.errorInvalidInvitation);
      return;
    }
    // Scanning must never be enough on its own: a hostile QR would otherwise
    // silently turn this phone into a gateway feeding someone else's relay.
    if (await _confirmJoin(invite.server) != true) return;
    await _join(invite.server, invite.key);
  }

  /// Shows what the invitation will actually do before any secret is used.
  Future<bool?> _confirmJoin(String relayUrl) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: host.isDesktop
        ? const BoxConstraints(maxWidth: _desktopSheetWidth)
        : null,
    builder: (sheetContext) => Sheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(
            icon: Icons.verified_user_outlined,
            title: l10n.confirmJoinTitle,
            subtitle: (host.isDesktop
                ? l10n.desktopConfirmJoinSubtitle
                : l10n.confirmJoinSubtitle),
          ),
          const SizedBox(height: 18),
          SecretField(
            label: l10n.relayUrlLabel,
            value: relayUrl,
            copiedMessage: l10n.labelCopied(l10n.relayUrlLabel),
            copyTooltip: l10n.copyTooltip,
          ),
          const SizedBox(height: 10),
          SecretField(
            label: l10n.settingsRole,
            value: gateway ? l10n.roleGatewayFull : l10n.roleClient,
            copiedMessage: l10n.labelCopied(l10n.settingsRole),
            copyTooltip: l10n.copyTooltip,
          ),
          const SizedBox(height: 14),
          Text(
            gateway
                ? l10n.confirmJoinGatewayWarning
                : (host.isDesktop
                      ? l10n.desktopConfirmJoinClientNote
                      : l10n.confirmJoinClientNote),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Palette.haze,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => Navigator.pop(sheetContext, true),
            child: Text(l10n.joinBridge),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(sheetContext, false),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    ),
  );

  Future<void> _showCodeKeyboardTest() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (_) => _CodeKeyboardTestSheet(onSend: _testCodeNotification),
    );
  }

  /// Maps a failure to a localized message; raw exception text (relay
  /// English, platform dumps, parser output) never reaches the screen.
  String _describeFailure(Object exception) {
    Log.warn('Operation failed (${exception.runtimeType})');
    return switch (exception) {
      RelayRequestException(status: 401) => l10n.errorRelayUnauthorized,
      RelayRequestException(status: 403) => l10n.errorRelayRefused,
      RelayRequestException(status: 404) => l10n.errorRelayNotFound,
      RelayRequestException(status: 409) => l10n.errorGatewayBusy,
      RelayRequestException(status: 429) => l10n.errorRelayBusy,
      RelayRequestException(status: >= 500) => l10n.errorRelayFailure,
      RelayRequestException() => l10n.errorRelayRefused,
      TimeoutException() ||
      SocketException() ||
      HandshakeException() ||
      http.ClientException() => l10n.errorRelayUnreachable,
      FormatException() => l10n.errorRelayResponse,
      PlatformException(code: 'permission_denied') =>
        l10n.errorPermissionDenied,
      PlatformException() => l10n.errorDeviceAction,
      _ => l10n.errorUnexpected,
    };
  }

  Future<void> _manualJoin() async {
    final manualServer = TextEditingController(text: server.text);
    final recovery = TextEditingController();
    String? serverError, codeError;
    List<int>? decodedKey;
    // The typed code is the bridge root key: keep it out of screenshots.
    await _setSecureScreen(true);
    if (!mounted) return;
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // Validate inside the sheet so a typo never discards what was typed.
          void submit() {
            final url = manualServer.text.trim();
            String? nextServerError, nextCodeError;
            List<int>? key;
            if (!isSafeRelayUrl(url)) nextServerError = l10n.errorInsecureRelay;
            try {
              key = RecoveryCode.decode(recovery.text);
            } on FormatException catch (failure) {
              Log.warn('Rejected a typed recovery code', failure.message);
              nextCodeError = l10n.errorInvalidRecoveryCode;
            }
            if (nextServerError != null || nextCodeError != null) {
              setSheetState(() {
                serverError = nextServerError;
                codeError = nextCodeError;
              });
              return;
            }
            decodedKey = key;
            Navigator.pop(sheetContext, true);
          }

          return CallbackShortcuts(
            // Desktop: Enter joins, Shift+Enter still inserts a line break.
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): submit,
              const SingleActivator(LogicalKeyboardKey.numpadEnter): submit,
            },
            child: Sheet(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SheetHeader(
                      icon: Icons.keyboard_alt_outlined,
                      title: l10n.manualJoinTitle,
                      subtitle: (host.isDesktop
                          ? l10n.desktopManualJoinSubtitle
                          : l10n.manualJoinSubtitle),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: manualServer,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      style: mono(size: 14),
                      onChanged: (_) {
                        if (serverError != null) {
                          setSheetState(() => serverError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: l10n.relayUrlLabel,
                        hintText: 'https://',
                        errorText: serverError,
                        errorMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: recovery,
                      autofocus: host.isDesktop,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.characters,
                      minLines: 2,
                      maxLines: 3,
                      style: mono(size: 14),
                      onSubmitted: (_) => submit(),
                      onChanged: (_) {
                        if (codeError != null) {
                          setSheetState(() => codeError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: l10n.recoveryCodeFieldLabel,
                        hintText: 'XXXX-XXXX-XXXX-…',
                        errorText: codeError,
                        errorMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: submit,
                      child: Text(l10n.joinBridge),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    await _setSecureScreen(false);
    final key = decodedKey;
    recovery.clear();
    if (submitted != true || !mounted || key == null) return;
    await _join(manualServer.text.trim(), key);
  }

  Future<void> _join(String joinServer, List<int> key) async {
    if (!isSafeRelayUrl(joinServer)) {
      setState(() => error = l10n.errorInsecureRelay);
      return;
    }
    final pending = await _sessionStore.prepareEnrollment(
      joinServer,
      invitationKey: key,
    );
    final signing = pending.identity;
    await _connect(() async {
      final identity = await BridgeIdentity.derive(key);
      final api = BridgeApi(joinServer);
      final data = await _waitForEnrollment(
        () => api.join(
          identity,
          deviceName.text,
          host.restoreGateway(gateway),
          signingIdentity: signing,
        ),
      );
      if (data['certificate'] is! String) {
        throw const FormatException('Device authorization missing');
      }
      return Session(
        server: joinServer,
        token: data['token'],
        deviceId: data['device']['id'],
        bridgeId: identity.bridgeId,
        key: key,
        authorization: DeviceAuthorization(
          identity: signing,
          certificate: data['certificate'],
          bootId: data['bootId'],
        ),
      );
    });
  }

  Future<Map<String, dynamic>> _waitForEnrollment(
    Future<Map<String, dynamic>> Function() attempt,
  ) async {
    var failures = 0;
    while (mounted) {
      try {
        return await attempt();
      } on RelayRequestException catch (failure) {
        if (!failure.recoveryRequired) rethrow;
        if (mounted) setState(() => error = l10n.pairingRecoveryWaiting);
        await Future<void>.delayed(
          Duration(seconds: (1 << failures.clamp(0, 5)).clamp(1, 30)),
        );
        failures++;
      }
    }
    throw const StoredPairingUnavailable();
  }

  Future<void> _recoverPairing(
    Session current,
    RelayRequestException failure,
  ) async {
    if (!mounted ||
        _leaving ||
        _pairingRejected ||
        _recoveringPairing ||
        !identical(session, current)) {
      return;
    }
    _recoveringPairing = true;
    _pairingRecoveryDone = Completer<void>();
    _pairingRecoveryPending = true;
    _recoveryRetry?.cancel();
    try {
      await _stopRelayEvents();
      if (mounted) setState(() => error = l10n.pairingRecoveryWaiting);
      final coordinator = AuthorizationCoordinator(_sessionStore);
      var candidate = current;
      if (!_operatorRecoveryPending &&
          candidate.authorization == null &&
          !(gateway && Platform.isAndroid)) {
        candidate = await coordinator.upgradeIfSupported(candidate);
      }
      final updated =
          _operatorRecoveryPending && !(gateway && Platform.isAndroid)
          ? await coordinator.installStagedOperatorRecovery(
                  candidate,
                  gateway: gateway,
                ) ??
                await coordinator.recover(candidate)
          : await coordinator.recover(candidate);
      if (!mounted || _leaving || !identical(session, current)) return;
      session = updated;
      if (current.authorization?.bootId != updated.authorization?.bootId) {
        _lastMessageSeq = 0;
        _registeredPushToken = null;
      }
      _pairingRecoveryPending = false;
      _operatorRecoveryPending = false;
      _recoveryFailures = 0;
      _startRelayEvents();
      unawaited(_sync());
    } on RelayRequestException catch (error) {
      if (!mounted || _leaving || !identical(session, current)) return;
      if (error.status == 401 &&
          (!_operatorRecoveryPending ||
              error.code != 'legacy_upgrade_required' ||
              !(gateway && Platform.isAndroid))) {
        _rejectPairing(
          legacy:
              error.code == 'legacy_upgrade_required' ||
              error.code == 'legacy_pairing_unrecoverable',
        );
      } else {
        _scheduleRecovery(current, error);
      }
    } catch (_) {
      if (mounted && identical(session, current)) {
        _scheduleRecovery(current, failure);
      }
    } finally {
      _recoveringPairing = false;
      _pairingRecoveryDone!.complete();
      _pairingRecoveryDone = null;
    }
  }

  void _scheduleRecovery(Session current, RelayRequestException failure) {
    if (_leaving) return;
    final seconds = (1 << _recoveryFailures.clamp(0, 5)).clamp(1, 30);
    _recoveryFailures++;
    _recoveryRetry = Timer(Duration(seconds: seconds), () {
      if (!mounted || !identical(session, current) || _pairingRejected) return;
      // A policy ACK may keep the same authority bearer. Let its own worker
      // commit, then reopen the visible stream without writing the ledger.
      if (gateway && Platform.isAndroid && failure.code == 'policy_pending') {
        _pairingRecoveryPending = false;
        _startRelayEvents();
      } else {
        unawaited(_recoverPairing(current, failure));
      }
    });
  }

  Future<void> _copyPrivateRecoveryVerifier(Session current) async {
    if (!gateway || !Platform.isAndroid) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.operatorPrivateVerifier),
        content: Text(l10n.operatorPrivateVerifierWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.operatorPrivateVerifier),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !identical(session, current)) return;
    final identity = await BridgeIdentity.derive(current.key);
    await clipboard.invokeMethod('copySensitive', {
      'text': jsonEncode({
        'bridgeId': current.bridgeId,
        'inviteToken': identity.inviteToken,
      }),
    });
  }

  Future<void> _operatorRecoveryDialog() async {
    final current = session;
    if (current == null || _leaving || _operatorWriteDone != null) return;
    _operatorWriteDone = Completer<void>();
    DeviceSigningIdentity identity;
    try {
      identity =
          current.authorization?.identity ??
          await _sessionStore.prepareUpgradeIdentity(
            current,
            createIfMissing: !(gateway && Platform.isAndroid),
          );
    } catch (_) {
      if (mounted) setState(() => error = l10n.operatorIdentityPending);
      _operatorWriteDone!.complete();
      _operatorWriteDone = null;
      return;
    }
    _operatorWriteDone!.complete();
    _operatorWriteDone = null;
    if (!mounted || _leaving) return;
    final certificate = TextEditingController();
    final policy = TextEditingController();
    final summary = jsonEncode({
      'server': current.server,
      'bridgeId': current.bridgeId,
      'deviceId': current.deviceId,
      'publicKey': identity.publicKey,
      'smsGateway': gateway,
    });
    final apply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.operatorRecoveryTitle),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.operatorRecoveryBody),
                const SizedBox(height: 12),
                SelectableText(summary),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: summary)),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(l10n.operatorRecoveryCopy),
                ),
                if (gateway && Platform.isAndroid)
                  TextButton(
                    onPressed: () => _copyPrivateRecoveryVerifier(current),
                    child: Text(l10n.operatorPrivateVerifier),
                  ),
                TextField(
                  controller: certificate,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.operatorRecoveryCertificate,
                  ),
                ),
                if (gateway && Platform.isAndroid)
                  TextField(
                    controller: policy,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: l10n.operatorRecoveryPolicy,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.operatorRecoveryApply),
          ),
        ],
      ),
    );
    if (apply == true && mounted && !_leaving && identical(session, current)) {
      _operatorWriteDone = Completer<void>();
      try {
        final auth = DeviceAuthorization(
          identity: identity,
          certificate: certificate.text.trim(),
          policyJson: policy.text.trim().isEmpty ? null : policy.text.trim(),
        );
        auth.validateFor(current.bridgeId, current.deviceId);
        if (auth.claims['smsGateway'] != gateway) {
          throw const StoredPairingUnavailable();
        }
        if (auth.authority) {
          AuthorizationCoordinator.validatePolicy(
            current.withCredentials(current.token, auth),
            auth.policyJson ?? '',
          );
        }
        // The relay validates the operator-issued certificate before it can
        // replace any known credential. The gateway worker owns actual install.
        final operation = auth.authority ? 'bootstrap' : 'resume';
        final payload = auth.authority ? auth.policyJson! : '';
        final challenge = await BridgeApi.forSession(
          current,
        ).authorizationChallenge(auth, operation, payload);
        await auth.challengeSignature(challenge, operation, payload);
        await _sessionStore.stageOperatorRecovery(
          current,
          auth.certificate,
          auth.policyJson,
          gateway: gateway,
        );
        _operatorRecoveryPending = true;
        _pairingRejected = false;
        if (gateway && Platform.isAndroid) {
          await _gatewayLifecycle.invokeMethod('wake');
        }
        unawaited(
          _recoverPairing(
            current,
            const RelayRequestException(
              409,
              'Operator recovery pending',
              code: 'gateway_unavailable',
            ),
          ),
        );
      } catch (_) {
        if (mounted) setState(() => error = l10n.operatorRecoveryRejected);
      } finally {
        _operatorWriteDone!.complete();
        _operatorWriteDone = null;
      }
    }
    certificate.dispose();
    policy.dispose();
  }

  Future<void> _connect(Future<Session> Function() action) async {
    if (_pairingUnavailable) {
      setState(
        () => error = (host.isDesktop
            ? l10n.desktopPairingUnavailable
            : l10n.pairingUnavailable),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (Platform.isAndroid) {
        // Quiesce any preserved worker before replacing pairing metadata.
        await _gatewayLifecycle.invokeMethod('stop');
        // A new enrollment must not inherit unpaired/previous-owner content.
        await platform.invokeMethod('clearQueues');
      }
      gateway = host.restoreGateway(gateway);
      if (gateway) await platform.invokeMethod('requestPermissions');
      session = await action();
      await _discoverySubscription?.cancel();
      await _discovery?.stop();
      // Persist metadata and credentials before enabling boot/receiver recovery.
      await _sessionStore.save(session!, gateway: gateway);
      _start();
      if (Platform.isAndroid && gateway) {
        final started = await _gatewayLifecycle.invokeMethod<bool>('start', {
          'bridgeId': session!.bridgeId,
          'deviceId': session!.deviceId,
        });
        if (started != true) error = l10n.gatewayRuntimeStopped;
      }
      unawaited(_requestNotificationPermission());
    } catch (exception) {
      error = _describeFailure(exception);
    }
    if (mounted) setState(() => busy = false);
    if (session != null && !_pairingRejected) {
      unawaited(_sync(messages: false, roster: false));
    }
  }

  void _start() {
    _pairingRejected = false;
    _syncRetry?.cancel();
    if (gateway && Platform.isAndroid) {
      unawaited(_refreshGatewayStatus());
    }
    if (Platform.isIOS) unawaited(_preparePush());
    _startRelayEvents(); // Subscribe before the initial catch-up closes its race.
    unawaited(_sync());
  }

  Future<void> _stopRelayEvents() async {
    _syncRetry?.cancel();
    final subscription = _relaySubscription;
    final events = _relayEvents;
    _relaySubscription = null;
    _relayEvents = null;
    _streamConnected = false;
    await subscription?.cancel();
    await events?.close();
  }

  void _startRelayEvents() {
    final current = session;
    if (current == null || _pairingRejected || _leaving) return;
    unawaited(_stopRelayEvents());
    final events = BridgeApi.forSession(current).events(current);
    _relayEvents = events;
    _relaySubscription = events.stream.listen(
      (event) {
        if (!mounted ||
            !identical(session, current) ||
            !identical(_relayEvents, events)) {
          return;
        }
        if (gateway && Platform.isAndroid) unawaited(_refreshGatewayStatus());
        if (event == RelayEvent.ready ||
            event == RelayEvent.resumed ||
            event == RelayEvent.heartbeat) {
          _streamConnected = relayOnline = true;
          if (event == RelayEvent.heartbeat) {
            setState(() {});
            return;
          }
        }
        if (event == RelayEvent.ready) {
          unawaited(_sync());
        } else if (event == RelayEvent.resumed ||
            event == RelayEvent.messages) {
          // A planned rotation only needs messages that arrived in its short
          // gap; the roster is unchanged because presence was not announced.
          unawaited(_sync(roster: false));
        } else if (event == RelayEvent.devices) {
          unawaited(_sync(messages: false));
        }
      },
      onError: (Object failure) {
        if (!mounted ||
            !identical(session, current) ||
            !identical(_relayEvents, events)) {
          return;
        }
        _streamConnected = relayOnline = false;
        if (gateway && Platform.isAndroid) unawaited(_refreshGatewayStatus());
        _syncRetry?.cancel();
        if (failure is RelayRequestException && failure.recoveryRequired) {
          unawaited(_recoverPairing(current, failure));
        } else if (failure is RelayRequestException && failure.status == 401) {
          _rejectPairing(
            legacy:
                failure.code == 'legacy_upgrade_required' ||
                failure.code == 'legacy_pairing_unrecoverable',
          );
        } else {
          setState(() => error = l10n.relayEventReconnecting);
        }
      },
    );
  }

  void _rejectPairing({bool legacy = false}) {
    _pairingRejected = true;
    _streamConnected = relayOnline = false;
    _syncRetry?.cancel();
    unawaited(_stopRelayEvents());
    _recoveryRetry?.cancel();
    if (mounted) {
      setState(
        () => error = legacy
            ? l10n.pairingLegacyMigration
            : l10n.relayPairingExpired,
      );
    }
  }

  Future<void> _sync({bool messages = true, bool roster = true}) async {
    _messagesPending |= messages;
    _rosterPending |= roster;
    final current = session;
    if (current == null ||
        busy ||
        _syncing ||
        _pairingRejected ||
        _pairingRecoveryPending) {
      return;
    }
    _syncing = true;
    _syncDone = Completer<void>();
    _syncRetry?.cancel();
    var postponed = false;
    try {
      while (mounted &&
          identical(session, current) &&
          !busy &&
          !_pairingRejected &&
          (_messagesPending || _rosterPending)) {
        final readMessages = _messagesPending, readRoster = _rosterPending;
        _messagesPending = _rosterPending = false;
        try {
          await _syncOnce(current, readMessages, readRoster);
          _syncFailures = 0;
        } catch (failure) {
          if (_pairingRejected || !identical(session, current)) break;
          postponed = true;
          _messagesPending |= readMessages;
          _rosterPending |= readRoster;
          if (failure is RelayRequestException && failure.recoveryRequired) {
            unawaited(_recoverPairing(current, failure));
          } else if (failure is RelayRequestException &&
              failure.status == 401) {
            _rejectPairing(
              legacy:
                  failure.code == 'legacy_upgrade_required' ||
                  failure.code == 'legacy_pairing_unrecoverable',
            );
          } else {
            relayOnline = _streamConnected;
            error = l10n.relayEventReconnecting;
            if (_streamConnected) {
              final seconds = (1 << _syncFailures.clamp(0, 5)).clamp(1, 30);
              _syncFailures++;
              _syncRetry = Timer(
                Duration(seconds: seconds),
                () => unawaited(_sync(messages: false, roster: false)),
              );
            }
          }
          break;
        }
      }
    } finally {
      _syncing = false;
      _syncDone!.complete();
      _syncDone = null;
      if (mounted) setState(() {});
      if (!postponed &&
          mounted &&
          !busy &&
          !_pairingRejected &&
          _streamConnected &&
          (_messagesPending || _rosterPending)) {
        unawaited(
          Future<void>.microtask(() => _sync(messages: false, roster: false)),
        );
      }
    }
  }

  Future<void> _syncOnce(
    Session current,
    bool readMessages,
    bool readRoster,
  ) async {
    final api = BridgeApi.forSession(current);
    if (gateway && Platform.isAndroid) {
      // The foreground service is the sole queue consumer and executor.
      phoneRole = await platform.invokeMethod<bool>('hasPhoneRole') ?? false;
    }
    if (readMessages) {
      // Only what this phone has not already decrypted.
      final page = await api.messagesSince(current, _lastMessageSeq);
      if (!mounted ||
          _pairingRejected ||
          _pairingRecoveryPending ||
          !identical(session, current)) {
        return;
      }
      if (page.oldestSeq > 0 &&
          _lastMessageSeq > 0 &&
          page.oldestSeq > _lastMessageSeq + 1) {
        Log.debug('Relay pruned past this cursor; keeping local history');
      }
      final clearEvents = <Map<String, dynamic>>[];
      for (final record in page.records) {
        try {
          final clear = await current.crypto.open(
            Map<String, dynamic>.from(record['envelope']),
          );
          if (!mounted ||
              _pairingRejected ||
              _pairingRecoveryPending ||
              !identical(session, current)) {
            return;
          }
          // An envelope sealed for a different bridge has no business here.
          if (clear['bridgeId'] != null &&
              clear['bridgeId'] != current.bridgeId) {
            Log.warn('Discarded an event sealed for another bridge');
            continue;
          }
          // The relay's own timestamp is display-only. Trusting it for ordering
          // or for the notification watermark would let the relay silence
          // future alerts by stamping one message far in the future.
          clear['relayReceivedAt'] = record['receivedAt'];
          // Prefer the sender identity sealed by the gateway; fall back to the
          // relay's attribution only for events predating protocol 2.
          clear['gatewayDeviceId'] ??= record['gatewayDeviceId'];
          if (clear['kind'] == 'gateway_state') {
            // Keep latest SIM state while incremental catches carry new events.
            _profilesByGateway[clear['gatewayDeviceId']] =
                (clear['simProfiles'] as List<dynamic>? ?? [])
                    .map(
                      (item) =>
                          Map<String, dynamic>.from(item as Map)
                            ..['gatewayDeviceId'] = clear['gatewayDeviceId'],
                    )
                    .toList();
          } else {
            clearEvents.add(clear);
          }
        } catch (exception) {
          Log.debug('Skipped an envelope this device cannot open');
        }
      }
      if (page.latestSeq > 0) _lastMessageSeq = page.latestSeq;
      if (clearEvents.isNotEmpty) {
        events = [...events, ...clearEvents];
        if (events.length > _maxLocalEvents) {
          events = events.sublist(events.length - _maxLocalEvents);
        }
      }
      try {
        await _notifyNewIncomingMessages(clearEvents);
      } catch (exception) {
        // Notification service failures must not discard decrypted inbox events
        // or turn a successful relay sync into a connection failure.
        Log.warn('Could not present incoming message notifications', exception);
      }
      simProfiles = _profilesByGateway.values.expand((items) => items).toList();
    }
    if (readRoster) {
      final roster = await api.roster(current);
      if (!mounted ||
          _pairingRejected ||
          _pairingRecoveryPending ||
          !identical(session, current)) {
        return;
      }
      devices = roster.devices;
      bridgeJoinable = roster.joinable;
      relayLatency = roster.latencyMs;
    }
    if (!mounted ||
        _pairingRejected ||
        _pairingRecoveryPending ||
        !identical(session, current)) {
      return;
    }
    await _syncPushRegistration(current, api);
    if (!mounted ||
        _pairingRejected ||
        _pairingRecoveryPending ||
        !identical(session, current)) {
      return;
    }
    relayOnline = _streamConnected;
    error = null;
  }

  /// Puts a freshly arrived code on the clipboard so the keyboard can offer it.
  ///
  /// iOS does not let a third-party app write into the QuickType "code from
  /// Messages" suggestion — only an AutoFill provider extension can do that —
  /// so the clipboard is the route that works today. The platform side marks
  /// the entry sensitive (Android) and gives it a short expiry (iOS).
  Future<void> _offerCodeToKeyboard(String code) async {
    if (!autoCopyCodes) return;
    try {
      try {
        await clipboard.invokeMethod('copyCode', {'code': code});
      } on MissingPluginException {
        if (!host.isDesktop) rethrow;
        await Clipboard.setData(ClipboardData(text: code));
      }
      Log.debug('Copied a delivered code to the clipboard');
    } catch (exception) {
      Log.warn('Could not copy the code to the clipboard', exception);
    }
  }

  String? _otpFrom(String? body) => verificationCodeFrom(body);

  Future<void> _notifyNewIncomingMessages(
    List<Map<String, dynamic>> clearEvents,
  ) async {
    if (!_notificationsReady || gateway || !mounted) return;
    final incoming = clearEvents.where(
      (item) => item['kind'] == 'sms' && item['direction'] == 'incoming',
    );
    // Ordered by the gateway's own sealed timestamp, never the relay's, which
    // is attacker-controlled.
    final dated =
        incoming
            .map(
              (item) => (
                item: item,
                at: DateTime.tryParse((item['occurredAt'] ?? '').toString()),
              ),
            )
            .where((entry) => entry.at != null)
            .toList()
          ..sort((a, b) => a.at!.compareTo(b.at!));
    if (dated.isEmpty) return;
    final notified = _notifiedMessages ??= await NotifiedMessages.load();
    final pushDelivered = await _deliveredPushIds();
    final keys = {
      for (final entry in dated) entry.item: messageKey(entry.item),
    };
    if (notified.isEmpty) {
      // First run on this device: adopt the existing history quietly.
      await notified.rememberAll(keys.values);
    } else {
      final fresh = dated
          .where((entry) => !notified.contains(keys[entry.item]!))
          .toList();
      // The newest code goes to the clipboard, so switching to the app that
      // asked for it puts the code one paste away.
      final newestCode = fresh
          .map((entry) => _otpFrom(entry.item['body']?.toString()))
          .whereType<String>()
          .lastOrNull;
      if (newestCode != null) await _offerCodeToKeyboard(newestCode);
      for (final entry in fresh) {
        final item = entry.item;
        // APNs already presented these alerts, but their codes remain eligible
        // for clipboard delivery when the app resumes.
        if (pushDelivered.contains(item['eventId'])) continue;
        if (!await _claimLocalNotification(item['eventId']?.toString())) {
          continue;
        }
        await _showMessageNotification(
          id: entry.at!.millisecondsSinceEpoch.remainder(0x7fffffff),
          sender: item['address']?.toString(),
          body: item['body']?.toString(),
          gatewayName: _gatewayName(item['gatewayDeviceId']),
        );
      }
      await notified.rememberAll(keys.values);
    }
  }

  /// Posts the notification for a delivered message.
  ///
  /// Preserve the verification code and original wording in the visible
  /// notification. Keyboard suggestions depend on the system; notification
  /// content alone does not provide native SMS AutoFill.
  Future<void> _showMessageNotification({
    required int id,
    required String? sender,
    required String? body,
    required String gatewayName,
  }) async {
    final otp = _otpFrom(body);
    await notifications.show(
      id: id,
      title: otp == null
          ? l10n.notificationMessageVia(gatewayName)
          : l10n.notificationOtpTitle(otp),
      body: '${sender ?? l10n.unknownSender} · ${body ?? ''}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _notificationChannelId,
          l10n.notificationChannelName,
          channelDescription: l10n.notificationChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          // Keep message bodies and codes off the lock screen.
          visibility: NotificationVisibility.private,
        ),
        linux: const LinuxNotificationDetails(),
        windows: const WindowsNotificationDetails(),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  /// A throwaway code that looks like a real one to the pattern matchers.
  String _testCode() => (100000 + Random.secure().nextInt(900000)).toString();

  /// Exercises the notification path on this phone only: post the same
  /// notification a delivered code produces, and copy it the same way.
  ///
  /// Nothing is sent to the relay, so this isolates the question of whether
  /// iOS surfaces the code above the keyboard.
  Future<void> _testCodeNotification() async {
    final allowed = await _requestNotificationPermission();
    if (!allowed) {
      // Posting anyway would look like it worked while iOS drops it.
      if (mounted) {
        setState(() => error = l10n.testNotificationsUnavailable);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.testNotificationsUnavailable),
            action: SnackBarAction(
              label: l10n.openSettings,
              onPressed: _openSystemNotificationSettings,
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }
    final code = _testCode();
    try {
      await _showMessageNotification(
        id: DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff),
        sender: l10n.testSender,
        body: l10n.testCodeBody(code),
        gatewayName: l10n.testSender,
      );
    } catch (_) {
      Log.warn('The notification service could not show a test alert');
      if (mounted) {
        setState(() => error = l10n.testNotificationsUnavailable);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.testNotificationsUnavailable)),
        );
      }
      return;
    }
    await _offerCodeToKeyboard(code);
    Log.info('Posted a test verification code notification');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.testCodeSent(code)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  /// Publishes a simulated incoming SMS through the real pipeline: sealed on
  /// this gateway, stored as ciphertext by the relay, and decrypted by the
  /// other phones — so it tests delivery end to end, not just the UI.
  Future<void> _testBridgeMessage() async {
    final current = session;
    if (current == null || !gateway || !Platform.isAndroid) return;
    final code = _testCode();
    final clear = bindEvent(
      {
        'kind': 'sms',
        'direction': 'incoming',
        'eventId': newCommandId(),
        'address': l10n.testSender,
        'body': l10n.testCodeBody(code),
        // Marked so a simulated message cannot be mistaken for one on the SIM.
        'simulated': true,
        'occurredAt': DateTime.now().toUtc().toIso8601String(),
      },
      bridgeId: current.bridgeId,
      senderDeviceId: current.deviceId,
    );
    try {
      await platform.invokeMethod('queueEvent', {'event': clear});
      await _gatewayLifecycle.invokeMethod('wake');
      Log.info(
        'Queued a simulated incoming message for the background gateway',
      );
      await _sync();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.testMessageQueued(code)),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  /// Leaving erases the only copy of this phone's bridge key, and pairing
  /// again needs the other phone in hand — so it asks first. It also sits one
  /// row below the test buttons, which is exactly where a stray tap lands.
  Future<void> _confirmLeaveBridge() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.logout,
              title: l10n.leaveBridgeTitle,
              subtitle: (host.isDesktop
                  ? l10n.desktopLeaveBridgeSubtitle
                  : l10n.leaveBridgeSubtitle),
            ),
            const SizedBox(height: 18),
            RemovalNote(
              text: (host.isDesktop
                  ? l10n.desktopLeaveBridgeWarning
                  : l10n.leaveBridgeWarning),
            ),
            if (session?.authorization?.authority == true) ...[
              const SizedBox(height: 10),
              RemovalNote(text: l10n.authorityRemovalWarning),
            ],
            if (gateway) ...[
              const SizedBox(height: 10),
              RemovalNote(text: l10n.leaveBridgeGatewayWarning),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              style: FilledButton.styleFrom(backgroundColor: Palette.fault),
              child: Text(l10n.leaveBridgeConfirm),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext, false),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) await _disconnect();
  }

  Future<void> _disconnect() async {
    _leaving = true;
    _recoveryRetry?.cancel();
    busy = true;
    await _stopRelayEvents();
    await _syncDone?.future;
    await _pairingRecoveryDone?.future;
    await _operatorWriteDone?.future;
    // A completed renewal may have persisted a fresher token while leaving.
    final latest = await _sessionStore.load();
    if (latest != null &&
        latest.session.deviceId == session?.deviceId &&
        latest.session.bridgeId == session?.bridgeId) {
      session = latest.session;
    }
    _gatewayCheckClock = null;
    _gatewayStatus = {};
    _gatewayChecksRevision.value++;
    if (mounted) setState(() {});
    // Permanent removal needs the gateway's durable policy ACK. Keep the
    // worker available to commit its own erase before quiescing it.
    final leaving = session;
    if (leaving != null) {
      try {
        await BridgeApi.forSession(leaving).leave(leaving);
      } catch (failure) {
        // A lost removal ACK can leave this device already denied by the
        // current durable policy. That explicit denial confirms remote absence.
        if (!(failure is RelayRequestException &&
            failure.status == 401 &&
            failure.code == 'device_revoked')) {
          busy = false;
          _leaving = false;
          if (mounted) setState(() => error = l10n.leavePolicyPending);
          _startRelayEvents();
          return;
        }
      }
    }
    if (Platform.isAndroid && gateway) {
      // Disable recovery and await the executor before revoking credentials.
      try {
        await _gatewayLifecycle.invokeMethod('stop');
      } catch (_) {
        // Failed quiescence must never erase the worker's pairing or outbox.
        busy = false;
        _leaving = false;
        _start();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.gatewayStopFailed)));
        }
        return;
      }
    }
    if (Platform.isAndroid) {
      try {
        await platform.invokeMethod('clearQueues');
      } catch (_) {
        busy = false;
        _leaving = false;
        // The worker already stopped; a kept pairing must keep receiving.
        if (gateway && leaving != null) {
          try {
            await _gatewayLifecycle.invokeMethod<bool>('start', {
              'bridgeId': leaving.bridgeId,
              'deviceId': leaving.deviceId,
            });
          } catch (failure) {
            Log.warn(
              'Could not restart the gateway after a failed leave',
              failure,
            );
          }
        }
        _start();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.gatewayClearFailed)));
        }
        return;
      }
    }
    session = null;
    busy = false;
    _leaving = false;
    _pairingRejected = false;
    _pairingRecoveryPending = false;
    _recoveryRetry?.cancel();
    _messagesPending = _rosterPending = false;
    events = [];
    devices = [];
    simProfiles = [];
    _lastMessageSeq = 0;
    _profilesByGateway.clear();
    _notifiedMessages = null;
    await (await ExecutedCommands.load()).clear();
    await (await NotifiedMessages.load()).clear();
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      'server',
      'deviceId',
      'bridgeId',
      'gateway',
      'sessionReady',
      'autoCopyCodes',
    ]) {
      await prefs.remove(key);
    }
    await _sessionStore.clear();
    if (Platform.isIOS) {
      _pushBridgeReady = false;
      _registeredPushToken = null;
      await clipboard.invokeMethod('clearPushBridge');
    }
    Log.info('Left the bridge and cleared local state');
    unawaited(_discoverRelays());
    if (mounted) setState(() {});
  }

  GatewayReadiness get _gatewayReadiness => GatewayReadiness(
    status: _gatewayStatus,
    nativeCheckAgeMs: _gatewayCheckClock?.elapsedMilliseconds,
    confirmedFingerprint: _autostartConfirmedFingerprint,
    confirmedAt: _autostartConfirmedAt,
  );

  Future<void> _refreshGatewayStatus() async {
    if (!Platform.isAndroid ||
        !gateway ||
        session == null ||
        _checkingGateway) {
      return;
    }
    _checkingGateway = true;
    try {
      _gatewayStatus =
          await _gatewayLifecycle
              .invokeMapMethod<String, dynamic>('status')
              .timeout(const Duration(seconds: 3)) ??
          {};
      _gatewayCheckClock = _gatewayStatus.isEmpty
          ? null
          : (Stopwatch()..start());
    } catch (_) {
      // A failed device check must never leave a cached healthy result visible.
      _gatewayStatus = {};
      _gatewayCheckClock = null;
    } finally {
      _checkingGateway = false;
      if (mounted) {
        _gatewayChecksRevision.value++;
        setState(() {});
      }
    }
  }

  String get _gatewayAttentionText => switch (_gatewayReadiness.attention) {
    GatewayAttention.receiveSms => l10n.gatewayReceiveMissing,
    GatewayAttention.sendSms => l10n.gatewaySendMissing,
    GatewayAttention.simAccess => l10n.gatewaySimMissing,
    GatewayAttention.stopped => l10n.gatewayRuntimeStopped,
    GatewayAttention.unauthorized => l10n.gatewayRuntimeUnauthorized,
    GatewayAttention.unpaired => l10n.gatewayRuntimeUnpaired,
    GatewayAttention.backgroundRestricted => l10n.gatewayBackgroundRestricted,
    GatewayAttention.battery => l10n.gatewayBatteryRestricted,
    GatewayAttention.notifications => l10n.gatewayNotificationsHidden,
    GatewayAttention.autostart => l10n.gatewayAutostartPending,
    GatewayAttention.reconnecting => l10n.gatewayRuntimeWaiting,
    GatewayAttention.queued => l10n.gatewayQueuedWarning(
      _gatewayReadiness.pending,
    ),
    GatewayAttention.notChecked => l10n.gatewayNotChecked,
    null => l10n.gatewayCheckedNow,
  };

  Widget _gatewayReadinessCard() {
    final checks = _gatewayReadiness;
    final attention = checks.attention != null;
    return Card(
      color: attention
          ? (checks.blocked ? Palette.faultSoft : Palette.chipSoft)
          : Palette.card,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              attention ? l10n.gatewayNeedsAttention : l10n.gatewayChecksTitle,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(_gatewayAttentionText, style: const TextStyle(height: 1.4)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _showGatewayChecks,
                child: Text(l10n.gatewayReviewSetup),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _gatewaySettingsAction(String method) async {
    try {
      await _gatewayLifecycle.invokeMethod(method);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.gatewaySettingsUnavailable)),
        );
      }
    }
    await _refreshGatewayStatus();
  }

  Future<void> _requestGatewayPermissions() async {
    try {
      await _gatewayLifecycle.invokeMethod('requestRequiredPermissions');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.gatewayCheckActionFailed)));
      }
    }
    await _refreshGatewayStatus();
  }

  Future<void> _fixGatewayNotifications() async {
    try {
      await _requestNotificationPermission();
      await _refreshGatewayStatus();
      // A granted app permission does not imply the foreground channel is visible.
      if (_gatewayReadiness.notifications == false) {
        await clipboard.invokeMethod('openNotificationSettings');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.gatewaySettingsUnavailable)),
        );
      }
    }
  }

  Future<void> _confirmGatewayAutostart() async {
    final fingerprint = _gatewayStatus['deviceBuildFingerprint'];
    if (fingerprint is! String || fingerprint.isEmpty) return;
    try {
      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'gatewayAutostartConfirmedFingerprint',
        fingerprint,
      );
      await prefs.setInt(
        'gatewayAutostartConfirmedAt',
        now.millisecondsSinceEpoch,
      );
      _autostartConfirmedFingerprint = fingerprint;
      _autostartConfirmedAt = now;
      if (mounted) {
        _gatewayChecksRevision.value++;
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.gatewayCheckActionFailed)));
      }
    }
  }

  Widget _gatewayBooleanCheck({
    required String title,
    required bool? passed,
    required String positive,
    required String negative,
    IconData icon = Icons.fact_check_outlined,
    bool danger = false,
  }) => SettingsTile(
    icon: icon,
    title: title,
    subtitle: passed == null
        ? l10n.gatewayNotChecked
        : (passed ? positive : negative),
    trailing: Icon(
      passed == null
          ? Icons.help_outline
          : (passed ? Icons.check_circle_outline : Icons.warning_amber_rounded),
      color: passed == null
          ? Palette.haze
          : (passed ? Palette.signal : (danger ? Palette.fault : Palette.chip)),
    ),
  );

  Future<void> _showGatewayChecks() async {
    unawaited(_refreshGatewayStatus());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: _gatewayChecksRevision,
            builder: (_, _, _) {
              final checks = _gatewayReadiness;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SheetHeader(
                    icon: Icons.fact_check_outlined,
                    title: l10n.gatewayChecksTitle,
                    subtitle: l10n.gatewayChecksSubtitle,
                  ),
                  const SizedBox(height: 14),
                  _gatewayBooleanCheck(
                    title: l10n.gatewayCheckReceive,
                    danger: true,
                    passed: checks.receiveSms,
                    positive: l10n.gatewayPermissionGranted,
                    negative: l10n.gatewayReceiveMissing,
                  ),
                  _gatewayBooleanCheck(
                    title: l10n.gatewayCheckSend,
                    danger: true,
                    passed: checks.sendSms,
                    positive: l10n.gatewayPermissionGranted,
                    negative: l10n.gatewaySendMissing,
                  ),
                  _gatewayBooleanCheck(
                    title: l10n.gatewayCheckSim,
                    danger: true,
                    passed: checks.simAccess,
                    positive: l10n.gatewayPermissionGranted,
                    negative: l10n.gatewaySimMissing,
                  ),
                  if (checks.receiveSms != true ||
                      checks.sendSms != true ||
                      checks.simAccess != true)
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _requestGatewayPermissions,
                          child: Text(l10n.gatewayAllowPermissions),
                        ),
                        TextButton(
                          onPressed: () =>
                              _gatewaySettingsAction('openPermissionSettings'),
                          child: Text(l10n.gatewayOpenPermissions),
                        ),
                      ],
                    ),
                  const Divider(),
                  SettingsTile(
                    icon: Icons.sync_outlined,
                    title: l10n.gatewayRuntimeTitle,
                    subtitle: _gatewayRuntimeSummary,
                    trailing: Icon(
                      checks.runtimeConnected
                          ? Icons.check_circle_outline
                          : Icons.schedule,
                      color: checks.runtimeConnected
                          ? Palette.signal
                          : Palette.haze,
                    ),
                  ),
                  if (_gatewayRestartOffered)
                    TextButton(
                      onPressed: _gatewayRestarting ? null : _restartGateway,
                      child: Text(l10n.gatewayRestart),
                    ),
                  if (checks.attention == GatewayAttention.unauthorized ||
                      checks.attention == GatewayAttention.unpaired)
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        if (mounted) setState(() => tab = 2);
                      },
                      child: Text(l10n.gatewayReviewPairing),
                    ),
                  _gatewayBooleanCheck(
                    title: l10n.gatewayCheckBackground,
                    passed: checks.backgroundRestricted == null
                        ? null
                        : !checks.backgroundRestricted!,
                    positive: l10n.gatewayBackgroundAllowed,
                    negative: l10n.gatewayBackgroundRestricted,
                  ),
                  if (checks.backgroundRestricted == true)
                    TextButton(
                      onPressed: () =>
                          _gatewaySettingsAction('openPermissionSettings'),
                      child: Text(l10n.openSettings),
                    ),
                  _gatewayBooleanCheck(
                    title: l10n.gatewayBatteryTitle,
                    passed: checks.batteryExempt,
                    positive: l10n.gatewayBatteryUnrestricted,
                    negative: l10n.gatewayBatteryRestricted,
                  ),
                  if (checks.batteryExempt != true)
                    TextButton(
                      onPressed: () =>
                          _gatewaySettingsAction('openBatterySettings'),
                      child: Text(l10n.openSettings),
                    ),
                  const Divider(),
                  _gatewayBooleanCheck(
                    title: l10n.settingsNotifications,
                    passed: checks.notifications,
                    positive: l10n.gatewayNotificationsVisible,
                    negative: l10n.gatewayNotificationsHidden,
                  ),
                  if (checks.notifications != true)
                    TextButton(
                      onPressed: _fixGatewayNotifications,
                      child: Text(l10n.openSettings),
                    ),
                  if (checks.autostartRequired) ...[
                    const Divider(),
                    SettingsTile(
                      icon: Icons.power_settings_new_outlined,
                      title: l10n.gatewayAutostartTitle,
                      subtitle: checks.autostartConfirmedByUser
                          ? l10n.gatewayAutostartManual
                          : l10n.gatewayAutostartPending,
                      trailing: Icon(
                        checks.autostartConfirmedByUser
                            ? Icons.person_outline
                            : Icons.help_outline,
                        color: Palette.haze,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _openGatewayAutostartSettings,
                          child: Text(l10n.gatewayOpenAutostart),
                        ),
                        if (!checks.autostartConfirmedByUser)
                          OutlinedButton(
                            onPressed:
                                _gatewayStatus['deviceBuildFingerprint']
                                    is String
                                ? _confirmGatewayAutostart
                                : null,
                            child: Text(l10n.gatewayConfirmAutostart),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _refreshGatewayStatus,
                    child: Text(l10n.gatewayCheckAgain),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openGatewayAutostartSettings() =>
      _gatewaySettingsAction('openAppSettings');

  bool get _gatewayRestartOffered =>
      _gatewayReadiness.nativeCheckRecent &&
      ![
        'unauthorized',
        'unpaired',
        'migration_required',
      ].contains(_gatewayStatus['state']) &&
      (_gatewayStatus['running'] == false || _gatewayStatus['ready'] == false);

  Future<void> _restartGateway() async {
    final current = session;
    if (current == null || _gatewayRestarting) return;
    setState(() => _gatewayRestarting = true);
    try {
      final started = await _gatewayLifecycle.invokeMethod<bool>('start', {
        'bridgeId': current.bridgeId,
        'deviceId': current.deviceId,
      });
      if (started != true && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.gatewayRestartDescription)));
      }
      await _sync();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.gatewayRuntimeStopped)));
      }
    } finally {
      if (mounted) setState(() => _gatewayRestarting = false);
    }
  }

  String get _gatewayRuntimeSummary {
    final lastSync = DateTime.tryParse(
      (_gatewayStatus['lastSuccessAt'] ?? _gatewayStatus['lastSync'])
              ?.toString() ??
          '',
    );
    final time = lastSync == null
        ? l10n.gatewayNotSynced
        : MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(lastSync.toLocal()));
    return l10n.gatewayRuntimeDetails(
      _gatewayRuntimeDescription,
      (_gatewayStatus['pending'] as num?)?.toInt() ?? 0,
      time,
    );
  }

  String get _gatewayRuntimeDescription {
    if (!_gatewayReadiness.nativeCheckRecent) return l10n.gatewayNotChecked;
    final state = _gatewayStatus['state'];
    if (state == 'migration_required') return l10n.pairingLegacyMigration;
    if (state == 'unauthorized') return l10n.gatewayRuntimeUnauthorized;
    if (state == 'unpaired') return l10n.gatewayRuntimeUnpaired;
    if (state == 'permissions') return l10n.gatewayRuntimePermissions;
    if (_gatewayStatus['running'] != true) return l10n.gatewayRuntimeStopped;
    final checks = _gatewayReadiness;
    if (checks.receiveSms == false ||
        checks.sendSms == false ||
        checks.simAccess == false) {
      return l10n.gatewayRuntimePermissions;
    }
    if (checks.runtimeConnected) return l10n.gatewayRuntimeRunning;
    return l10n.gatewayRuntimeWaiting;
  }

  List<Map<String, dynamic>> get _gateways => devices
      .cast<Map<String, dynamic>>()
      .where((item) => item['capabilities']?['smsGateway'] == true)
      .toList();

  String _gatewayName(String? id) =>
      _gateways
          .where((item) => item['id'] == id)
          .map(
            (item) => item['name']?.toString() ?? l10n.defaultDeviceNameAndroid,
          )
          .firstOrNull ??
      l10n.defaultDeviceNameAndroid;

  Future<void> _sendCommand(String type) async {
    final selectedSim = await _selectSim();
    if (!mounted || selectedSim == null) return;
    final number = TextEditingController();
    final body = TextEditingController();
    final isSms = type == 'send_sms';
    final gatewayLabel = _gatewayName(selectedSim['gatewayDeviceId']);
    final simLabel = selectedSim['displayName']?.toString() ?? 'SIM';
    final submit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(
                icon: isSms ? Icons.chat_bubble_outline : Icons.phone_outlined,
                title: isSms ? l10n.smsSheetTitle : l10n.callSheetTitle,
                subtitle: isSms
                    ? l10n.smsSheetSubtitle(gatewayLabel, simLabel)
                    : l10n.callSheetSubtitle(gatewayLabel, simLabel),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: number,
                keyboardType: TextInputType.phone,
                style: mono(size: 15),
                decoration: InputDecoration(labelText: l10n.phoneNumberLabel),
              ),
              if (isSms) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: body,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: l10n.messageLabel),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                child: Text(isSms ? l10n.encryptAndSend : l10n.dialOnGateway),
              ),
            ],
          ),
        ),
      ),
    );
    if (submit != true || session == null) return;
    if (number.text.trim().isEmpty || (isSms && body.text.trim().isEmpty)) {
      setState(
        () => error = isSms ? l10n.errorSmsFields : l10n.errorPhoneField,
      );
      return;
    }
    try {
      final target = devices
          .cast<Map<String, dynamic>>()
          .where((item) => item['id'] == selectedSim['gatewayDeviceId'])
          .firstOrNull;
      if (target == null) throw Exception(l10n.errorNoGateway);
      // The gateway is named inside the sealed payload, not just in the relay
      // request, so the relay cannot route this to a different SIM.
      final clear = buildCommand(
        type: type,
        bridgeId: session!.bridgeId,
        senderDeviceId: session!.deviceId,
        targetDeviceId: target['id'] as String,
        issuedAt: DateTime.now(),
        payload: {
          'address': number.text.trim(),
          if (isSms) 'body': body.text.trim(),
          'subscriptionId': selectedSim['subscriptionId'],
          'phoneAccountId': selectedSim['phoneAccountId'],
        },
      );
      await BridgeApi.forSession(
        session!,
      ).command(session!, target['id'], await session!.crypto.seal(clear));
      Log.info('Queued $type for gateway ${Log.preview(target['id'])}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isSms ? l10n.queuedSms : l10n.queuedCall)),
        );
      }
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  Future<Map<String, dynamic>?> _selectSim() async {
    final routes = <Map<String, dynamic>>[];
    for (final gatewayDevice in _gateways) {
      final profiles = simProfiles
          .where((profile) => profile['gatewayDeviceId'] == gatewayDevice['id'])
          .toList();
      if (profiles.isEmpty) {
        routes.add({
          'gatewayDeviceId': gatewayDevice['id'],
          'displayName': l10n.defaultLine,
          'carrierName': l10n.simDetailsUnavailable,
          'phoneNumber': '',
        });
      } else {
        routes.addAll(profiles);
      }
    }
    if (routes.length == 1) return routes.first;
    if (routes.isEmpty) {
      setState(() => error = l10n.errorNoGateway);
      return null;
    }
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.sim_card_outlined,
              title: l10n.chooseSim,
              subtitle: l10n.chooseSimSubtitle,
            ),
            const SizedBox(height: 16),
            ...routes.map(
              (profile) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ActionTile(
                  icon: Icons.sim_card_rounded,
                  title:
                      '${_gatewayName(profile['gatewayDeviceId'])} · ${profile['displayName'] ?? l10n.simNumber(((profile['slotIndex'] as int?) ?? 0) + 1)}',
                  subtitle: [
                    profile['carrierName'] ?? l10n.unknownCarrier,
                    if ((profile['phoneNumber'] ?? '').toString().isNotEmpty)
                      profile['phoneNumber'],
                    if (profile['slotIndex'] != null)
                      l10n.simSlot(((profile['slotIndex'] as int?) ?? 0) + 1),
                  ].join(' · '),
                  onTap: () => Navigator.pop(sheetContext, profile),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _controlRemoteCall(
    Map<String, dynamic> event,
    String action,
  ) async {
    if (session == null) return;
    try {
      final targetId = event['gatewayDeviceId'];
      if (targetId == null) throw Exception(l10n.errorCallGateway);
      await BridgeApi.forSession(session!).command(
        session!,
        targetId,
        await session!.crypto.seal(
          buildCommand(
            type: 'control_call',
            bridgeId: session!.bridgeId,
            senderDeviceId: session!.deviceId,
            targetDeviceId: targetId as String,
            issuedAt: DateTime.now(),
            payload: {'action': action, 'callId': event['callId']},
          ),
        ),
      );
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  void _showCompose() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.add_rounded,
              title: l10n.composeTitle,
              subtitle: l10n.composeSubtitle,
            ),
            const SizedBox(height: 16),
            ActionTile(
              icon: Icons.chat_bubble_outline,
              title: l10n.actionSms,
              subtitle: l10n.actionSmsSubtitle,
              onTap: () {
                Navigator.pop(sheetContext);
                _sendCommand('send_sms');
              },
            ),
            const SizedBox(height: 10),
            ActionTile(
              icon: Icons.phone_outlined,
              title: l10n.actionCall,
              subtitle: l10n.actionCallSubtitle,
              onTap: () {
                Navigator.pop(sheetContext);
                _sendCommand('place_call');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Blocks screenshots and the recent-apps thumbnail while a secret is shown.
  Future<void> _setSecureScreen(bool secure) async {
    if (!Platform.isAndroid) return;
    try {
      await platform.invokeMethod('setSecureScreen', {'secure': secure});
    } catch (exception) {
      Log.warn('Could not change screen capture protection', exception);
    }
  }

  Future<void> _showPairing() async {
    // The QR encodes the bridge root key, so nothing here may reach a
    // screenshot, a screen recorder, or the app switcher preview.
    await _setSecureScreen(true);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.person_add_alt_1_outlined,
              title: (host.isDesktop ? l10n.desktopPairTitle : l10n.pairTitle),
              subtitle: l10n.pairSubtitle,
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: ShapeDecoration(
                color: Palette.card,
                shape: simShape(
                  cut: 30,
                  base: 12,
                  side: const BorderSide(color: Palette.chip, width: 1.6),
                ),
              ),
              child: QrImageView(data: session!.invitation, size: 210),
            ),
            const SizedBox(height: 20),
            SecretField(
              label: l10n.recoveryCodeLabel,
              value: session!.recoveryCode,
              copiedMessage: l10n.labelCopied(l10n.recoveryCodeLabel),
              copyTooltip: l10n.copyTooltip,
            ),
            const SizedBox(height: 10),
            SecretField(
              label: l10n.relayUrlLabel,
              value: session!.server,
              copiedMessage: l10n.labelCopied(l10n.relayUrlLabel),
              copyTooltip: l10n.copyTooltip,
            ),
            const SizedBox(height: 14),
            Text(
              (host.isDesktop ? l10n.desktopPairWarning : l10n.pairWarning),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Palette.haze,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
    await _setSecureScreen(false);
  }

  /// Shown only while the stored session is being looked up, so a paired
  /// phone never flashes the setup form on launch.
  Widget _buildRestoring() => Scaffold(
    backgroundColor: Palette.board,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandMark(size: 56),
          const SizedBox(height: 26),
          SizedBox(
            width: 90,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.white.withValues(alpha: .14),
              valueColor: const AlwaysStoppedAnimation(Palette.chip),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_restoring) return _buildRestoring();
    if (session == null) return _buildOnboarding();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Tablets and desktop windows share the wide layout: a side rail and
        // a readable, capped content width instead of a stretched phone UI.
        final wide = constraints.maxWidth >= _desktopBreakpoint;
        final content = IndexedStack(
          index: tab,
          children: [_activityTab(), _devicesTab(), _settingsTab()],
        );
        final scaffold = Scaffold(
          appBar: wide
              ? null
              : AppBar(
                  titleSpacing: 20,
                  title: Row(
                    children: [
                      const BrandMark(size: 32),
                      const SizedBox(width: 11),
                      Text(l10n.appTitle, style: display(size: 21)),
                    ],
                  ),
                  actions: [
                    IconButton(
                      tooltip: l10n.pairDeviceTooltip,
                      onPressed: _showPairing,
                      icon: const Icon(Icons.person_add_alt_1_outlined),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
          body: SafeArea(
            child: Row(
              children: [
                if (wide) _desktopRail(),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: host.isDesktop || wide
                            ? (tab == 0
                                  ? _desktopContentWidth
                                  : _desktopFormWidth)
                            : double.infinity,
                      ),
                      child: content,
                    ),
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: tab == 0 && !wide
              ? FloatingActionButton.extended(
                  onPressed: _showCompose,
                  backgroundColor: Palette.chip,
                  foregroundColor: Palette.board,
                  elevation: 2,
                  shape: simShape(cut: 20, base: 8),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(
                    l10n.fabNew,
                    style: const TextStyle(
                      fontFamily: Fonts.display,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                )
              : null,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (value) => setState(() => tab = value),
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.inbox_outlined),
                      selectedIcon: const Icon(Icons.inbox_rounded),
                      label: l10n.tabActivity,
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.devices_outlined),
                      selectedIcon: const Icon(Icons.devices_rounded),
                      label: l10n.tabDevices,
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.tune_outlined),
                      selectedIcon: const Icon(Icons.tune_rounded),
                      label: l10n.tabSettings,
                    ),
                  ],
                ),
        );
        if (!host.isDesktop) return scaffold;
        // Desktop keyboard navigation: ⌘/Ctrl+N composes, ⌘/Ctrl+1–3 switch tabs.
        final macOS = Platform.isMacOS;
        SingleActivator shortcut(LogicalKeyboardKey key) =>
            SingleActivator(key, meta: macOS, control: !macOS);
        return CallbackShortcuts(
          bindings: {
            shortcut(LogicalKeyboardKey.keyN): _showCompose,
            shortcut(LogicalKeyboardKey.digit1): () => setState(() => tab = 0),
            shortcut(LogicalKeyboardKey.digit2): () => setState(() => tab = 1),
            shortcut(LogicalKeyboardKey.digit3): () => setState(() => tab = 2),
          },
          child: Focus(autofocus: true, child: scaffold),
        );
      },
    );
  }

  Widget _desktopRail() => NavigationRail(
    extended: true,
    minExtendedWidth: 216,
    backgroundColor: Palette.board,
    indicatorColor: Palette.chip,
    selectedIconTheme: const IconThemeData(color: Palette.board),
    unselectedIconTheme: const IconThemeData(color: Palette.line),
    selectedLabelTextStyle: const TextStyle(
      fontFamily: Fonts.display,
      color: Palette.chip,
      fontWeight: FontWeight.w700,
    ),
    unselectedLabelTextStyle: const TextStyle(
      fontFamily: Fonts.display,
      color: Palette.line,
    ),
    leading: Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 26),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandMark(size: 32),
          const SizedBox(width: 10),
          Text(l10n.appTitle, style: display(size: 19, color: Colors.white)),
        ],
      ),
    ),
    trailing: Padding(
      padding: const EdgeInsets.only(top: 24),
      child: TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: Palette.chip),
        onPressed: _showPairing,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: Text(l10n.desktopPairTitle),
      ),
    ),
    selectedIndex: tab,
    onDestinationSelected: (value) => setState(() => tab = value),
    destinations: [
      NavigationRailDestination(
        icon: const Icon(Icons.inbox_outlined),
        selectedIcon: const Icon(Icons.inbox_rounded),
        label: Text(l10n.tabActivity),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.devices_outlined),
        selectedIcon: const Icon(Icons.devices_rounded),
        label: Text(l10n.tabDevices),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.tune_outlined),
        selectedIcon: const Icon(Icons.tune_rounded),
        label: Text(l10n.tabSettings),
      ),
    ],
  );

  Widget _buildOnboarding() {
    final hero = Container(
      padding: EdgeInsets.fromLTRB(
        24,
        MediaQuery.paddingOf(context).top + 28,
        24,
        36,
      ),
      decoration: ShapeDecoration(
        gradient: const LinearGradient(
          colors: [Palette.board, Palette.boardRaised],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: const BeveledRectangleBorder(
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(40),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BrandMark(size: 50),
          const SizedBox(height: 32),
          Text(
            host.isDesktop
                ? l10n.desktopOnboardingHeadline
                : l10n.onboardingHeadline,
            style: display(size: 40, color: Colors.white, height: 1.02),
          ),
          const SizedBox(height: 14),
          Text(
            host.isDesktop
                ? l10n.desktopOnboardingTagline
                : l10n.onboardingTagline,
            style: TextStyle(
              color: Colors.white.withValues(alpha: .72),
              height: 1.45,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TrustPill(icon: Icons.lock_outline, text: l10n.trustEncrypted),
              TrustPill(
                icon: Icons.vpn_key_outlined,
                text: (host.isDesktop
                    ? l10n.desktopTrustKeys
                    : l10n.trustKeysLocal),
              ),
            ],
          ),
        ],
      ),
    );
    final form = Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (host.isDesktop ? l10n.desktopSetupTitle : l10n.setupTitle),
            style: display(size: 21),
          ),
          const SizedBox(height: 6),
          Text(
            host.isDesktop ? l10n.desktopSetupSubtitle : l10n.setupSubtitle,
            style: const TextStyle(color: Palette.haze),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: server,
            keyboardType: TextInputType.url,
            style: mono(size: 14),
            decoration: InputDecoration(
              labelText: l10n.relayUrlLabel,
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 10),
          if (discoveredRelays.isNotEmpty)
            ...discoveredRelays.map((relay) {
              final url = _relayUrl(relay);
              final selected = server.text == url;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Palette.card,
                  shape: simShape(
                    cut: 16,
                    base: 7,
                    side: BorderSide(
                      color: selected ? Palette.chip : Palette.line,
                      width: selected ? 1.6 : 1,
                    ),
                  ),
                  child: ListTile(
                    shape: simShape(cut: 16, base: 7),
                    leading: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        color: Palette.chipSoft,
                        shape: simShape(cut: 13, base: 6),
                      ),
                      child: const Icon(
                        Icons.lan_outlined,
                        color: Palette.ink,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      relay.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(url, style: mono(size: 11.5)),
                    trailing: selected
                        ? const Icon(Icons.check_circle, color: Palette.signal)
                        : const Icon(Icons.chevron_right),
                    onTap: () => setState(() => server.text = url),
                  ),
                ),
              );
            })
          else
            Row(
              children: [
                if (discoveringRelays)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.wifi_find, size: 18, color: Palette.haze),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    discoveringRelays
                        ? l10n.discoverySearching
                        : l10n.discoveryNone,
                    style: const TextStyle(color: Palette.haze, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: discoveringRelays ? null : _discoverRelays,
                  child: Text(l10n.discoveryRetry),
                ),
              ],
            ),
          const SizedBox(height: 12),
          if (host.canGateway && gateway) ...[
            TextField(
              controller: relayKey,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.relayKeyLabel,
                prefixIcon: const Icon(Icons.key_outlined),
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: deviceName,
            decoration: InputDecoration(
              labelText: l10n.deviceNameLabel,
              prefixIcon: Icon(
                host.isDesktop
                    ? Icons.desktop_windows_outlined
                    : Icons.smartphone_outlined,
              ),
            ),
          ),
          if (host.canGateway) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xffE9E6DB),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ModeButton(
                      selected: gateway,
                      icon: Icons.sim_card_outlined,
                      text: l10n.roleGateway,
                      onTap: () => setState(() => gateway = true),
                    ),
                  ),
                  Expanded(
                    child: ModeButton(
                      selected: !gateway,
                      icon: Icons.phone_iphone_outlined,
                      text: l10n.roleClient,
                      onTap: () => setState(() => gateway = false),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: ShapeDecoration(
                color: Palette.card,
                shape: simShape(
                  cut: 20,
                  base: 8,
                  side: const BorderSide(color: Palette.line),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: Palette.chipSoft,
                      shape: simShape(cut: 13, base: 6),
                    ),
                    child: Icon(
                      host.isDesktop
                          ? Icons.desktop_windows
                          : Icons.phone_iphone,
                      color: Palette.ink,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.isDesktop
                              ? l10n.desktopClientTitle
                              : l10n.iosClientTitle,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          host.isDesktop
                              ? l10n.desktopClientBody
                              : l10n.iosClientBody,
                          style: const TextStyle(
                            color: Palette.haze,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (host.isDesktop) ...[
            const SizedBox(height: 14),
            _desktopAvailabilityCard(),
          ],
          if (error != null) ...[
            const SizedBox(height: 14),
            ErrorBanner(message: error!),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy
                ? null
                : host.canGateway && gateway
                ? _create
                : _manualJoin,
            child: busy
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    host.canGateway && gateway
                        ? l10n.createBridge
                        : l10n.pairExistingBridge,
                  ),
          ),
          // The primary button already opens code entry unless it creates a
          // bridge; never offer the same action twice.
          if (host.canScanInvitation || (host.canGateway && gateway)) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (host.canScanInvitation)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(l10n.scanInvitation),
                    ),
                  ),
                if (host.canScanInvitation && host.canGateway && gateway)
                  const SizedBox(width: 10),
                if (host.canGateway && gateway)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : _manualJoin,
                      icon: const Icon(Icons.keyboard_alt_outlined),
                      label: Text(l10n.enterCode),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (host.isDesktop && constraints.maxWidth >= _desktopBreakpoint) {
              return SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 420, child: hero),
                          const SizedBox(width: 24),
                          Expanded(child: form),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: host.isDesktop || constraints.maxWidth >= 720
                      ? 680
                      : double.infinity,
                ),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [hero, form],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _desktopAvailabilityCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.desktopAvailabilityTitle,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.desktopAvailabilityBody,
            style: const TextStyle(color: Palette.haze, height: 1.4),
          ),
          if (host.target == TargetPlatform.windows ||
              host.target == TargetPlatform.linux) ...[
            const SizedBox(height: 10),
            Text(
              l10n.desktopClipboardBody,
              style: const TextStyle(color: Palette.haze, height: 1.4),
            ),
          ],
        ],
      ),
    ),
  );

  bool _wideLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

  Widget _activityTab() => RefreshIndicator(
    onRefresh: _sync,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 100),
      children: [
        LineCard(
          online: relayOnline,
          statusText: relayOnline
              ? (gateway && Platform.isAndroid
                    ? l10n.gatewayRelayConnected
                    : l10n.bridgeHealthy)
              : l10n.bridgeOffline,
          detailText: relayOnline
              ? l10n.relayLatency('${relayLatency ?? '—'}')
              : l10n.reconnecting,
          metrics: [
            ('${devices.length}', l10n.metricDevices),
            (
              _gateways.any(_isOnline) ? l10n.statusOnline : l10n.statusOffline,
              l10n.metricGateway,
            ),
          ],
        ),
        if (gateway && Platform.isAndroid) ...[
          const SizedBox(height: 12),
          _gatewayReadinessCard(),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          ErrorBanner(message: error!),
        ],
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(l10n.recentActivity, style: display(size: 20)),
            ),
            Text(
              l10n.eventsCount(events.length),
              style: const TextStyle(color: Palette.haze, fontSize: 13),
            ),
            // Wide layouts put compose in the header instead of a floating
            // button that covers the message list.
            if (_wideLayout(context)) ...[
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: _showCompose,
                // The theme's full-width buttons cannot size inside a row.
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(l10n.fabNew),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        if (events.isEmpty)
          EmptyState(
            icon: Icons.forum_outlined,
            title: l10n.emptyActivityTitle,
            body: l10n.emptyActivityBody,
          )
        else
          ...events.reversed.map(_eventCard),
      ],
    ),
  );

  Widget _eventCard(Map<String, dynamic> event) {
    final isCall = event['kind'] == 'call';
    final failed = event['status'] == 'failed';
    final otp = isCall ? null : _otpFrom(event['body']?.toString());
    final controllable =
        isCall &&
        _isLatestCallState(event) &&
        const {
          'ringing',
          'active',
          'holding',
          'dialing',
          'connecting',
        }.contains(event['status']);
    final body = isCall ? null : event['body']?.toString();
    final meta = _eventMeta(event);
    final result = _eventResult(event);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: failed
                          ? Palette.faultSoft
                          : isCall
                          ? Palette.chipSoft
                          : Palette.signalSoft,
                      shape: simShape(cut: 13, base: 6),
                    ),
                    child: Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : isCall
                          ? (event['status'] == 'missed'
                                ? Icons.phone_missed_outlined
                                : Icons.phone_outlined)
                          : Icons.chat_bubble_outline,
                      size: 20,
                      color: failed
                          ? Palette.fault
                          : isCall
                          ? Palette.ink
                          : Palette.signal,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          switch (event['address']?.toString()) {
                            final String address when address.isNotEmpty =>
                              address,
                            _ => l10n.privateNumber,
                          },
                          overflow: TextOverflow.ellipsis,
                          style: mono(size: 14, weight: FontWeight.w700),
                        ),
                        if (isCall) ...[
                          const SizedBox(height: 2),
                          Text(
                            _callLabel(event['status']),
                            style: const TextStyle(
                              color: Palette.haze,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _relativeTime(event),
                    style: const TextStyle(color: Palette.haze, fontSize: 11.5),
                  ),
                ],
              ),
              if (body != null && body.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  body,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.4, fontSize: 14),
                ),
              ],
              if (otp != null) ...[
                const SizedBox(height: 10),
                OtpBlock(
                  code: otp,
                  label: l10n.otpLabel,
                  copiedMessage: l10n.otpCopied,
                ),
              ],
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in meta)
                      MetaChip(text: entry.$1, monospace: entry.$2),
                  ],
                ),
              ],
              if (result != null) ...[
                const SizedBox(height: 9),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(result.$2, size: 14, color: result.$3),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        result.$1,
                        style: TextStyle(
                          color: result.$3,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (controllable) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _controlRemoteCall(
                      event,
                      event['status'] == 'ringing' ? 'reject' : 'disconnect',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: Palette.fault,
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    child: Text(
                      event['status'] == 'ringing'
                          ? l10n.declineCall
                          : l10n.hangUpCall,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _relativeTime(Map<String, dynamic> event) {
    // The gateway's sealed time, not the relay's, which it can choose freely.
    final at = DateTime.tryParse((event['occurredAt'] ?? '').toString());
    if (at == null) return '';
    final difference = DateTime.now().toUtc().difference(at.toUtc());
    if (difference.inMinutes < 1) return l10n.timeJustNow;
    if (difference.inHours < 1) {
      return l10n.timeMinutesAgo(difference.inMinutes);
    }
    if (difference.inDays < 1) return l10n.timeHoursAgo(difference.inHours);
    return l10n.timeDaysAgo(difference.inDays);
  }

  bool _isLatestCallState(Map<String, dynamic> event) {
    final callId = event['callId'];
    if (callId == null) return false;
    final latest = events.reversed
        .where((item) => item['callId'] == callId)
        .firstOrNull;
    return latest?['occurredAt'] == event['occurredAt'];
  }

  /// Route metadata for an event: (text, monospace) chips.
  List<(String, bool)> _eventMeta(Map<String, dynamic> event) {
    final profile = simProfiles.where((item) {
      if (event['subscriptionId'] != null) {
        return item['subscriptionId'].toString() ==
            event['subscriptionId'].toString();
      }
      if ((event['phoneAccountId'] ?? '').toString().isNotEmpty) {
        return item['phoneAccountId'] == event['phoneAccountId'];
      }
      return false;
    }).firstOrNull;
    final gatewayName = _gatewayName(
      profile?['gatewayDeviceId']?.toString() ??
          event['gatewayDeviceId']?.toString(),
    );
    return [
      if (event['simulated'] == true) (l10n.simulatedBadge, false),
      (gatewayName, false),
      if (profile?['displayName'] != null)
        (profile!['displayName'].toString(), false),
      if ((profile?['phoneNumber'] ?? '').toString().isNotEmpty)
        (profile!['phoneNumber'].toString(), true),
    ];
  }

  /// Delivery result for outgoing SMS: (text, icon, color).
  (String, IconData, Color)? _eventResult(Map<String, dynamic> event) {
    if (event['status'] == 'unknown') {
      return (
        l10n.commandOutcomeUnknown,
        Icons.help_outline_rounded,
        Palette.haze,
      );
    }
    if (event['kind'] != 'sms' || event['direction'] != 'outgoing') {
      return null;
    }
    return switch (event['status']) {
      'sent' => (
        l10n.smsStatusSent,
        Icons.check_circle_outline,
        Palette.signal,
      ),
      'failed' => (
        l10n.smsStatusFailed(
          event['failureReason']?.toString() ?? l10n.smsFailureDefault,
        ),
        Icons.error_outline_rounded,
        Palette.fault,
      ),
      _ => (l10n.smsStatusWaiting, Icons.schedule_rounded, Palette.haze),
    };
  }

  Widget _devicesTab() => RefreshIndicator(
    onRefresh: _sync,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.devicesTitle, style: display(size: 25)),
                const SizedBox(height: 4),
                Text(
                  l10n.devicesSubtitle,
                  style: const TextStyle(color: Palette.haze),
                ),
              ],
            ),
            IconButton.filled(
              onPressed: _showPairing,
              style: IconButton.styleFrom(
                backgroundColor: Palette.board,
                shape: simShape(cut: 15, base: 6),
              ),
              color: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
          ],
        ),
        const SizedBox(height: 22),
        ...devices.map((device) {
          final current = device['id'] == session!.deviceId;
          final isGateway = device['capabilities']?['smsGateway'] == true;
          final online = _isOnline(device);
          final sims = simProfiles
              .where((profile) => profile['gatewayDeviceId'] == device['id'])
              .toList();
          return Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: DeviceCard(
              name:
                  device['name']?.toString() ??
                  (host.isDesktop
                      ? l10n.desktopUnnamedDevice
                      : l10n.unnamedPhone),
              statusLine:
                  '${isGateway ? l10n.roleGateway : l10n.roleClientShort} · '
                  '${online ? l10n.onlineNow : _lastSeen(device['lastSeenAt'])}',
              isGateway: isGateway,
              online: online,
              isCurrentDevice: current,
              isComputer: current && host.isDesktop,
              isOwner: device['isOwner'] == true,
              currentDeviceLabel: host.isDesktop
                  ? l10n.desktopThisDevice
                  : l10n.thisPhone,
              ownerLabel: l10n.ownerBadge,
              simChips: [
                for (final sim in sims)
                  [
                    sim['displayName'] ??
                        l10n.simNumber(((sim['slotIndex'] as int?) ?? 0) + 1),
                    if ((sim['phoneNumber'] ?? '').toString().isNotEmpty)
                      sim['phoneNumber'],
                  ].join(' · '),
              ],
              removeLabel: l10n.removeDevice,
              onRemove: _isBridgeOwner && !current
                  ? () => _confirmRemoveDevice(device)
                  : null,
            ),
          );
        }),
      ],
    ),
  );

  Widget _settingsTab() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
    children: [
      Text(l10n.settingsTitle, style: display(size: 25)),
      const SizedBox(height: 20),
      if (host.isDesktop) ...[
        _desktopAvailabilityCard(),
        const SizedBox(height: 14),
      ],
      Card(
        child: Column(
          children: [
            SettingsTile(
              icon: gateway
                  ? Icons.sim_card_outlined
                  : host.isDesktop
                  ? Icons.desktop_windows_outlined
                  : Icons.phone_iphone_outlined,
              title: l10n.settingsRole,
              subtitle: gateway
                  ? l10n.roleGatewayFull
                  : host.isDesktop
                  ? l10n.desktopRole
                  : Platform.isIOS
                  ? l10n.roleClientIos
                  : l10n.roleClient,
              trailing: const Icon(Icons.info_outline, color: Palette.fir),
            ),
            const Divider(height: 1, indent: 64),
            SettingsTile(
              icon: Icons.dns_outlined,
              title: l10n.settingsRelay,
              subtitle: session!.server,
              trailing: OnlineLabel(
                online: relayOnline,
                text: relayOnline ? l10n.statusOnline : l10n.statusOffline,
              ),
            ),
            const Divider(height: 1, indent: 64),
            SettingsTile(
              icon: Icons.shield_outlined,
              title: l10n.settingsEncryption,
              subtitle: l10n.settingsEncryptionSubtitle,
              trailing: const Icon(
                Icons.verified_rounded,
                color: Palette.signal,
              ),
            ),
            const Divider(height: 1, indent: 64),
            SettingsTile(
              icon: Icons.person_add_alt_1_outlined,
              title: (host.isDesktop ? l10n.desktopPairTitle : l10n.pairTitle),
              subtitle: l10n.pairMethods,
              onTap: _showPairing,
            ),
            const Divider(height: 1, indent: 64),
            SettingsTile(
              icon: Icons.manage_accounts_outlined,
              title: l10n.operatorRecoveryTitle,
              subtitle: l10n.operatorRecoverySummary,
              onTap: _operatorRecoveryDialog,
            ),
            if (gateway && Platform.isAndroid) ...[
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.fact_check_outlined,
                title: l10n.gatewayChecksTitle,
                subtitle: _gatewayAttentionText,
                onTap: _showGatewayChecks,
              ),
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.sync_outlined,
                title: l10n.gatewayRuntimeTitle,
                subtitle: _gatewayRuntimeSummary,
              ),
              const Divider(height: 1, indent: 64),
              if (_gatewayRestartOffered) ...[
                SettingsTile(
                  icon: Icons.restart_alt,
                  title: l10n.gatewayRestart,
                  subtitle: l10n.gatewayRestartDescription,
                  onTap: _gatewayRestarting ? null : _restartGateway,
                ),
                const Divider(height: 1, indent: 64),
              ],
              SettingsTile(
                icon: Icons.battery_saver_outlined,
                title: l10n.gatewayBatteryTitle,
                subtitle: _gatewayStatus['batteryExempt'] == true
                    ? l10n.gatewayBatteryUnrestricted
                    : l10n.gatewayBatteryRestricted,
                onTap: () => _gatewaySettingsAction('openBatterySettings'),
              ),
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.power_settings_new_outlined,
                title: l10n.gatewayAutostartTitle,
                subtitle: l10n.gatewayAutostartDescription,
                onTap: _openGatewayAutostartSettings,
              ),
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.phone_in_talk_outlined,
                title: l10n.settingsCallControl,
                subtitle: phoneRole
                    ? l10n.callControlReady
                    : l10n.callControlNeedsRole,
                trailing: phoneRole
                    ? const Icon(Icons.verified_rounded, color: Palette.signal)
                    : null,
                onTap: phoneRole ? null : _requestPhoneRole,
              ),
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.sim_card_outlined,
                title: l10n.settingsSims,
                subtitle: simProfiles.isEmpty
                    ? l10n.noActiveSim
                    : simProfiles
                          .map(
                            (profile) => [
                              _gatewayName(profile['gatewayDeviceId']),
                              profile['displayName'],
                              if ((profile['phoneNumber'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                profile['phoneNumber'],
                            ].join(' · '),
                          )
                          .join(' · '),
              ),
            ],
            if (!gateway) ...[
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: switch (notificationsAllowed) {
                  true => Icons.notifications_active_outlined,
                  false => Icons.notifications_off_outlined,
                  null => Icons.notifications_none_outlined,
                },
                title: l10n.settingsNotifications,
                subtitle: switch (notificationsAllowed) {
                  true => l10n.notificationsAllowed,
                  false => l10n.notificationsBlocked,
                  null =>
                    host.isDesktop && (Platform.isWindows || Platform.isLinux)
                        ? (_notificationServiceAvailable
                              ? l10n.desktopNotificationsAvailable
                              : l10n.desktopNotificationsUnknown)
                        : l10n.notificationsUnknown,
                },
                trailing: notificationsAllowed == true
                    ? const Icon(Icons.verified_rounded, color: Palette.signal)
                    : Icon(
                        Icons.chevron_right,
                        color: notificationsAllowed == false
                            ? Palette.fault
                            : Palette.haze,
                      ),
                onTap: notificationsAllowed == true
                    ? null
                    : () async {
                        // iOS shows its prompt only once; after that the
                        // system settings are the only way back.
                        if (host.target == TargetPlatform.windows ||
                            host.target == TargetPlatform.linux) {
                          await _openSystemNotificationSettings();
                        } else if (!await _requestNotificationPermission()) {
                          await _openSystemNotificationSettings();
                        }
                      },
              ),
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.content_paste_go_outlined,
                title: l10n.settingsAutoCopy,
                subtitle: autoCopyCodes ? l10n.autoCopyOn : l10n.autoCopyOff,
                trailing: Switch(
                  value: autoCopyCodes,
                  activeThumbColor: Palette.fir,
                  onChanged: (value) async {
                    setState(() => autoCopyCodes = value);
                    await (await SharedPreferences.getInstance()).setBool(
                      'autoCopyCodes',
                      value,
                    );
                  },
                ),
              ),
            ],
            if (_isBridgeOwner) ...[
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: bridgeJoinable
                    ? Icons.lock_open_outlined
                    : Icons.lock_outline,
                title: l10n.settingsEnrollment,
                subtitle: bridgeJoinable
                    ? l10n.enrollmentOpen
                    : l10n.enrollmentClosed,
                trailing: Switch(
                  value: bridgeJoinable,
                  activeThumbColor: Palette.fir,
                  onChanged: _setJoinable,
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      Card(
        child: Column(
          children: [
            SettingsTile(
              icon: Icons.notifications_active_outlined,
              title: l10n.testCodeTitle,
              subtitle: host.isDesktop
                  ? l10n.desktopCodeTestSubtitle
                  : l10n.testCodeSubtitle,
              onTap: Platform.isIOS
                  ? _showCodeKeyboardTest
                  : _testCodeNotification,
            ),
            if (gateway) ...[
              const Divider(height: 1, indent: 64),
              SettingsTile(
                icon: Icons.send_outlined,
                title: l10n.testMessageTitle,
                subtitle: l10n.testMessageSubtitle,
                onTap: _testBridgeMessage,
              ),
            ],
          ],
        ),
      ),
      if (host.isDesktop) ...[const SizedBox(height: 14), _updatesCard()],
      const SizedBox(height: 14),
      Card(
        child: SettingsTile(
          icon: Icons.logout,
          title: l10n.leaveBridge,
          subtitle: (host.isDesktop
              ? l10n.desktopLeaveBridgeSubtitle
              : l10n.leaveBridgeSubtitle),
          onTap: _confirmLeaveBridge,
          destructive: true,
        ),
      ),
      const SizedBox(height: 22),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          [
            if (!_isBridgeOwner && devices.isNotEmpty)
              l10n.ownerOnlyHint(_ownerName),
            l10n.callAudioNote,
          ].join('\n\n'),
          style: const TextStyle(
            color: Palette.haze,
            height: 1.45,
            fontSize: 12,
          ),
        ),
      ),
    ],
  );

  /// True when this phone created the bridge, which is what allows it to
  /// remove other phones.
  bool get _isBridgeOwner => devices.cast<Map<String, dynamic>>().any(
    (item) => item['id'] == session?.deviceId && item['isOwner'] == true,
  );

  String get _ownerName =>
      devices
          .cast<Map<String, dynamic>>()
          .where((item) => item['isOwner'] == true)
          .map(
            (item) =>
                item['name']?.toString() ??
                (host.isDesktop
                    ? l10n.desktopUnnamedDevice
                    : l10n.unnamedPhone),
          )
          .firstOrNull ??
      (host.isDesktop ? l10n.desktopUnnamedDevice : l10n.unnamedPhone);

  /// Explains exactly what removal does — and what it cannot undo — before
  /// cutting a phone off.
  Future<void> _confirmRemoveDevice(Map<String, dynamic> device) async {
    final name =
        device['name']?.toString() ??
        (host.isDesktop ? l10n.desktopUnnamedDevice : l10n.unnamedPhone);
    final isGateway = device['capabilities']?['smsGateway'] == true;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: host.isDesktop
          ? const BoxConstraints(maxWidth: _desktopSheetWidth)
          : null,
      builder: (sheetContext) => Sheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.person_remove_outlined,
              title: l10n.removeDeviceTitle(name),
              subtitle: l10n.removeDeviceSubtitle,
            ),
            const SizedBox(height: 18),
            RemovalNote(text: l10n.removeDeviceKeyWarning),
            if (isGateway && device['isOwner'] == true) ...[
              const SizedBox(height: 10),
              RemovalNote(text: l10n.authorityRemovalWarning),
            ],
            if (isGateway) ...[
              const SizedBox(height: 10),
              RemovalNote(text: l10n.removeDeviceGatewayWarning),
            ],
            if (bridgeJoinable) ...[
              const SizedBox(height: 10),
              RemovalNote(text: l10n.removeDeviceRejoinWarning),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              style: FilledButton.styleFrom(backgroundColor: Palette.fault),
              child: Text(l10n.removeDeviceConfirm),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext, false),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || session == null) return;
    try {
      await BridgeApi.forSession(session!).removeDevice(session!, device['id']);
      Log.info('Removed device ${Log.preview(device['id'])} from the bridge');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.deviceRemoved(name))));
      }
      await _sync();
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  Future<void> _setJoinable(bool joinable) async {
    if (session == null) return;
    try {
      bridgeJoinable = await BridgeApi.forSession(
        session!,
      ).setJoinable(session!, joinable);
      Log.info('Bridge enrollment set to $bridgeJoinable');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              bridgeJoinable ? l10n.enrollmentOpened : l10n.enrollmentClosed2,
            ),
          ),
        );
        setState(() {});
      }
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  Future<void> _requestPhoneRole() async {
    try {
      await platform.invokeMethod('requestPhoneRole');
    } catch (exception) {
      if (mounted) {
        setState(() => error = _describeFailure(exception));
      }
    }
  }

  bool _isOnline(Map<String, dynamic> device) {
    if (device['online'] is bool) return device['online'] == true;
    final seen = DateTime.tryParse(device['lastSeenAt'] ?? '');
    return seen != null &&
        DateTime.now().toUtc().difference(seen) < _presenceWindow;
  }

  String _lastSeen(String? value) {
    final seen = DateTime.tryParse(value ?? '');
    if (seen == null) return l10n.statusOffline;
    final difference = DateTime.now().toUtc().difference(seen);
    if (difference.inMinutes < 1) return l10n.seenJustNow;
    if (difference.inHours < 1) {
      return l10n.seenMinutesAgo(difference.inMinutes);
    }
    return l10n.seenHoursAgo(difference.inHours);
  }

  String _callLabel(dynamic status) => switch (status) {
    'unknown' => l10n.commandOutcomeUnknown,
    'ringing' => l10n.callIncoming,
    'missed' => l10n.callMissed,
    'dialing' => l10n.callDialed,
    'active' => l10n.callActive,
    'holding' => l10n.callOnHold,
    'ended' => l10n.callEnded,
    _ => l10n.callActivity,
  };
}

class _CodeKeyboardTestSheet extends StatefulWidget {
  const _CodeKeyboardTestSheet({required this.onSend});
  final Future<void> Function() onSend;

  @override
  State<_CodeKeyboardTestSheet> createState() => _CodeKeyboardTestSheetState();
}

class _CodeKeyboardTestSheetState extends State<_CodeKeyboardTestSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      await widget.onSend();
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _focus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Sheet(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              icon: Icons.keyboard_alt_outlined,
              title: l10n.testCodeTitle,
              subtitle: l10n.testCodeKeyboardSubtitle,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: l10n.verificationCodeLabel,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _sending ? null : _send,
              child: Text(l10n.sendTestCode),
            ),
          ],
        ),
      ),
    );
  }
}
