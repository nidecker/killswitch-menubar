// Menu bar icon for a WireGuard kill switch.
//
// The tunnel to protect, its server and its interface are read from the
// system VPN configuration (scutil), where the WireGuard app declares them.
//
// The state is not guessed: every 5 s (and on every network change), the app
// attempts a real TCP connection that leaves directly through Wi-Fi/Ethernet,
// outside the tunnel. If it succeeds, traffic can leak; if pf rejects it,
// the kill switch is working.

import Cocoa
import Network
import ServiceManagement

private let probeTargets = ["1.1.1.1", "8.8.8.8"]
private let defaultPort = 51820
private let scutil = "/usr/sbin/scutil"
private let wireGuardBundleID = "com.wireguard.macos"

// MARK: - System

func run(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output
}

/// Value of the first "key : value" line in scutil output.
func scutilValue(_ key: String, in output: String) -> String? {
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

// MARK: - WireGuard tunnels

struct Tunnel {
    let id: String
    let name: String
    let connected: Bool

    /// The config's Endpoint field, as the WireGuard app declares it to the system.
    var endpoint: String? { scutilValue("RemoteAddress", in: run(scutil, ["--nc", "show", id])) }
    /// utunN interface, only while the tunnel is connected.
    var interface: String? { scutilValue("InterfaceName", in: run(scutil, ["--nc", "status", id])) }
}

func wireGuardTunnels() -> [Tunnel] {
    run(scutil, ["--nc", "list"]).split(separator: "\n").compactMap { line in
        guard line.contains("[VPN:com.wireguard.macos]"),
              let match = line.firstMatch(of: #/\((\w+)\)\s+([0-9A-F-]{36}).*?"(.*)"/#)
        else { return nil }
        return Tunnel(id: String(match.2), name: String(match.3), connected: match.1 == "Connected")
    }
}

// MARK: - Network

/// IPv4 addresses of active interfaces, keyed by interface name.
func ipv4Addresses() -> [String: String] {
    var result: [String: String] = [:]
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
    defer { freeifaddrs(ifap) }
    let upRunning = UInt32(IFF_UP | IFF_RUNNING)
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              ifa.ifa_flags & upRunning == upRunning else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        result[String(cString: ifa.ifa_name)] = String(cString: host)
    }
    return result
}

/// Attempts a TCP connection to `ip:443`, forcing it out through `iface`.
/// true = connected, false = refused, nil = no answer.
func canConnect(via iface: String, to ip: String, timeoutMs: Int32 = 1500) -> Bool? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var index = if_nametoindex(iface)
    guard index != 0,
          setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
    else { return nil }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(443).bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}

/// IP addresses (v4 and v6) of a host name or a literal IP.
func resolve(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
    defer { freeaddrinfo(res) }
    var ips: [String] = []
    for ai in sequence(first: first, next: { $0.pointee.ai_next }) {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(String(cString: buf).split(separator: "%")[0])
        if !ips.contains(ip) { ips.append(ip) }
    }
    return ips
}

/// "host:port", "[ipv6]:port" or just "host" (port 51820 by default).
func parseEndpoint(_ raw: String) -> (host: String, port: Int)? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    var host = s
    var port = defaultPort
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
        host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]
        if rest.hasPrefix(":") {
            guard let p = Int(rest.dropFirst()) else { return nil }
            port = p
        }
    } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
        host = String(s[..<colon])
        guard let p = Int(s[s.index(after: colon)...]) else { return nil }
        port = p
    }
    guard !host.isEmpty, !host.contains(" "), (1...65535).contains(port) else { return nil }
    return (host, port)
}

func isIPLiteral(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
}

// MARK: - State

enum Exposure { case blocked, leaking(String), noNetwork }

struct Snapshot {
    var exposure: Exposure
    /// Connected WireGuard tunnel, if any.
    var tunnel: Tunnel?
    var endpoint: String?
    var interface: String?
    var address: String?
}

func takeSnapshot() -> Snapshot {
    let addresses = ipv4Addresses()
    let physical = addresses.keys.filter { $0.hasPrefix("en") }.sorted()

    var exposure = Exposure.noNetwork
    if !physical.isEmpty {
        exposure = .blocked
        probing: for iface in physical {
            for ip in probeTargets {
                guard let connected = canConnect(via: iface, to: ip) else { continue }
                if connected { exposure = .leaking(iface); break probing }
                break
            }
        }
    }

    let tunnel = wireGuardTunnels().first { $0.connected }
    let interface = tunnel?.interface
    return Snapshot(exposure: exposure, tunnel: tunnel, endpoint: tunnel?.endpoint,
                    interface: interface, address: interface.flatMap { addresses[$0] })
}

enum Ring { case full, broken, none }

