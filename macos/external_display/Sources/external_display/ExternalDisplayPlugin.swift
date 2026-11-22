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

    /// AppKit saves the external window's frame in the user defaults under this name
    /// on each move and at the end of each resize, so the frame also survives a crash.
    static let frameAutosaveName = "External Window"

    /// The window's title, in the user defaults, while the window is open. The operator
    /// closing the window removes it; the app quitting or being killed does not, and
    /// `MainViewHandler.onListen` opens the window again at the next launch
    /// (taiyodayo/maiTalk#2002).
    static let openDefaultsKey = "External Window Open"

    /// Called by `disconnect` first, while the window and its engine still exist, so the
    /// host can let go of what it attached to the window (taiyodayo/maiTalk#2024).
    public static var willReleaseExternalWindow: ((NSWindow) -> Void)?

    /// The `willClose` observer `createWindow` adds with each new window.
    private static var willCloseObserver: NSObjectProtocol?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        // 建立 Flutter EventChannel
        let onDisplayChange = FlutterEventChannel(name: "monitorStateListener", binaryMessenger: registrar.messenger)
        let plugin = ExternalDisplayPlugin()
        // Only the main page's engine opens the window again at launch. The external
        // window's engine registers here too, while its window is being built.
        onDisplayChange.setStreamHandler(MainViewHandler(plugin: externalWindow == nil ? plugin : nil))
        
        // 建立 Flutter MethodChannel
        let connect = FlutterMethodChannel(name: "displayController", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(plugin, channel: connect)
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

                    // The default frame, ON the target screen. Fullscreen covers it;
                    // windowed (no saved frame) is clamped to the visible frame and
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
                        ExternalDisplayPlugin.externalWindow?.setFrameAutosaveName(ExternalDisplayPlugin.frameAutosaveName)
                        ExternalDisplayPlugin.externalWindow?.delegate = self;
                        
                        ExternalDisplayPlugin.willCloseObserver = NotificationCenter.default.addObserver(
                            forName: NSWindow.willCloseNotification,
                            object: nil,
                            queue: .main
                        ) { notification in
                            if ExternalDisplayPlugin.closesExternalWindow(whenClosing: notification.object as? NSWindow) {
                                ExternalDisplayPlugin.externalWindow?.close()
                            }
                        }
                    }
                    
                    if (title != "External View") {
                        ExternalDisplayPlugin.externalWindow?.title = title
                    }
                        
                    ExternalDisplayPlugin.externalWindow?.orderFront(nil)
                    // Windowed, the window opens where it was last left, on whichever
                    // screen that was: the saved frame, which AppKit moves back onto a
                    // screen when it is off all of them. `frame`, on `targetScreen`, is
                    // the default for a first use (taiyodayo/maiTalk#1970).
                    if fullscreen || ExternalDisplayPlugin.externalWindow?.setFrameUsingName(ExternalDisplayPlugin.frameAutosaveName) != true {
                        ExternalDisplayPlugin.externalWindow?.setFrame(frame, display: true)
                    }

                    if (fullscreen) {
                        ExternalDisplayPlugin.externalWindow?.toggleFullScreen(nil)
                    }

                    // Last: a launch that dies while the window opens does not open it
                    // again at the next one.
                    UserDefaults.standard.set(title, forKey: ExternalDisplayPlugin.openDefaultsKey)
                    ExternalDisplayPlugin.mainViewEvents?(true)
                }

                result(true)
            
            case "destroyWindow":
                UserDefaults.standard.removeObject(forKey: ExternalDisplayPlugin.openDefaultsKey)
                if (ExternalDisplayPlugin.externalWindow != nil) {
                    ExternalDisplayPlugin.externalWindow?.close()
                    return result(true)
                }
                result(false)
            
            // Release the window and its engine: an engine that failed to start is
            // not reused, and the next `createWindow` builds a new one
            // (taiyodayo/maiTalk#2024). `destroyWindow` keeps both for an instant reopen.
            case "disconnect":
                guard let window = ExternalDisplayPlugin.externalWindow else { return result(false) }
                ExternalDisplayPlugin.release(window)
                result(true)

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
    
    /// Closes [window] for good: the close emits the unplug as a close does, then the
    /// window, its engine and every static that points into that engine go.
    static func release(_ window: NSWindow) {
        willReleaseExternalWindow?(window)
        UserDefaults.standard.removeObject(forKey: openDefaultsKey)
        if let observer = willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            willCloseObserver = nil
        }
        window.close()
        // The next window takes the saved frame under this name.
        window.setFrameAutosaveName("")
        window.delegate = nil
        let controller = window.contentViewController as? FlutterViewController
        window.contentViewController = nil
        controller?.engine.shutDownEngine()
        externalWindow = nil
        externalViewEvents = nil
        connectReturn = nil
        receiveParameters?.setStreamHandler(nil)
        receiveParameters = nil
        sendParameters = nil
    }

    public func windowWillClose(_: Notification) {
        ExternalDisplayPlugin.mainViewEvents?(false)
    }

    /// The operator closes the window (its close button, ⌘W): it stays closed at the
    /// next launch. AppKit does not ask when the window closes with the app: `close()`
    /// from the observer in `createWindow`, or a quit.
    public func windowShouldClose(_: NSWindow) -> Bool {
        UserDefaults.standard.removeObject(forKey: ExternalDisplayPlugin.openDefaultsKey)
        return true
    }

    /// Whether the external window closes with `window`: only when `window` is another
    /// window that hosts a Flutter view, i.e. the app's own window.
    ///
    /// Every other close is ignored. AppKit closes private windows of its own (macOS
    /// 27.2.1 closes one while a window leaves full screen), and panels and dialogs
    /// close all the time. Closing the external window for one of those took it away
    /// from the audience, and in the middle of its own full-screen exit AppKit raised
    /// `NSInternalInconsistencyException` (taiyodayo/maiTalk#1943).
    static func closesExternalWindow(whenClosing window: NSWindow?) -> Bool {
        guard let window, window !== externalWindow else { return false }
        return window.contentViewController is FlutterViewController
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
    /// The main page's method-call handler, which is also the external window's delegate;
    /// nil on the external window's own engine.
    private let plugin: ExternalDisplayPlugin?

    init(plugin: ExternalDisplayPlugin?) {
        self.plugin = plugin
    }

    // 主頁面 Flutter 的開始監控 swift 傳回的資料
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        ExternalDisplayPlugin.mainViewEvents = events

        // The window was open when the app last quit or was killed: open it again, as
        // `createWindow` from the main page would. The value is taken, and `createWindow`
        // writes it back once the window is open.
        let defaults = UserDefaults.standard
        if let plugin, let title = defaults.string(forKey: ExternalDisplayPlugin.openDefaultsKey) {
            defaults.removeObject(forKey: ExternalDisplayPlugin.openDefaultsKey)
            plugin.handle(FlutterMethodCall(methodName: "createWindow", arguments: ["title": title]), result: { _ in })
        }

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
