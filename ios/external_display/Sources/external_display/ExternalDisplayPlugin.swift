import Flutter
import UIKit

public class ExternalDisplayPlugin: NSObject, FlutterPlugin {
    public static var connectReturn:(() -> Void)?
    public static var mainViewEvents:FlutterEventSink?
    public static var externalViewEvents:FlutterEventSink?

    public static var registerGeneratedPlugin:((FlutterViewController)->Void)?
    public static var receiveParameters:FlutterEventChannel?
    public static var sendParameters:FlutterMethodChannel?
    public static var externalWindow:UIWindow?

    // The external display's scene, captured by `ExternalDisplaySceneDelegate`
    // when iOS connects a `.windowExternalDisplayNonInteractive` scene. Under
    // the UIScene lifecycle a UIWindow only renders when bound to its
    // UIWindowScene — the legacy `UIWindow.screen` path is a no-op and the
    // system mirrors instead. Non-nil here == an external display is attached.
    public static var externalWindowScene:UIWindowScene?

    // 初始化
    public static func register(with registrar: FlutterPluginRegistrar) {
        // 建立 Flutter EventChannel
        let onDisplayChange = FlutterEventChannel(name: "monitorStateListener", binaryMessenger: registrar.messenger())
        onDisplayChange.setStreamHandler(MainViewHandler())

        // 建立 Flutter MethodChannel
        let connect = FlutterMethodChannel(name: "displayController", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ExternalDisplayPlugin(), channel: connect)
    }

    // Tear down the external engine + window. Shared by the Dart `disconnect`
    // call and the scene's `sceneDidDisconnect`. Hiding the window detaches it
    // from the scene, after which iOS resumes mirroring (the default).
    public static func teardownExternal() {
        externalWindow?.isHidden = true
        externalWindow = nil
        externalViewEvents = nil
        receiveParameters?.setStreamHandler(nil)
        receiveParameters = nil
        sendParameters = nil
    }

    // 接收主頁面的命令和參數
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            case "getScreen":
                // Legacy diagnostic (unused by the app). Report the external
                // scene's screen size if one is attached.
                var screenInfos = [String]()
                if let screen = ExternalDisplayPlugin.externalWindowScene?.screen {
                    let b = screen.nativeBounds
                    screenInfos.append("0. [\(Int(b.width))x\(Int(b.height))]")
                }
                result(screenInfos)

            // 連結外部顯示器 — attach the external Flutter engine's window to the
            // external UIWindowScene captured by ExternalDisplaySceneDelegate.
            case "connect":
                guard let windowScene = ExternalDisplayPlugin.externalWindowScene else {
                    result(false)
                    return
                }
                let args = call.arguments as? Dictionary<String, String>
                let routeName = args?["routeName"] ?? "externalView"

                let flutterEngine = FlutterEngine()
                flutterEngine.run(withEntrypoint: "externalDisplayMain", initialRoute: routeName)
                let externalViewController = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
                ExternalDisplayPlugin.registerGeneratedPlugin?(externalViewController)

                ExternalDisplayPlugin.receiveParameters = FlutterEventChannel(name: "receiveParametersListener", binaryMessenger: flutterEngine.binaryMessenger)
                ExternalDisplayPlugin.receiveParameters?.setStreamHandler(ExternalViewHandler())
                ExternalDisplayPlugin.sendParameters = FlutterMethodChannel(name: "sendParameters", binaryMessenger: flutterEngine.binaryMessenger)
                flutterEngine.registrar(forPlugin: "")?.addMethodCallDelegate(ExternalDisplaySendParameters(), channel: ExternalDisplayPlugin.sendParameters!)

                let window = UIWindow(windowScene: windowScene)
                window.rootViewController = externalViewController
                ExternalDisplayPlugin.externalWindow = window
                // Visible but NOT key — the phone window stays key/interactive
                // (this is a non-interactive external display).
                window.isHidden = false

                let size = windowScene.screen.bounds.size
                result(["height": size.height, "width": size.width])

