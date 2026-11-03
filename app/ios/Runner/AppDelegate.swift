import Flutter
import UIKit
import UserNotifications
import Security

/// A delivered code is only useful for a minute or two; leaving it on the
/// pasteboard any longer widens the window in which another app could read it.
private let codeClipboardLifetime: TimeInterval = 180

/// Stable pasteboard type. `UTType` needs iOS 14, above this app's floor.
private let plainTextPasteboardType = "public.utf8-plain-text"
private let pushKeyService = "app.simbridge.notification-key"
private let pushKeyAccount = "current-bridge"
private let pushHistoryService = "app.simbridge.notification-history"
private let localHistoryService = "app.simbridge.local-notification-history"

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private func sharedKeychainGroup() -> String? {
    Bundle.main.object(forInfoDictionaryKey: "NotificationKeychainGroup") as? String
  }

  private func pushEnvironment() -> String? {
    // The build setting must match the aps-environment of the signing profile.
    // Development and ad hoc builds use sandbox; App Store exports use production.
    return Bundle.main.object(forInfoDictionaryKey: "PushEnvironment") as? String
  }

  private func notificationHistory(_ service: String) -> [String] {
    guard let group = sharedKeychainGroup() else { return [] }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
      let data = value as? Data,
      let list = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return [] }
    return list
  }

  private func claimLocalNotification(_ messageId: String) -> Bool {
    guard !messageId.isEmpty, let group = sharedKeychainGroup() else { return true }
    if notificationHistory(pushHistoryService).contains(messageId) { return false }
    var ids = notificationHistory(localHistoryService)
    if ids.contains(messageId) { return false }
    ids.append(messageId)
    if ids.count > 400 { ids.removeFirst(ids.count - 400) }
    guard let data = try? JSONSerialization.data(withJSONObject: ids) else { return true }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: localHistoryService,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
    ]
    if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      == errSecSuccess { return true }
    var record = query
    record[kSecValueData as String] = data
    record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(record as CFDictionary, nil) == errSecSuccess
  }

  private func storeNotificationKey(_ arguments: [String: Any]) -> Bool {
    guard let group = sharedKeychainGroup(),
      let bridgeId = arguments["bridgeId"] as? String,
      let encoded = arguments["key"] as? String,
      let key = Data(base64Encoded: encoded), key.count == 32,
      let data = try? JSONSerialization.data(withJSONObject: [
        "bridgeId": bridgeId, "key": encoded,
      ])
    else { return false }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: pushKeyService,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
    ]
    SecItemDelete(query as CFDictionary)
    var record = query
    record[kSecValueData as String] = data
    record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(record as CFDictionary, nil) == errSecSuccess
  }

  private func clearNotificationKey() {
    guard let group = sharedKeychainGroup() else { return }
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: pushKeyService,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
    ] as CFDictionary)
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: pushHistoryService,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
    ] as CFDictionary)
    SecItemDelete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: localHistoryService,
      kSecAttrAccount as String: pushKeyAccount,
      kSecAttrAccessGroup as String: group,
    ] as CFDictionary)
  }

  private func deliveredPushMessageIds() -> [String] {
    notificationHistory(pushHistoryService)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    UserDefaults.standard.set(deviceToken.map { String(format: "%02x", $0) }.joined(),
                              forKey: "apnsDeviceToken")
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    UserDefaults.standard.removeObject(forKey: "apnsDeviceToken")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // The notification extension records this message before Flutter's poll
    // can post a local alert. Present the remote banner in the foreground too.
    if let messageId = notification.request.content.userInfo["messageId"] as? String {
      completionHandler(notificationHistory(localHistoryService).contains(messageId)
        ? [] : [.banner, .sound])
      return
    }
    super.userNotificationCenter(center, willPresent: notification,
                                 withCompletionHandler: completionHandler)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications. Without it iOS silently drops
    // notifications raised while the app is in the foreground — and since the
    // app can only sync while it is open, that is every notification it posts.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "app.simbridge/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "copyCode", "copySensitive":
        let argumentKey = call.method == "copyCode" ? "code" : "text"
        guard
          let arguments = call.arguments as? [String: Any],
          let code = arguments[argumentKey] as? String, !code.isEmpty
        else {
          result(FlutterError(code: "bad_arguments", message: "A code is required", details: nil))
          return
        }
        // localOnly keeps the code off Universal Clipboard, so it never
        // travels to the user's other Apple devices; the expiry clears it.
        UIPasteboard.general.setItems(
          [[plainTextPasteboardType: code]],
          options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(codeClipboardLifetime),
          ]
        )
        result(true)
      case "openNotificationSettings":
        // iOS presents its permission prompt once per install; after that
        // this is the only route back to enabling notifications.
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      case "setPushBridge":
        result((call.arguments as? [String: Any]).map(self.storeNotificationKey) ?? false)
      case "clearPushBridge":
        self.clearNotificationKey()
        result(true)
      case "registerForPush":
        UIApplication.shared.registerForRemoteNotifications()
        result(true)
      case "pushRegistration":
        result([
          "token": UserDefaults.standard.string(forKey: "apnsDeviceToken") ?? "",
          "environment": self.pushEnvironment() ?? "",
        ])
      case "deliveredPushMessageIds":
        result(self.deliveredPushMessageIds())
      case "claimLocalNotification":
        result((call.arguments as? String).map(self.claimLocalNotification) ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