enum Status {
    case protected, vpnDown, mismatch(String), exposed(String), offline

    var ring: Ring {
        switch self {
        case .protected, .vpnDown, .mismatch: .full
        case .exposed: .broken
        case .offline: .none
        }
    }

    var color: NSColor? {
        switch self {
        case .protected: .systemGreen
        case .vpnDown, .mismatch: .systemOrange
        case .exposed: .systemRed
        case .offline: nil
        }
    }

    var headline: String {
        switch self {
        case .protected: "Protected: traffic only leaves through the VPN"
        case .vpnDown: "VPN down: internet blocked"
        case .mismatch(let name): "Kill switch set for a tunnel other than \(name): internet blocked"
        case .exposed(let i): "Kill switch off: traffic can leave through \(i)"
        case .offline: "No network"
        }
    }
}

// MARK: - Icon

/// Maximum height of a menu bar icon.
private let iconSize: CGFloat = 22

/// Keyhole inside a ring: full when internet can only go out through the VPN,
/// down to two quarters when the kill switch is off.
/// The keyhole takes the menu bar text color (light or dark).
func statusIcon(for status: Status?) -> NSImage {
    let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
        NSColor.labelColor.setFill()
        drawKeyhole(in: rect.insetBy(dx: 5.5, dy: 5.5))

        guard let status, let color = status.color else { return true }
        color.setStroke()
        let lineWidth: CGFloat = 1.6
        let radius = rect.width / 2 - lineWidth / 2 - 0.2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        // Top-right and bottom-left quarters
        let arcs: [(CGFloat, CGFloat)] = switch status.ring {
        case .full: [(0, 360)]
        case .broken: [(0, 90), (180, 270)]
        case .none: []
        }
        for (start, end) in arcs {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()
        }
        return true
    }
    image.accessibilityDescription = status?.headline ?? "WireGuard kill switch"
    return image
}

// MARK: - Root commands

enum PrivilegedResult { case ok, cancelled, failed(String) }