            case "disconnect":
                if (ExternalDisplayPlugin.externalWindow != nil) {
                    ExternalDisplayPlugin.teardownExternal()
                    result(true)
                } else {
                    result(false)
                }

            // 等候外部顯示器可以接收參數
            case "waitingTransferParametersReady":
                let sendFail = DispatchWorkItem(block: {
                    result(false)
                    ExternalDisplayPlugin.connectReturn = nil
                })

                func returnResolution() -> Void {
                    sendFail.cancel()
                    result(true)
                    ExternalDisplayPlugin.connectReturn = nil
                }
                ExternalDisplayPlugin.connectReturn = returnResolution

                if (ExternalDisplayPlugin.externalViewEvents != nil) {
                    ExternalDisplayPlugin.connectReturn?()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: sendFail)
                }

            // 發送參數到外部顯示頁面
            case "sendParameters":
                if (ExternalDisplayPlugin.externalViewEvents != nil) {
                    ExternalDisplayPlugin.externalViewEvents?(call.arguments)
                    result(true)
                } else {
                    result(false)
                }

            default:
                result(false)
        }
    }
}

// Scene delegate for the external display. iOS instantiates this for the
// `.windowExternalDisplayNonInteractive` scene declared in the host app's
// Info.plist (UISceneConfigurations). Capturing the scene here is what lets
// `connect` bind a dedicated UIWindow to it; without it iOS mirrors the phone.
// @objc(...) pins the runtime class name so Info.plist can name it module-free.
@objc(ExternalDisplaySceneDelegate)
public class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayPlugin.externalWindowScene = windowScene
        // Report "plugged" to the main isolate; Dart drives connect() in turn.
        ExternalDisplayPlugin.mainViewEvents?(true)
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        guard scene === ExternalDisplayPlugin.externalWindowScene else { return }
        ExternalDisplayPlugin.teardownExternal()
        ExternalDisplayPlugin.externalWindowScene = nil
        ExternalDisplayPlugin.mainViewEvents?(false)
    }
}

// 接收外部顯示頁面的命令和參數
public class ExternalDisplaySendParameters: NSObject, FlutterPlugin {
    public static func register(with registrar: any FlutterPluginRegistrar) {}

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        ExternalDisplayPlugin.mainViewEvents?(call.arguments)
    }
}

// 主頁面 Flutter 開始和停止對 swift 傳送資料的監控
public class MainViewHandler: NSObject, FlutterStreamHandler {
    // 主頁面 Flutter 的開始監控 swift 傳回的資料
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        ExternalDisplayPlugin.mainViewEvents = events
        if #available(iOS 14.0, *) {
            // 檢查是否Mac機
            if (ProcessInfo.processInfo.isiOSAppOnMac) {
                return nil
            }
        }

        // Catch-up: the external scene may already be connected before Dart
        // attached this listener (app launched with a display plugged in).
        // Connect/disconnect transitions are driven by ExternalDisplaySceneDelegate.
        if (ExternalDisplayPlugin.externalWindowScene != nil) {
            events(true)
        }
        return nil
    }

    // 主頁面 Flutter 的停止監控 swift 傳回的資料
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        // 取消 swift 傳回的資料功能
        ExternalDisplayPlugin.mainViewEvents = nil
        return nil
    }
}

// 外部顯示頁面 Flutter 開始和停止對 swift 傳送資料的監控
public class ExternalViewHandler: NSObject, FlutterStreamHandler {
    // 外部顯示頁面 Flutter 的停止監控 swift 傳回的資料
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        ExternalDisplayPlugin.externalViewEvents = events
        ExternalDisplayPlugin.connectReturn?()
        return nil
    }

    // 外部顯示頁面 Flutter 的停止監控 swift 傳回的資料
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        ExternalDisplayPlugin.receiveParameters?.setStreamHandler(nil)
        ExternalDisplayPlugin.externalViewEvents = nil
        return nil
    }
}
