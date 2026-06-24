import Cocoa
import FlutterMacOS

public class ExternalDisplayPlugin: NSObject, FlutterPlugin, NSWindowDelegate {
    public static var connectReturn:(() -> Void)?
    public static var mainViewEvents:FlutterEventSink?
    public static var externalViewEvents:FlutterEventSink?
    
    public static var registerGeneratedPlugin:((FlutterViewController)->Void)?
    public static var receiveParameters:FlutterEventChannel?
    public static var sendParameters:FlutterMethodChannel?
    public static var externalWindow: NSWindow?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        // 建立 Flutter EventChannel
        let onDisplayChange = FlutterEventChannel(name: "monitorStateListener", binaryMessenger: registrar.messenger)
        onDisplayChange.setStreamHandler(MainViewHandler())
        
        // 建立 Flutter MethodChannel
        let connect = FlutterMethodChannel(name: "displayController", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(ExternalDisplayPlugin(), channel: connect)
    }

    // 接收主頁面的命令和參數
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            case "getScreen":
                let screens = NSScreen.screens
                var screenInfos = [String]()
                if #available(macOS 10.15, *) {
                    for i in 0..<screens.count {
                        let screen = screens[i]
                        screenInfos.append("\(i). \(screen.localizedName) [\(screen.frame.width)x\(screen.frame.height)]")
                    }
                } else {
                    for i in 0..<screens.count {
                        let screen = screens[i]
                        screenInfos.append("\(i). \(screen.frame.width)x\(screen.frame.height)")
                    }
                }
                result(screenInfos)
            
            // 連結外部顯示器
            case "createWindow":
                let args = call.arguments as? Dictionary<String, Any>
                let title = args?["title"] as? String ?? "External View"
                let fullscreen = args?["fullscreen"] as? Bool ?? false
                let windowWidth = args?["width"] as? Int ?? 1920
                let windowHeight = args?["height"] as? Int ?? 1080
                let screenIndex = args?["targetScreen"] as? Int ?? NSScreen.screens.count-1
 
                DispatchQueue.main.async {
                    let screens = NSScreen.screens
                    // Clamp the requested index so a bad/absent value can't crash.
                    let index = max(0, min(screenIndex, screens.count - 1))
                    let targetScreen = screens[index]

                    // Place the audience window ON the target screen. Fullscreen
                    // covers it; windowed is clamped to the visible frame and
                    // centred, so on a single-monitor Mac (no projector) it never
                    // lands off-screen. The old `origin.y = maxY` pushed the window
                    // above the screen — invisible on a one-screen setup.
                    let visible = targetScreen.visibleFrame
                    let w = min(CGFloat(windowWidth), visible.width)
                    let h = min(CGFloat(windowHeight), visible.height)
                    let frame = fullscreen
                        ? targetScreen.frame
                        : NSRect(
                            x: visible.origin.x + (visible.width - w) / 2,
                            y: visible.origin.y + (visible.height - h) / 2,
                            width: w,
                            height: h
                        )

                    if (ExternalDisplayPlugin.externalWindow == nil) {
                        ExternalDisplayPlugin.externalWindow = NSWindow(
                            contentRect: frame,
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .borderless],
                            backing: .buffered,
                            defer: true,
                            screen: targetScreen
                        )

                        let flutterEngine = FlutterEngine(name: "External Window", project: FlutterDartProject())
                        flutterEngine.run(withEntrypoint: "externalDisplayMain")
                        let externalViewController = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)
                        ExternalDisplayPlugin.registerGeneratedPlugin?(externalViewController)

                        ExternalDisplayPlugin.receiveParameters = FlutterEventChannel(name: "receiveParametersListener", binaryMessenger: flutterEngine.binaryMessenger)
                        ExternalDisplayPlugin.receiveParameters?.setStreamHandler(ExternalViewHandler())
                        ExternalDisplayPlugin.sendParameters = FlutterMethodChannel(name: "sendParameters", binaryMessenger: flutterEngine.binaryMessenger)
                        flutterEngine.registrar(forPlugin: "").addMethodCallDelegate(ExternalDisplaySendParameters(), channel: ExternalDisplayPlugin.sendParameters!)

                        ExternalDisplayPlugin.externalWindow?.title = title
                        ExternalDisplayPlugin.externalWindow?.contentViewController = externalViewController
                        ExternalDisplayPlugin.externalWindow?.isReleasedWhenClosed = false
                        ExternalDisplayPlugin.externalWindow?.setFrameAutosaveName("External Window")
                        ExternalDisplayPlugin.externalWindow?.delegate = self;
                        
                        NotificationCenter.default.addObserver(
                            forName: NSWindow.willCloseNotification,
                            object: nil, // 监听所有窗口
                            queue: .main
                        ) { notification in
                            let window = notification.object as? NSWindow
                            if (window != ExternalDisplayPlugin.externalWindow) {
                                ExternalDisplayPlugin.externalWindow?.close()
                            }
                        }
                    }
                    
                    if (title != "External View") {
                        ExternalDisplayPlugin.externalWindow?.title = title
                    }
                        
                    ExternalDisplayPlugin.externalWindow?.orderFront(nil)
                    ExternalDisplayPlugin.externalWindow?.setFrame(frame, display: true)

                    if (fullscreen) {
                        ExternalDisplayPlugin.externalWindow?.toggleFullScreen(nil)
                    }

                    ExternalDisplayPlugin.mainViewEvents?(true)
                }

                result(true)
            
            case "destroyWindow":
                if (ExternalDisplayPlugin.externalWindow != nil) {
                    ExternalDisplayPlugin.externalWindow?.close()
                    return result(true)
                }
                result(false)
            
            case "connect":
                if (ExternalDisplayPlugin.externalWindow != nil) {
                    let size = ExternalDisplayPlugin.externalWindow?.contentView?.frame.size ?? NSSize(width: 1920, height: 1080)
                    result(["height":size.height, "width":size.width])
                }
                result(false)
            
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
    
    public func windowWillClose(_: Notification) {
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
        
        return nil
    }
    
    // 主頁面 Flutter 的停止監控 swift 傳回的資料
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
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
