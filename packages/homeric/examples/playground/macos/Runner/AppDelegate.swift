import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var historyChannel: FlutterMethodChannel?
  private var canUndo = false
  private var canRedo = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    DispatchQueue.main.async { [weak self] in
      self?.registerHomericHistoryChannel()
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  @IBAction func undo(_ sender: Any?) {
    historyChannel?.invokeMethod("undo", arguments: nil)
  }

  @IBAction func redo(_ sender: Any?) {
    historyChannel?.invokeMethod("redo", arguments: nil)
  }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo(_:)) {
      return canUndo
    }
    if menuItem.action == #selector(redo(_:)) {
      return canRedo
    }
    return super.validateMenuItem(menuItem)
  }

  private func registerHomericHistoryChannel() {
    let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
      ?? NSApp.windows
        .compactMap { $0.contentViewController as? FlutterViewController }
        .first
    guard let controller else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "homeric/macos_history",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "setUndoState":
        guard let args = call.arguments as? [String: Any] else {
          result(
            FlutterError(
              code: "bad_args",
              message: "setUndoState expects a map",
              details: nil
            )
          )
          return
        }
        self.canUndo = args["canUndo"] as? Bool ?? false
        self.canRedo = args["canRedo"] as? Bool ?? false
        NSApp.mainMenu?.update()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    historyChannel = channel
  }
}
