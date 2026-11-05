import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Exit codes
// 0 sent | 1 not trusted | 2 usage | 3 device not found/ambiguous | 4 send failed | 5 timeout

// MARK: - Accessibility helpers

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ el: AXUIElement, _ name: String) -> String {
    (axAttr(el, name) as? String) ?? ""
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pvRaw = axAttr(el, kAXPositionAttribute),
          let svRaw = axAttr(el, kAXSizeAttribute) else { return nil }
    let pv = pvRaw as! AXValue
    let sv = svRaw as! AXValue
    var p = CGPoint.zero
    var s = CGSize.zero
    guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

// MARK: - Panel discovery

/// NSWorkspace.runningApplications is a cached snapshot that never refreshes
/// without a run loop, so enumerate PIDs through libproc instead.
func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

func candidatePIDs(explicitPID: pid_t?) -> [pid_t] {
    if let pid = explicitPID { return [pid] }
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    var result: [pid_t] = []
    for i in 0..<Int(count) where pids[i] > 0 {
        guard let path = executablePath(of: pids[i]) else { continue }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "airdrop" || path.lowercased().contains("airdrop") {
            result.append(pids[i])
        }
    }
    return result
}

func panelWindows(explicitPID: pid_t?) -> [AXUIElement] {
    var windows: [AXUIElement] = []
    for pid in candidatePIDs(explicitPID: explicitPID) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        for window in (axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if axString(window, kAXTitleAttribute) == "AirDrop" { windows.append(window) }
        }
    }
    return windows
}

// MARK: - Device rows

/// Device rows are AXButtons inside the panel's scroll area. Their description
/// gains a ", <status>" suffix once a transfer starts.
let statusSuffixes = ["Waiting…", "Waiting...", "Sending…", "Sending...", "Sent",
                      "Failed", "Declined", "Cancelled", "Canceled", "Not Delivered"]

struct Device {
    let name: String
    let status: String?
    let element: AXUIElement
    let frame: CGRect
    var label: String { status.map { "\(name), \($0)" } ?? name }
}

func splitStatus(_ raw: String) -> (name: String, status: String?) {
    for suffix in statusSuffixes where raw.hasSuffix(", " + suffix) {
        return (String(raw.dropLast(suffix.count + 2)), suffix)
    }
    return (raw, nil)
}

func collectButtons(_ root: AXUIElement, depth: Int = 0, insideScrollArea: Bool = false,
                    into out: inout [(AXUIElement, CGRect, Bool)]) {
    guard depth < 30 else { return }
    let role = axString(root, kAXRoleAttribute)
    let inScroll = insideScrollArea || role == "AXScrollArea"
    if role == "AXButton", let frame = axFrame(root), frame.width > 0, frame.height > 0 {
        out.append((root, frame, inScroll))
    }
    for child in axChildren(root) {
        collectButtons(child, depth: depth + 1, insideScrollArea: inScroll, into: &out)
    }
}

func scanDevices(explicitPID: pid_t?) -> [Device] {
    var devices: [Device] = []
    for window in panelWindows(explicitPID: explicitPID) {
        var buttons: [(AXUIElement, CGRect, Bool)] = []
        collectButtons(window, into: &buttons)
        let inScroll = buttons.filter { $0.2 }
        let chosen = inScroll.isEmpty ? buttons : inScroll
        for (el, frame, _) in chosen {
            let raw = axString(el, kAXDescriptionAttribute)
            guard !raw.isEmpty, raw != "Cancel", raw != "Done" else { continue }
            let (name, status) = splitStatus(raw)
            if devices.contains(where: { $0.name == name && $0.label == raw }) { continue }
            devices.append(Device(name: name, status: status, element: el, frame: frame))
        }
    }
    return devices
}

func matching(_ devices: [Device], _ query: String) -> [Device] {
    let exact = devices.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if !exact.isEmpty { return exact }
    return devices.filter { $0.name.localizedCaseInsensitiveContains(query) }
}

func waitForDevices(_ query: String, timeout: TimeInterval, explicitPID: pid_t?) -> [Device] {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while true {
        let hits = matching(scanDevices(explicitPID: explicitPID), query)
        if !hits.isEmpty { return hits }
        if Date() >= deadline { return [] }
        usleep(200_000)
    }
}

func findButton(describedAs label: String, explicitPID: pid_t?) -> AXUIElement? {
    for window in panelWindows(explicitPID: explicitPID) {
        var buttons: [(AXUIElement, CGRect, Bool)] = []
        collectButtons(window, into: &buttons)
        if let match = buttons.first(where: { axString($0.0, kAXDescriptionAttribute) == label }) {
            return match.0
        }
    }
    return nil
}

// MARK: - Actions

func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

enum Outcome {
    case sent
    case failed(String)
    case timeout
}

