import CryptoKit
import Security
import UserNotifications

private let keyService = "app.simbridge.notification-key"
private let historyService = "app.simbridge.notification-history"
private let keyAccount = "current-bridge"

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttemptContent = content
    defer { contentHandler(content) }

    guard content.userInfo["messageId"] is String,
      let envelope = content.userInfo["encrypted"] as? [String: Any],
      let bridge = readBridge(),
      let clear = decrypt(envelope, key: bridge.key),
      clear["bridgeId"] as? String == bridge.id,
      clear["kind"] as? String == "sms",
      clear["direction"] as? String == "incoming"
    else { return }

    // A replayed push must not reveal its decrypted preview a second time;
    // it keeps the generic alert the relay sent.
    let eventId = (clear["eventId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if let eventId, !remember(eventId) { return }

    let german = Locale.preferredLanguages.first?.hasPrefix("de") == true
    let body = clear["body"] as? String ?? ""
    let sender = (clear["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (german ? "Unbekannter Absender" : "Unknown sender")
    let code = (clear["otp"] as? String) ?? verificationCode(in: body)
    content.title = code.map { german ? "Bestätigungscode \($0)" : "Verification code \($0)" }
      ?? (german ? "Nachricht über Sim Bridge" : "Message via Sim Bridge")
    content.body = "\(sender) · \(body)"
    if let eventId {
      // Use the gateway's event ID throughout iOS. The relay's message ID is
      // unrelated, so it cannot coordinate a Flutter local alert with APNs.
      var userInfo = content.userInfo
      userInfo["messageId"] = eventId
      content.userInfo = userInfo
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let content = bestAttemptContent { contentHandler?(content) }
  }

  private func accessGroup() -> String? {
    Bundle.main.object(forInfoDictionaryKey: "NotificationKeychainGroup") as? String
  }

  private func query(service: String, group: String) -> [String: Any] {[
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: keyAccount,
    kSecAttrAccessGroup as String: group,
  ]}

  private func read(service: String, group: String) -> Data? {
    var request = query(service: service, group: group)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess else { return nil }
    return value as? Data
  }

  private func readBridge() -> (id: String, key: SymmetricKey)? {
    guard let group = accessGroup(),
      let data = read(service: keyService, group: group),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let id = value["bridgeId"],
      let encoded = value["key"],
      let bytes = Data(base64Encoded: encoded), bytes.count == 32
    else { return nil }
    return (id, SymmetricKey(data: bytes))
  }

  private func base64url(_ value: Any?) -> Data? {
    guard let text = value as? String else { return nil }
    let standard = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
  }

  private func decrypt(_ envelope: [String: Any], key: SymmetricKey) -> [String: Any]? {
    guard envelope["v"] as? Int == 1,
      let nonce = base64url(envelope["nonce"]), nonce.count == 12,
      let ciphertext = base64url(envelope["ciphertext"]),
      let tag = base64url(envelope["mac"]), tag.count == 16,
      let sealed = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                         ciphertext: ciphertext, tag: tag),
      let clear = try? AES.GCM.open(sealed, using: key),
      let value = try? JSONSerialization.jsonObject(with: clear) as? [String: Any]
    else { return nil }
    return value
  }

  private func verificationCode(in body: String) -> String? {
    let patterns = [
      "(?:code|pin|otp|passcode|verification)[^0-9]{0,20}([0-9]{4,8})",
      "(?<![0-9])([0-9]{4,8})(?![0-9])",
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
        let range = Range(match.range(at: 1), in: body)
      else { continue }
      return String(body[range])
    }
    return nil
  }

  /// Records an event ID; returns false when it was already shown before.
  @discardableResult
  private func remember(_ messageId: String) -> Bool {
    guard let group = accessGroup() else { return true }
    var ids = (read(service: historyService, group: group)
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }) ?? []
    if ids.contains(messageId) { return false }
    ids.append(messageId)
    if ids.count > 400 { ids.removeFirst(ids.count - 400) }
    guard let data = try? JSONSerialization.data(withJSONObject: ids) else { return true }
    let base = query(service: historyService, group: group)
    if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      == errSecSuccess { return true }
    var record = base
    record[kSecValueData as String] = data
    record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(record as CFDictionary, nil)
    return true
  }
}