func runPrivileged(_ args: [String]) -> PrivilegedResult {
    guard let script = Bundle.main.path(forResource: "wgks-pf", ofType: "sh") else {
        return .failed("wgks-pf.sh is missing from the app bundle.")
    }
    let shell = (["/bin/bash", script] + args)
        .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        .joined(separator: " ")
    let escaped = shell
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
        .executeAndReturnError(&error)
    guard let error else { return .ok }
    if error[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
    return .failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error.")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let pathMonitor = NWPathMonitor()
    private let probeQueue = DispatchQueue(label: "wgks.probe")
    private let defaults = UserDefaults.standard
    private var probing = false
    private var snapshot: Snapshot?

    /// Tunnel and interface the pf rules were loaded for.
    private var appliedTunnel: String? { defaults.string(forKey: "appliedTunnel") }
    private var appliedInterface: String? { defaults.string(forKey: "appliedInterface") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        render()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == wireGuardBundleID { self?.updateVisibility() }
            }
        }
        updateVisibility()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        pathMonitor.start(queue: probeQueue)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private var status: Status? {
        guard let snapshot else { return nil }
        switch snapshot.exposure {
        case .noNetwork: return .offline
        case .leaking(let iface): return .exposed(iface)
        case .blocked:
            guard let tunnel = snapshot.tunnel, let interface = snapshot.interface else { return .vpnDown }
            if let applied = appliedInterface,
               applied != interface || appliedTunnel != tunnel.name {
                return .mismatch(tunnel.name)
            }
            return .protected
        }
    }

    /// The icon only shows while the WireGuard app is running, unless the kill switch
    /// is on: it must then stay reachable to turn it off, even with WireGuard closed.
    private func updateVisibility() {
        let wireGuardRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: wireGuardBundleID).isEmpty
        statusItem.isVisible = wireGuardRunning || appliedTunnel != nil
        refresh()
    }

    private func refresh() {
        guard statusItem.isVisible, !probing else { return }
        probing = true
        probeQueue.async {
            let snapshot = takeSnapshot()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.probing = false
                // Traffic gets out while we thought the kill switch was on: its rules are
                // gone (reboot, removed by hand). Forget that setting, which also hides
                // the icon if WireGuard is closed.
                if case .leaking = snapshot.exposure, self.appliedTunnel != nil {
                    self.defaults.removeObject(forKey: "appliedTunnel")
                    self.defaults.removeObject(forKey: "appliedInterface")
                    self.updateVisibility()
                }
                self.render()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = statusIcon(for: status)
        button.toolTip = status?.headline ?? "Checking…"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = self.status

        menu.addItem(info(status?.headline ?? "Checking…"))
        if let snapshot, let tunnel = snapshot.tunnel {
            let details = [snapshot.interface, snapshot.address].compactMap { $0 }
            menu.addItem(info("Tunnel: \(([tunnel.name] + details).joined(separator: " · "))"))
            if let endpoint = snapshot.endpoint {
                menu.addItem(info("Server: \(endpoint)"))
                if let host = parseEndpoint(endpoint)?.host, !isIPLiteral(host) {
                    menu.addItem(info("⚠︎ Server is a host name: the kill switch blocks reconnection"))
                }
            }
        } else {
            menu.addItem(info("Tunnel: none connected"))
        }
        if case .blocked? = snapshot?.exposure, let applied = appliedTunnel, applied != snapshot?.tunnel?.name {
            menu.addItem(info("Kill switch set for: \(applied)"))
        }
        menu.addItem(.separator())

        switch status {
        case .mismatch(let name)?:
            menu.addItem(action("Reapply for \(name)", #selector(enable)))
            menu.addItem(action("Turn Off Kill Switch", #selector(disable)))
        case .protected?, .vpnDown?:
            menu.addItem(action("Turn Off Kill Switch", #selector(disable)))
        case .exposed?, .offline?, nil:
            menu.addItem(action("Turn On Kill Switch", #selector(enable)))
        }
        menu.addItem(.separator())

        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func enable() {
        guard let tunnel = wireGuardTunnels().first(where: { $0.connected }),
              let interface = tunnel.interface else {
            showAlert("Connect a WireGuard tunnel first",
                      "The kill switch protects the active tunnel: it needs its interface and its server.")
            return
        }
        guard let raw = tunnel.endpoint, let endpoint = parseEndpoint(raw) else {
            showAlert("Unreadable server", "Could not read the Endpoint of tunnel \(tunnel.name).")
            return
        }

        // If DNS is already blocked, fall back to the addresses resolved last time
        let cacheKey = "endpointIPs.\(tunnel.id)"
        var ips = resolve(endpoint.host)
        if ips.isEmpty { ips = defaults.stringArray(forKey: cacheKey) ?? [] }
        guard !ips.isEmpty else {
            showAlert("Server not found", "Could not resolve \(endpoint.host).")
            return
        }
        defaults.set(ips, forKey: cacheKey)

        switch runPrivileged(["on", interface, String(endpoint.port)] + ips) {
        case .ok:
            defaults.set(tunnel.name, forKey: "appliedTunnel")
            defaults.set(interface, forKey: "appliedInterface")
        case .cancelled: break
        case .failed(let message): showAlert("Could not turn on the kill switch", message)
        }
        refresh()
    }

    @objc private func disable() {
        switch runPrivileged(["off"]) {
        case .ok:
            defaults.removeObject(forKey: "appliedTunnel")
            defaults.removeObject(forKey: "appliedInterface")
        case .cancelled: break
        case .failed(let message): showAlert("Could not turn off the kill switch", message)
        }
        updateVisibility()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Could not change Open at Login", error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// `--status` prints the state to the terminal, without any UI.
if CommandLine.arguments.contains("--status") {
    for tunnel in wireGuardTunnels() {
        print("Tunnel \(tunnel.connected ? "●" : "○") \(tunnel.name) → \(tunnel.endpoint ?? "?")")
    }
    let snapshot = takeSnapshot()
    switch snapshot.exposure {
    case .blocked: print("Direct exit: blocked (kill switch on)")
    case .leaking(let iface): print("Direct exit: POSSIBLE through \(iface) (kill switch off)")
    case .noNetwork: print("Direct exit: no network interface")
    }
    let vpn = [snapshot.tunnel?.name, snapshot.interface, snapshot.address].compactMap { $0 }
    print("VPN: \(vpn.isEmpty ? "disconnected" : vpn.joined(separator: " · "))")
    exit(0)
}

// `--export-icons <folder>` saves every icon variant as PNG, on light and dark backgrounds.
if let flag = CommandLine.arguments.firstIndex(of: "--export-icons"), flag + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let variants: [(String, Status)] = [("on", .protected), ("vpn-down", .vpnDown),
                                        ("off", .exposed("en0")), ("offline", .offline)]
    let backgrounds: [(String, NSAppearance.Name, NSColor)] = [
        ("light", .aqua, NSColor(white: 0.93, alpha: 1)), ("dark", .darkAqua, NSColor(white: 0.17, alpha: 1)),
    ]
    for (name, status) in variants {
        for (theme, appearance, background) in backgrounds {
            let scale: CGFloat = 8
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(iconSize * scale), pixelsHigh: Int(iconSize * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let rect = NSRect(x: 0, y: 0, width: iconSize * scale, height: iconSize * scale)
                background.setFill()
                rect.fill()
                statusIcon(for: status).draw(in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name)-\(theme).png"))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
