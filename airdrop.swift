import AppKit
import ApplicationServices

// MARK: - Share lifecycle

final class AirdropRunner: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    private let urls: [URL]
    private let service: NSSharingService
    private var finished = false
    private var panelSeen = false
    private var panelClosed = false
    private let startedAt = Date()

    init(urls: [URL], service: NSSharingService) {
        self.urls = urls
        self.service = service
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[airdrop] \(message)\n".data(using: .utf8)!)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        log("perform")
        service.perform(withItems: urls)

        // Fallback: never linger forever if no delegate callback ever arrives.
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: false) { [weak self] _ in
            self?.finish(code: 1, message: "airdrop-timeout")
        }

        // If the share panel never shows up, don't sit around for 30 minutes.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self, !self.panelSeen else { return }
            self.finish(code: 1, message: "airdrop-no-panel")
        }

        // Track when the share panel goes away.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self, !self.panelClosed else { timer.invalidate(); return }
            let axApp = AXUIElementCreateApplication(getpid())
            var raw: AnyObject?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
            let windows = (raw as? [AXUIElement]) ?? []
            let hasPanel = windows.contains { window in
                var title: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                return (title as? String) == "AirDrop"
            }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(self.startedAt))
            if hasPanel && !self.panelSeen {
                self.panelSeen = true
                self.log("panel appeared at \(elapsed)s")
            }
            if !hasPanel && self.panelSeen {
                self.panelClosed = true
                self.log("panel closed at \(elapsed)s")
                timer.invalidate()
                // The panel stays up until the share finishes, so its
                // disappearance is the completion signal. Give the delegate a
                // moment to report a cancel/failure first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.finish(code: 0, message: "airdrop-finished")
                }
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        log("willShareItems")
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        log("didShareItems")
        finish(code: 0, message: "airdrop-sent")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        log("didFailToShareItems: \(error.localizedDescription)")
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError {
            finish(code: 130, message: "airdrop-cancelled")
        } else {
            finish(code: 1, message: "airdrop-failed: \(error.localizedDescription)")
        }
    }

    private func finish(code: Int32, message: String) {
        guard !finished else { return }
        finished = true

        let out = code == 0 ? FileHandle.standardOutput : FileHandle.standardError
        out.write((message + "\n").data(using: .utf8)!)

        // Release any busy/wait cursor the share UI pushed onto the cursor stack.
        NSCursor.arrow.set()

        // Give the panel a beat to finish dismissing before the process goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exit(code)
        }
    }
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())

if args == ["--check"] {
    _ = NSApplication.shared
    if let s = NSSharingService(named: .sendViaAirDrop) {
        print("airdrop-available: \(s.title)")
        exit(0)
    } else {
        print("airdrop-unavailable")
        exit(1)
    }
}

guard !args.isEmpty else {
    FileHandle.standardError.write("usage: airdrop <file|dir>... | --check\n".data(using: .utf8)!)
    exit(2)
}

let urls = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
for u in urls where !FileManager.default.fileExists(atPath: u.path) {
    FileHandle.standardError.write("missing: \(u.path)\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let service = NSSharingService(named: .sendViaAirDrop) else {
    FileHandle.standardError.write("AirDrop sharing service unavailable\n".data(using: .utf8)!)
    exit(1)
}

let runner = AirdropRunner(urls: urls, service: service)
app.delegate = runner
app.run()
