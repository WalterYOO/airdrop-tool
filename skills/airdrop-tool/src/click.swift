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
    guard let pvRaw = axAttr(el, kAXPositionAttribute), CFGetTypeID(pvRaw) == AXValueGetTypeID(),
          let svRaw = axAttr(el, kAXSizeAttribute), CFGetTypeID(svRaw) == AXValueGetTypeID() else {
        return nil
    }
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

/// Only a process whose executable is exactly named `airdrop` owns the panel.
/// This deliberately excludes the system `AirDrop.appex` and this executable.
func candidatePIDs(explicitPID: pid_t?) -> [pid_t] {
    if let pid = explicitPID { return [pid] }
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    let me = getpid()
    var result: [pid_t] = []
    for i in 0..<Int(count) where pids[i] > 0 && pids[i] != me {
        guard let path = executablePath(of: pids[i]) else { continue }
        if URL(fileURLWithPath: path).lastPathComponent == "airdrop" {
            result.append(pids[i])
        }
    }
    return result
}

func hasScrollArea(_ el: AXUIElement, depth: Int = 0) -> Bool {
    guard depth < 12 else { return false }
    if axString(el, kAXRoleAttribute) == "AXScrollArea" { return true }
    for child in axChildren(el) where hasScrollArea(child, depth: depth + 1) { return true }
    return false
}

/// The panel is identified by structure (a window containing a scroll area),
/// not by its localized title.
func panelWindows(explicitPID: pid_t?) -> [AXUIElement] {
    var windows: [AXUIElement] = []
    for pid in candidatePIDs(explicitPID: explicitPID) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        for window in (axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if hasScrollArea(window) { windows.append(window) }
        }
    }
    return windows
}

// MARK: - Device rows

/// Device rows are AXButtons inside the panel's scroll area. Once a transfer
/// starts their description gains a ", <status>" suffix. Status text is
/// localized, so only known words are stripped from names; everything after
/// the pressed device's name is reported as-is.
let successStatuses: Set<String> = ["Sent", "已发送", "已傳送"]
let failureStatuses: Set<String> = ["Failed", "Declined", "Cancelled", "Canceled", "Not Delivered",
                                    "失败", "已拒绝", "已取消", "未送达", "傳送失敗", "已拒絕", "已取消"]
let pendingStatuses: Set<String> = ["Waiting", "Waiting…", "Waiting...",
                                    "Sending", "Sending…", "Sending...",
                                    "正在等待", "正在等待…", "正在等待...",
                                    "正在发送", "正在发送…", "正在发送..."]
let knownStatuses = successStatuses.union(failureStatuses).union(pendingStatuses)

struct Device {
    let name: String
    let status: String?
    let raw: String
    let element: AXUIElement
    let frame: CGRect
}

