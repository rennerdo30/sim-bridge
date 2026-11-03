/// Device checks are independent of relay roster polling. Unknown is never a
/// successful check, and OEM autostart is only a user's reported setting.
enum GatewayAttention {
  notChecked,
  receiveSms,
  sendSms,
  simAccess,
  stopped,
  unauthorized,
  unpaired,
  backgroundRestricted,
  battery,
  notifications,
  autostart,
  reconnecting,
  queued,
}

class GatewayReadiness {
  GatewayReadiness({
    required this.status,
    required this.nativeCheckAgeMs,
    String? confirmedFingerprint,
    DateTime? confirmedAt,
  }) : autostartConfirmedByUser =
           confirmedAt != null &&
           confirmedFingerprint != null &&
           confirmedFingerprint.isNotEmpty &&
           confirmedFingerprint == status['deviceBuildFingerprint'];

  final Map<String, dynamic> status;
  final int? nativeCheckAgeMs;
  final bool autostartConfirmedByUser;

  bool? grant(String key) => status[key] is bool ? status[key] as bool : null;
  bool get nativeCheckRecent =>
      nativeCheckAgeMs != null &&
      nativeCheckAgeMs! >= 0 &&
      nativeCheckAgeMs! < 30000;
  bool? get receiveSms => nativeCheckRecent ? grant('receiveSmsGranted') : null;
  bool? get sendSms => nativeCheckRecent ? grant('sendSmsGranted') : null;
  bool? get simAccess =>
      nativeCheckRecent ? grant('readPhoneStateGranted') : null;
  bool? get notifications =>
      nativeCheckRecent ? grant('notificationsEnabled') : null;
  bool? get batteryExempt => nativeCheckRecent ? grant('batteryExempt') : null;
  bool get autostartRequired => status['manufacturerAutostartRequired'] == true;
  bool? get backgroundRestricted =>
      nativeCheckRecent ? grant('backgroundRestricted') : null;
  bool get runtimeConnected {
    final age = status['lastSyncAgeMs'];
    return nativeCheckRecent &&
        status['running'] == true &&
        status['ready'] == true &&
        status['relayOnline'] == true &&
        status['state'] == 'running' &&
        age is num &&
        age >= 0 &&
        age + nativeCheckAgeMs! < 30000;
  }

  int get pending => (status['pending'] as num?)?.toInt() ?? 0;
  bool get blocked =>
      attention == GatewayAttention.receiveSms ||
      attention == GatewayAttention.sendSms ||
      attention == GatewayAttention.simAccess ||
      attention == GatewayAttention.stopped ||
      attention == GatewayAttention.unauthorized ||
      attention == GatewayAttention.unpaired;
  GatewayAttention? get attention {
    if (receiveSms == false) return GatewayAttention.receiveSms;
    if (sendSms == false) return GatewayAttention.sendSms;
    if (simAccess == false) return GatewayAttention.simAccess;
    if (nativeCheckRecent &&
        ['unauthorized', 'migration_required'].contains(status['state'])) {
      return GatewayAttention.unauthorized;
    }
    if (nativeCheckRecent && status['state'] == 'unpaired') {
      return GatewayAttention.unpaired;
    }
    if (nativeCheckRecent &&
        (status['running'] == false || status['state'] == 'suspended')) {
      return GatewayAttention.stopped;
    }
    if (!nativeCheckRecent ||
        receiveSms == null ||
        sendSms == null ||
        simAccess == null ||
        batteryExempt == null ||
        notifications == null ||
        (status['backgroundRestrictionCheckSupported'] == true &&
            backgroundRestricted == null) ||
        status['manufacturerAutostartRequired'] is! bool) {
      return GatewayAttention.notChecked;
    }
    if (backgroundRestricted == true) {
      return GatewayAttention.backgroundRestricted;
    }
    if (batteryExempt == false) return GatewayAttention.battery;
    if (notifications == false) return GatewayAttention.notifications;
    if (autostartRequired && !autostartConfirmedByUser) {
      return GatewayAttention.autostart;
    }
    if (!runtimeConnected) return GatewayAttention.reconnecting;
    if (pending > 0) return GatewayAttention.queued;
    return null;
  }
}
