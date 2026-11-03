import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clipboardChannel: FlutterMethodChannel?
  private var clipboardExpiry: Timer?
  private var clipboardOwnedChangeCount: Int?

  override func awakeFromNib() {
    // Forward command-line arguments (such as --managed-updates from the
    // renner.dev launcher) to Dart's main(), as the Windows and Linux runners do.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    contentViewController = flutterViewController
    title = "Sim Bridge"
    contentMinSize = NSSize(width: 760, height: 600)
    setContentSize(NSSize(width: 1180, height: 800))
    center()

    // flutter_local_notifications installs its own foreground notification
    // delegate during registration. Keep that delegate rather than replacing it.
    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "app.simbridge/clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    clipboardChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "window_unavailable", message: "The window is closed", details: nil))
        return
      }
      switch call.method {
      case "copyCode", "copySensitive":
        let argumentKey = call.method == "copyCode" ? "code" : "text"
        guard let arguments = call.arguments as? [String: Any],
              let code = arguments[argumentKey] as? String else {
          result(FlutterError(code: "bad_arguments", message: "Sensitive text is required", details: nil))
          return
        }
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        // Common clipboard-manager markers: macOS has no public equivalent of
        // iOS UIPasteboard's localOnly or expirationDate write options.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        self.clipboardExpiry?.invalidate()
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
          result(false)
          return
        }
        self.clipboardOwnedChangeCount = pasteboard.changeCount
        self.clipboardExpiry = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
          self?.clearOwnedClipboardCode()
        }
        result(true)
      case "openNotificationSettings":
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
          result(false)
          return
        }
        result(NSWorkspace.shared.open(url))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  func clearOwnedClipboardCode() {
    clipboardExpiry?.invalidate()
    clipboardExpiry = nil
    // Never erase something the user copied after the verification code.
    if let changeCount = clipboardOwnedChangeCount,
       NSPasteboard.general.changeCount == changeCount {
      NSPasteboard.general.clearContents()
    }
    clipboardOwnedChangeCount = nil
  }

  override func close() {
    clearOwnedClipboardCode()
    super.close()
  }

  deinit {
    clipboardExpiry?.invalidate()
  }
}