func splitKnownStatus(_ raw: String) -> (name: String, status: String?) {
    for suffix in knownStatuses where raw.hasSuffix(", " + suffix) {
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

/// Only buttons inside the scroll area are device rows. There is deliberately
/// no fallback to other buttons, which could be settings controls.
func scanDevices(explicitPID: pid_t?) -> [Device] {
    autoreleasepool {
        var devices: [Device] = []
        for window in panelWindows(explicitPID: explicitPID) {
            var buttons: [(AXUIElement, CGRect, Bool)] = []
            collectButtons(window, into: &buttons)
            for (el, frame, inScroll) in buttons where inScroll {
                let raw = axString(el, kAXDescriptionAttribute)
                guard !raw.isEmpty else { continue }
                let (name, status) = splitKnownStatus(raw)
                guard !name.isEmpty else { continue }
                if devices.contains(where: { $0.raw == raw && $0.frame == frame }) { continue }
                devices.append(Device(name: name, status: status, raw: raw, element: el, frame: frame))
            }
        }
        return devices
    }
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
        usleep(300_000)
    }
}

/// The panel's only button outside the scroll area is Cancel (later Done).
func dismissButton(explicitPID: pid_t?) -> AXUIElement? {
    for window in panelWindows(explicitPID: explicitPID) {
        var buttons: [(AXUIElement, CGRect, Bool)] = []
        collectButtons(window, into: &buttons)
        if let button = buttons.first(where: { !$0.2 }) { return button.0 }
    }
    return nil
}

// MARK: - Actions

func press(_ element: AXUIElement) -> AXError {
    var error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    var attempts = 0
    while error == .cannotComplete && attempts < 3 {
        usleep(200_000)
        attempts += 1
        error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
    return error
}

func dismissPanel(explicitPID: pid_t?) {
    guard let button = dismissButton(explicitPID: explicitPID) else { return }
    var attempts = 0
    while attempts < 3 {
        if press(button) == .success { return }
        usleep(200_000)
        attempts += 1
    }
}

enum Outcome {
    case sent
    case failed(String)
    case panelClosed
    case timeout
}

/// Watch the pressed device's description. Status text is localized, so match
/// on the known device name prefix and classify the suffix.
func awaitTransfer(_ name: String, element: AXUIElement,
                   timeout: TimeInterval, explicitPID: pid_t?) -> Outcome {
    let deadline = Date().addingTimeInterval(timeout)
    var lastLabel: String?
    while Date() < deadline {
        usleep(300_000)
        var raw = axString(element, kAXDescriptionAttribute)
        if raw.isEmpty {
            raw = scanDevices(explicitPID: explicitPID)
                .first(where: { $0.raw == name || $0.raw.hasPrefix(name + ", ") })?.raw ?? ""
        }
        guard !raw.isEmpty else {
            if panelWindows(explicitPID: explicitPID).isEmpty { return .panelClosed }
            continue
        }
        if raw != lastLabel {
            lastLabel = raw
            FileHandle.standardError.write("status: \(raw)\n".data(using: .utf8)!)
        }
        guard raw.hasPrefix(name + ", ") else { continue }
        let status = String(raw.dropFirst(name.count + 2))
        if successStatuses.contains(status) { return .sent }
        if failureStatuses.contains(status) { return .failed(status) }
    }
    return .timeout
}

func postClick(_ p: CGPoint) -> Bool {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
    var posted = true
    func post(_ type: CGEventType, clickState: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource: src, mouseType: type,
                                  mouseCursorPosition: p, mouseButton: .left) else {
            posted = false
            return
        }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        event.post(tap: .cghidEventTap)
    }
    post(.mouseMoved)
    usleep(120_000)
    post(.leftMouseDown, clickState: 1)
    usleep(80_000)
    post(.leftMouseUp, clickState: 1)
    usleep(150_000)
    return posted
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
FileHandle.standardError.write("accessibility-trusted: \(trusted)\n".data(using: .utf8)!)

let argv = Array(CommandLine.arguments.dropFirst())

if argv == ["--check"] { exit(trusted ? 0 : 1) }

guard trusted else {
    FileHandle.standardError.write("accessibility permission not granted\n".data(using: .utf8)!)
    exit(1)
}

// Apply the timeout process-wide, not just to one app element.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

// Legacy coordinate mode.
if argv.count == 2, let x = Double(argv[0]), let y = Double(argv[1]) {
    guard postClick(CGPoint(x: x, y: y)) else { fail("could not create mouse events", code: 4) }
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
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--list":
        listMode = true; i += 1
    case "--device":
        guard i + 1 < argv.count else { fail(usage, code: 2) }
        deviceQuery = argv[i + 1]; i += 2
    case "--dry-run":
        dryRun = true; i += 1
    case "--keep-open":
        keepOpen = true; i += 1
    case "--wait":
        guard i + 1 < argv.count, let v = TimeInterval(argv[i + 1]) else { fail(usage, code: 2) }
        waitSeconds = v; i += 2
    case "--timeout":
        guard i + 1 < argv.count, let v = TimeInterval(argv[i + 1]) else { fail(usage, code: 2) }
        transferTimeout = v; i += 2
    case "--pid":
        guard i + 1 < argv.count, let v = pid_t(argv[i + 1]), v > 0 else { fail(usage, code: 2) }
        explicitPID = v; i += 2
    default:
        fail(usage, code: 2)
    }
}

if listMode && deviceQuery != nil { fail("--list and --device are mutually exclusive\n" + usage, code: 2) }

if listMode {
    let deadline = Date().addingTimeInterval(max(0, waitSeconds))
    var devices = scanDevices(explicitPID: explicitPID)
    while devices.isEmpty && Date() < deadline {
        usleep(300_000)
        devices = scanDevices(explicitPID: explicitPID)
    }
    guard !devices.isEmpty else { fail("no AirDrop devices found", code: 3) }
    for d in devices { print("device: \(d.raw) @\(Int(d.frame.midX)),\(Int(d.frame.midY))") }
    exit(0)
}

guard let query = deviceQuery else { fail(usage, code: 2) }
guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { fail("device name must not be empty\n" + usage, code: 2) }

let hits = waitForDevices(query, timeout: waitSeconds, explicitPID: explicitPID)
guard !hits.isEmpty else {
    let available = scanDevices(explicitPID: explicitPID).map(\.raw)
    fail("device '\(query)' not found. available: \(available.isEmpty ? "none" : available.joined(separator: ", "))", code: 3)
}
guard hits.count == 1 else {
    fail("device '\(query)' is ambiguous: \(hits.map(\.raw).joined(separator: ", "))", code: 3)
}

let target = hits[0]
print("press-target: \(target.raw)")

if dryRun {
    print("dry-run: not pressing")
    exit(0)
}

let pressError = press(target.element)
guard pressError == .success else {
    fail("AXPress failed for '\(target.name)' (AXError \(pressError.rawValue))", code: 4)
}

switch awaitTransfer(target.name, element: target.element,
                     timeout: transferTimeout, explicitPID: explicitPID) {
case .sent:
    print("sent: \(target.name)")
    if !keepOpen { dismissPanel(explicitPID: explicitPID) }
    exit(0)
case .failed(let reason):
    if !keepOpen { dismissPanel(explicitPID: explicitPID) }
    fail("send failed: \(target.name) (\(reason))", code: 4)
case .panelClosed:
    fail("panel closed before the transfer finished for '\(target.name)'", code: 4)
case .timeout:
    if !keepOpen { dismissPanel(explicitPID: explicitPID) }
    fail("timed out waiting for transfer of '\(target.name)'", code: 5)
}
