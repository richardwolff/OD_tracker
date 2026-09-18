// OD Tracker — macOS desktop wrapper.
//
// A single window hosting index.html in a WKWebView, so the tracker runs as a
// normal Mac app: its own Dock icon and menu bar, Cmd+Q, a Save dialog for
// exports, and data that persists between launches. Built and installed by
// install-mac-app.sh; there is no Xcode project.
//
// Data lives in WebKit's store for this bundle id, not in any browser:
//     ~/Library/WebKit/<bundle id>/WebsiteData/

import Cocoa
import WebKit

let appName = "OD Tracker"

final class AppDelegate: NSObject, NSApplicationDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    var titleWatch: NSKeyValueObservation?
    // Folder of the last export, so the next Save dialog opens there — the data
    // and the metadata for a run belong together.
    var lastSaveDir: URL?

    // ---------------------------------------------------------------- launch
    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // persistent localStorage
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.minSize = NSSize(width: 480, height: 400)
        window.contentView = webView
        window.center()
        // remember size and position across launches
        window.setFrameAutosaveName("ODTrackerMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // follow the page title, falling back to the app name while loading
        titleWatch = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            let t = wv.title ?? ""
            self?.window.title = t.isEmpty ? appName : t
        }

        guard let page = Bundle.main.url(forResource: "index", withExtension: "html") else {
            fatal("index.html is missing from the app bundle. Re-run install-mac-app.sh.")
            return
        }
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // ---------------------------------------------------------------- navigation
    // Exports are <a download> clicks on blob: URLs; WebKit flags those as
    // downloads and we route them to a Save dialog. Anything pointing off the
    // machine goes to the default browser rather than replacing the app page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences); return
        }
        if let url = action.request.url, let scheme = url.scheme,
           scheme == "http" || scheme == "https" || scheme == "mailto" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel, preferences); return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // ---------------------------------------------------------------- downloads
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { completionHandler(nil); return }
            self?.lastSaveDir = url.deletingLastPathComponent()
            // the panel has already asked about replacing; WKDownload itself
            // refuses to overwrite, so clear the way for it
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // a cancelled Save dialog also lands here — not worth an alert
        if (error as NSError).code == NSURLErrorCancelled { return }
        let alert = NSAlert()
        alert.messageText = "Could not save the file"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // ---------------------------------------------------------------- file picker
    // "Import project" is an <input type=file>; WKWebView on macOS shows no
    // picker for it unless we provide one.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // ---------------------------------------------------------------- menu
    // A programmatic app has no menu unless it builds one, and without an Edit
    // menu Cmd+C/V/X/A do nothing in the culture-name and note fields.
    func buildMenu() {
        let bar = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(submenu(app, title: appName))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        bar.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(zoomActual(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen",
                                action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        bar.addItem(submenu(view, title: "View"))

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        bar.addItem(submenu(win, title: "Window"))
        NSApp.windowsMenu = win

        NSApp.mainMenu = bar
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc func reload(_ sender: Any?)     { webView.reload() }
    @objc func zoomActual(_ sender: Any?) { webView.pageZoom = 1 }
    @objc func zoomIn(_ sender: Any?)     { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?)    { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }

    // ---------------------------------------------------------------- errors
    private func fatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "\(appName) cannot start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
