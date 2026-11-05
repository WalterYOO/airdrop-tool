import AppKit
import ApplicationServices

func envSeconds(_ name: String, default fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[name],
          let value = Double(raw), value > 0 else { return fallback }
    return value
}

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

        let totalTimeout = envSeconds("AIRDROP_TOTAL_TIMEOUT", default: 1800)
        let panelTimeout = envSeconds("AIRDROP_PANEL_TIMEOUT", default: 30)

        // Fallback: never linger forever if no delegate callback ever arrives.
        Timer.scheduledTimer(withTimeInterval: totalTimeout, repeats: false) { [weak self] _ in
            self?.finish(code: 1, message: "airdrop-timeout")
        }

        // If the share panel never shows up, don't sit around for the full timeout.
        Timer.scheduledTimer(withTimeInterval: panelTimeout, repeats: false) { [weak self] _ in
            guard let self = self, !self.panelSeen else { return }
            self.finish(code: 1, message: "airdrop-no-panel")
        }

        // Track when the share panel goes away. This process has no other
        // windows, so any window means the panel is up. The title is localized
        // and must not be used as the identifier.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self, !self.panelClosed else { timer.invalidate(); return }
            let axApp = AXUIElementCreateApplication(getpid())
            var raw: AnyObject?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
            let hasPanel = !((raw as? [AXUIElement]) ?? []).isEmpty
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
                    self?.finish(code: 0, message: "airdrop-dismissed")
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
        let cancelled = (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
            || (ns.domain == NSOSStatusErrorDomain && ns.code == -128)  // userCanceledErr
        if cancelled {
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

let usage = "usage: airdrop <file|dir>... | --check | --help\n"
let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--help") || args.contains("-h") {
    print("usage: airdrop <file|dir>... | --check | --help")
    exit(0)
}

if args.first == "--check" {
    guard args.count == 1 else {
        FileHandle.standardError.write(usage.data(using: .utf8)!)
        exit(2)
    }
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
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}

let urls = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
for u in urls {
    guard FileManager.default.fileExists(atPath: u.path) else {
        FileHandle.standardError.write("missing: \(u.path)\n".data(using: .utf8)!)
        exit(2)
    }
    guard FileManager.default.isReadableFile(atPath: u.path) else {
        FileHandle.standardError.write("unreadable: \(u.path)\n".data(using: .utf8)!)
        exit(2)
    }
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