/// Watch the device row's status after pressing it. AXPress is the only method
/// that works: synthetic mouse clicks are ignored by the AirDrop remote view.
func awaitTransfer(_ name: String, timeout: TimeInterval, explicitPID: pid_t?) -> Outcome {
    let deadline = Date().addingTimeInterval(timeout)
    var lastLabel: String?
    while Date() < deadline {
        usleep(200_000)
        guard let device = scanDevices(explicitPID: explicitPID)
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            if panelWindows(explicitPID: explicitPID).isEmpty { return .timeout }
            continue
        }
        if device.label != lastLabel {
            lastLabel = device.label
            FileHandle.standardError.write("status: \(device.label)\n".data(using: .utf8)!)
        }
        switch device.status {
        case "Sent":
            return .sent
        case "Failed", "Declined", "Cancelled", "Canceled", "Not Delivered":
            return .failed(device.status!)
        default:
            break
        }
    }
    return .timeout
}

func postClick(_ p: CGPoint) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    func post(_ type: CGEventType, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: src, mouseType: type,
                                  mouseCursorPosition: p, mouseButton: .left) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        event.post(tap: .cghidEventTap)
    }
    post(.mouseMoved)
    usleep(120_000)
    post(.leftMouseDown, clickState: 1)
    usleep(80_000)
    post(.leftMouseUp, clickState: 1)
    usleep(150_000)
}

// MARK: - CLI

let usage = """
usage:
  click --device <name> [--wait <sec>] [--timeout <sec>] [--pid <pid>] [--dry-run] [--keep-open]
  click --list [--wait <sec>] [--pid <pid>]
  click <x> <y>
  click --check
"""

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(prompt)
print("accessibility-trusted: \(trusted)")

let argv = Array(CommandLine.arguments.dropFirst())

if argv == ["--check"] { exit(trusted ? 0 : 1) }

guard trusted else {
    FileHandle.standardError.write("accessibility permission not granted\n".data(using: .utf8)!)
    exit(1)
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

// Legacy coordinate mode.
if argv.count == 2, let x = Double(argv[0]), let y = Double(argv[1]) {
    postClick(CGPoint(x: x, y: y))
    print("clicked \(Int(x)),\(Int(y))")
    exit(0)
}

var listMode = false
var deviceQuery: String?
var dryRun = false
var keepOpen = false
var waitSeconds: TimeInterval = 10
var transferTimeout: TimeInterval = 120
var explicitPID: pid_t?

var i = 0
while i < argv.count {
    switch argv[i] {
    case "--list":
        listMode = true; i += 1
    case "--device":
        guard i + 1 < argv.count else { fail(usage, code: 2) }
        deviceQuery = argv[i + 1]; i += 2
    case "--dry-run":
        dryRun = true; i += 1
    case "--keep-open":
        keepOpen = true; i += 1
    case "--strict":
        i += 1  // verification is always on now; accepted for compatibility
    case "--wait":
        guard i + 1 < argv.count, let v = TimeInterval(argv[i + 1]) else { fail(usage, code: 2) }
        waitSeconds = v; i += 2
    case "--timeout":
        guard i + 1 < argv.count, let v = TimeInterval(argv[i + 1]) else { fail(usage, code: 2) }
        transferTimeout = v; i += 2
    case "--pid":
        guard i + 1 < argv.count, let v = pid_t(argv[i + 1]) else { fail(usage, code: 2) }
        explicitPID = v; i += 2
    default:
        fail(usage, code: 2)
    }
}

if listMode {
    let deadline = Date().addingTimeInterval(max(0, waitSeconds))
    var devices = scanDevices(explicitPID: explicitPID)
    while devices.isEmpty && Date() < deadline {
        usleep(200_000)
        devices = scanDevices(explicitPID: explicitPID)
    }
    guard !devices.isEmpty else { fail("no AirDrop devices found", code: 3) }
    for d in devices {
        print("device: \(d.label) @\(Int(d.frame.midX)),\(Int(d.frame.midY))")
    }
    exit(0)
}

guard let query = deviceQuery else { fail(usage, code: 2) }

let hits = waitForDevices(query, timeout: waitSeconds, explicitPID: explicitPID)
guard !hits.isEmpty else {
    let available = scanDevices(explicitPID: explicitPID).map(\.name)
    fail("device '\(query)' not found. available: \(available.isEmpty ? "none" : available.joined(separator: ", "))", code: 3)
}
guard hits.count == 1 else {
    fail("device '\(query)' is ambiguous: \(hits.map(\.name).joined(separator: ", "))", code: 3)
}

let target = hits[0]
print("press-target: \(target.label)")

if dryRun {
    print("dry-run: not pressing")
    exit(0)
}

guard press(target.element) else {
    fail("AXPress failed for '\(target.name)' (action unsupported)", code: 4)
}

switch awaitTransfer(target.name, timeout: transferTimeout, explicitPID: explicitPID) {
case .sent:
    print("sent: \(target.name)")
    if !keepOpen, let done = findButton(describedAs: "Done", explicitPID: explicitPID) {
        _ = press(done)
    }
    exit(0)
case .failed(let reason):
    fail("send failed: \(target.name) (\(reason))", code: 4)
case .timeout:
    fail("timed out waiting for transfer of '\(target.name)'", code: 5)
}
