import Cocoa
import ApplicationServices
import ImageIO
import Foundation

// MARK: - Quota State (5h + Weekly, 11s rotation, synced with C statusline)

struct QuotaWindow: Codable {
    var remaining: Double
    var reset_epoch: Int

    var usedPercent: Int {
        max(0, min(100, Int(((1.0 - max(0.0, min(1.0, remaining))) * 100.0).rounded())))
    }

    func countdown(isWeek: Bool) -> String {
        let secs = reset_epoch - Int(Date().timeIntervalSince1970)
        guard secs > 0 else { return "" }
        let mins = max(1, (secs + 30) / 60)
        let hours = mins / 60
        if isWeek || hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return hours > 0 ? "\(hours)h \(mins % 60)m" : "\(mins)m"
    }

    func barString(cells: Int = 10) -> String {
        let pct = usedPercent
        var filled = Int((Double(pct) / 100.0 * Double(cells)).rounded())
        if pct < 100 && filled >= cells { filled = cells - 1 }
        filled = max(0, min(cells, filled))
        return String(repeating: "━", count: filled) + String(repeating: "─", count: cells - filled)
    }
}

struct QuotaState: Codable {
    var five_hour: QuotaWindow?
    var weekly: QuotaWindow?
}

final class LocalhostTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class QuotaStore {
    private static let stateURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/agy-hud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("quota.json")
    }()
    private let session: URLSession
    private(set) var state = QuotaState()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.0
        cfg.timeoutIntervalForResource = 2.5
        self.session = URLSession(configuration: cfg, delegate: LocalhostTLSDelegate(), delegateQueue: nil)
        loadFromDisk()
    }

    func loadFromDisk() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let loaded = try? JSONDecoder().decode(QuotaState.self, from: data) {
            self.state = loaded
        }
    }

    private static func parseEpoch(_ iso: String) -> Int {
        guard !iso.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return Int(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso).map { Int($0.timeIntervalSince1970) } ?? 0
    }

    func refresh(completion: @escaping (QuotaState) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            self.loadFromDisk()
            let now = Int(Date().timeIntervalSince1970)
            var next = self.state
            if let w5 = next.five_hour, w5.reset_epoch > 0, w5.reset_epoch <= now { next.five_hour = nil }
            if let ww = next.weekly, ww.reset_epoch > 0, ww.reset_epoch <= now { next.weekly = nil }

            let daemonDir = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity/daemon")
            let fm = FileManager.default
            let hubs = ((try? fm.contentsOfDirectory(atPath: daemonDir)) ?? [])
                .filter { $0.hasPrefix("hub_") && $0.hasSuffix(".json") }
                .map { (daemonDir as NSString).appendingPathComponent($0) }
                .sorted {
                    let d1 = (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
                    let d2 = (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
                    return d1 > d2
                }

            for hubPath in hubs.prefix(2) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: hubPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = (json["httpsPort"] as? Int) ?? (json["port"] as? Int),
                      let csrf = json["csrfToken"] as? String, !csrf.isEmpty,
                      let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")
                else { continue }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                req.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
                req.httpBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.data(using: .utf8)

                let sem = DispatchSemaphore(value: 0)
                var gotAny = false
                self.session.dataTask(with: req) { respData, _, _ in
                    defer { sem.signal() }
                    guard let respData,
                          let root = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                          let us = root["userStatus"] as? [String: Any],
                          let ccd = us["cascadeModelConfigData"] as? [String: Any],
                          let configs = ccd["clientModelConfigs"] as? [[String: Any]]
                    else { return }

                    for cfg in configs {
                        guard let label = cfg["label"] as? String,
                              label.lowercased().contains("gemini"),
                              let qi = cfg["quotaInfo"] as? [String: Any],
                              let rt = qi["resetTime"] as? String, !rt.isEmpty
                        else { continue }
                        let rem = (qi["remainingFraction"] as? Double) ?? 0.0
                        let epoch = Self.parseEpoch(rt)
                        guard epoch > now else { continue }
                        let win = QuotaWindow(remaining: rem, reset_epoch: epoch)
                        if epoch - now <= 6 * 3600 { next.five_hour = win } else { next.weekly = win }
                        gotAny = true
                        break
                    }
                    if next.weekly == nil {
                        for cfg in configs {
                            guard let qi = cfg["quotaInfo"] as? [String: Any],
                                  let rt = qi["resetTime"] as? String, !rt.isEmpty
                            else { continue }
                            let rem = (qi["remainingFraction"] as? Double) ?? 0.0
                            let epoch = Self.parseEpoch(rt)
                            if epoch - now > 6 * 3600 {
                                next.weekly = QuotaWindow(remaining: rem, reset_epoch: epoch)
                                gotAny = true
                                break
                            }
                        }
                    }
                }.resume()
                _ = sem.wait(timeout: .now() + 2.5)
                if gotAny { break }
            }

            self.state = next
            if let encoded = try? JSONEncoder().encode(next) {
                try? encoded.write(to: Self.stateURL, options: .atomic)
            }
            completion(next)
        }
    }
}

// MARK: - Reusable Floating HUD Panel (Fast ImageIO Thumbnails + 8KB Text Cap)

final class PreviewHUD {
    private let panel: NSPanel
    private let backdrop: NSVisualEffectView
    private let header: NSTextField
    private let imageView: NSImageView
    private let textField: NSTextField

    private(set) var currentFile: String?
    private(set) var anchorRect: NSRect?
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.level = NSWindow.Level(rawValue: 25)
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true

        let hdr = NSTextField(labelWithString: "")
        hdr.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        hdr.textColor = NSColor.white.withAlphaComponent(0.65)
        hdr.lineBreakMode = .byTruncatingHead

        let iv = NSImageView(frame: .zero)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.isHidden = true

        let tf = NSTextField(frame: .zero)
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.textColor = .white
        tf.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tf.isHidden = true

        bg.addSubview(iv)
        bg.addSubview(tf)
        bg.addSubview(hdr)
        p.contentView = bg

        self.panel = p
        self.backdrop = bg
        self.header = hdr
        self.imageView = iv
        self.textField = tf
    }

    func show(file: String, anchorRect: NSRect?, near mouse: NSPoint) {
        if currentFile == file, panel.isVisible {
            self.anchorRect = anchorRect
            return
        }

        let ext = (file as NSString).pathExtension.lowercased()
        let screen = Self.screenContaining(mouse) ?? NSScreen.main ?? NSScreen.screens.first!
        let area = screen.visibleFrame
        let pad: CGFloat = 10
        let headerH: CGFloat = 18

        var cw: CGFloat = 0
        var ch: CGFloat = 0

        if Self.imageExts.contains(ext) {
            guard let (img, ptSize) = Self.loadThumbnail(file: file, scale: screen.backingScaleFactor) else { return }
            let fit = min(1.0, 800.0 / max(ptSize.width, ptSize.height), (area.width * 0.7) / ptSize.width, (area.height * 0.7) / ptSize.height)
            cw = max(120, (ptSize.width * fit).rounded())
            ch = max(80, (ptSize.height * fit).rounded())

            imageView.image = img
            imageView.frame = NSRect(x: pad, y: pad, width: cw, height: ch)
            imageView.isHidden = false
            textField.isHidden = true
        } else {
            guard let fh = FileHandle(forReadingAtPath: file) else { return }
            let chunk = fh.readData(ofLength: 8192)
            try? fh.close()
            guard let raw = String(data: chunk, encoding: .utf8) else { return }
            let lines = raw
                .components(separatedBy: .newlines)
                .prefix(42)
                .map { $0.count > 110 ? String($0.prefix(109)) + "…" : $0 }
            let longest = lines.reduce(24) { max($0, $1.count) }
            cw = min(CGFloat(longest) * 7.1 + 12, area.width * 0.58)
            ch = min(CGFloat(max(2, lines.count)) * 15.0 + 8, area.height * 0.68)

            textField.stringValue = lines.joined(separator: "\n")
            textField.frame = NSRect(x: pad, y: pad, width: cw, height: ch)
            textField.isHidden = false
            imageView.image = nil
            imageView.isHidden = true
        }

        let outerW = cw + pad * 2
        let outerH = ch + pad * 2 + headerH
        header.stringValue = (file as NSString).abbreviatingWithTildeInPath
        header.frame = NSRect(x: pad, y: pad + ch + 4, width: cw, height: 14)
        backdrop.frame = NSRect(x: 0, y: 0, width: outerW, height: outerH)

        let rect = Self.frameFor(size: NSSize(width: outerW, height: outerH), mouse: mouse, in: area)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        self.currentFile = file
        self.anchorRect = anchorRect
    }

    func hide() {
        guard panel.isVisible || currentFile != nil else { return }
        panel.orderOut(nil)
        imageView.image = nil
        currentFile = nil
        anchorRect = nil
    }

    private static func loadThumbnail(file: String, scale: CGFloat) -> (NSImage, NSSize)? {
        let url = URL(fileURLWithPath: file) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let maxPx = Int(800.0 * max(1.0, scale))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let s = max(1.0, scale)
        let ptSize = NSSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s)
        return (NSImage(cgImage: cg, size: ptSize), ptSize)
    }

    private static func screenContaining(_ pt: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(pt, $0.frame) }
    }

    private static func frameFor(size: NSSize, mouse: NSPoint, in area: NSRect) -> NSRect {
        let gap: CGFloat = 18
        let top = area.origin.y + area.height
        let right = area.origin.x + area.width
        var x = mouse.x + gap
        var y = mouse.y + gap
        if y + size.height > top { y = mouse.y - gap - size.height }
        if x + size.width > right { x = mouse.x - gap - size.width }
        x = max(area.origin.x, min(x, right - size.width))
        y = max(area.origin.y, min(y, top - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - Event-Driven Hover Watcher (0.0% idle CPU + AXBoundsForRange instant close)

final class HoverWatcher {
    private let hud = PreviewHUD()
    private let systemWide = AXUIElementCreateSystemWide()
    private var enabledElectronPids = Set<pid_t>()
    private var workspaces: [String] = []
    private var lastHoveredBundle: String?
    private var pendingWork: DispatchWorkItem?
    private var monitors: [Any] = []
    var isEnabled = true {
        didSet { if !isEnabled { hud.hide() } }
    }

    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty"
    ]
    private static let allowedExts = "png|jpe?g|gif|webp|heic|md|txt|log|json|tsv|csv|html|py|ts|tsx|js|jsx|swift|sh|yaml|yml|toml|css"
    private static let safeOpenExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "md", "txt", "log", "json", "tsv", "csv", "html"]
    private static let sensitiveMarkers = ["/.ssh/", "/.aws/", "/.gnupg/", "/.config/cloudflare", "credentials", ".env", ".pem", ".key", "id_rsa", "id_ed25519"]
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?:file://)?(?:~/|\.{0,2}/)?[\w.@+\-/~]+\.(?:"# + allowedExts + #")(?::\d+(?::\d+)?)?(?:#L\d+(?:-L\d+)?)?"#,
        options: [.caseInsensitive]
    )

    init() {
        var dirs = [NSHomeDirectory()]
        let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/antigravity-cli/settings.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let trusted = json["trustedWorkspaces"] as? [String] {
            for d in trusted where !dirs.contains(d) { dirs.append(d) }
        }
        self.workspaces = dirs
    }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.onMouseMoved()
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            guard let self, let file = self.hud.currentFile else { return }
            let bundle = self.lastHoveredBundle ?? ""
            let inAnchor = self.hud.anchorRect.map { NSMouseInRect(NSEvent.mouseLocation, $0.insetBy(dx: -3, dy: -3), false) } ?? true
            self.hud.hide()
            if Self.terminalBundles.contains(bundle), inAnchor {
                let ext = (file as NSString).pathExtension.lowercased()
                if Self.safeOpenExts.contains(ext) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file))
                }
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel], handler: { [weak self] _ in
            self?.pendingWork?.cancel()
            self?.hud.hide()
        }) { monitors.append(m) }
    }

    private func onMouseMoved() {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        // Fast path: if mouse is still inside the hovered filename's exact rect, do zero AX work
        if let rect = hud.anchorRect {
            if NSMouseInRect(mouse, rect.insetBy(dx: -3, dy: -3), false) { return }
            hud.hide()
        }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.inspectNow() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    private func inspectNow() {
        guard isEnabled, AXIsProcessTrusted(),
              let primaryH = NSScreen.screens.first?.frame.height else {
            hud.hide()
            return
        }
        let mouse = NSEvent.mouseLocation
        let axX = Float(mouse.x)
        let axY = Float(primaryH - mouse.y)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, axX, axY, &hit) == .success, let el = hit else {
            hud.hide()
            return
        }

        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              (Self.terminalBundles.contains(bundleId) || bundleId == "com.google.antigravity")
        else {
            hud.hide()
            return
        }
        lastHoveredBundle = bundleId

        if bundleId == "com.google.antigravity" && !enabledElectronPids.contains(pid) {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledElectronPids.insert(pid)
        }

        if Self.terminalBundles.contains(bundleId) {
            if let (file, rect) = fileFromTerminal(el, axPoint: CGPoint(x: CGFloat(axX), y: CGFloat(axY)), primaryH: primaryH) {
                hud.show(file: file, anchorRect: rect, near: mouse)
            } else {
                hud.hide()
            }
        } else {
            if let file = fileFromElectron(el) {
                hud.show(file: file, anchorRect: nil, near: mouse)
            } else {
                hud.hide()
            }
        }
    }

    private func windowTitle(of el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        for _ in 0..<6 {
            guard let node = cur else { break }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &titleRef) == .success {
                    return titleRef as? String
                }
                return nil
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success, let p = parentRef {
                cur = (p as! AXUIElement)
            } else { break }
        }
        return nil
    }

    private func fileFromTerminal(_ el: AXUIElement, axPoint: CGPoint, primaryH: CGFloat) -> (String, NSRect?)? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        guard (roleRef as? String) == (kAXTextAreaRole as String) else { return nil }

        var pt = axPoint
        guard let ptVal = AXValueCreate(.cgPoint, &pt) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, ptVal, &rangeRef) == .success,
              let rv = rangeRef else { return nil }
        var charRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rv as! AXValue, .cfRange, &charRange) else { return nil }

        var lineNumRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: charRange.location), &lineNumRef) == .success,
              let lineNum = lineNumRef as? NSNumber else { return nil }

        var lineRangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForLineParameterizedAttribute as CFString, lineNum, &lineRangeRef) == .success,
              let lrv = lineRangeRef else { return nil }
        var lineRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(lrv as! AXValue, .cfRange, &lineRange), lineRange.length > 0 else { return nil }

        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, lrv, &strRef) == .success,
              let lineText = strRef as? String else { return nil }

        let hintDir = windowTitle(of: el)?.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces)
        let offset = charRange.location - lineRange.location
        let ns = lineText as NSString
        for m in Self.pathRegex.matches(in: lineText, range: NSRange(location: 0, length: ns.length)) {
            if offset < m.range.location - 1 || offset > m.range.location + m.range.length + 1 { continue }
            if let file = resolveExistingPath(ns.substring(with: m.range), hintDir: hintDir) {
                var tokRange = CFRange(location: lineRange.location + m.range.location, length: m.range.length)
                var cocoaRect: NSRect?
                if let trv = AXValueCreate(.cfRange, &tokRange) {
                    var bRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, trv, &bRef) == .success,
                       let bv = bRef {
                        var cg = CGRect.zero
                        if AXValueGetValue(bv as! AXValue, .cgRect, &cg) {
                            cocoaRect = NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
                        }
                    }
                }
                return (file, cocoaRect)
            }
        }
        return nil
    }

    private func fileFromElectron(_ el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        for _ in 0..<4 {
            guard let node = cur else { break }
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &urlRef) == .success,
               let url = urlRef as? URL, url.isFileURL, fileExists(url.path) {
                return url.path
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success, let p = parentRef {
                cur = (p as! AXUIElement)
            } else { break }
        }
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
               let text = ref as? String, !text.isEmpty, text.count < 4000 {
                let ns = text as NSString
                for m in Self.pathRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    if let file = resolveExistingPath(ns.substring(with: m.range), hintDir: nil) { return file }
                }
            }
        }
        return nil
    }

    private func resolveExistingPath(_ raw: String, hintDir: String?) -> String? {
        var s = raw
        if s.hasPrefix("file://") { s.removeFirst("file://".count) }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        if let c = s.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) { s.removeSubrange(c) }
        if let d = s.removingPercentEncoding { s = d }

        if s.hasPrefix("~/") {
            let full = (s as NSString).expandingTildeInPath
            return fileExists(full) ? full : nil
        }
        if s.hasPrefix("/") { return fileExists(s) ? s : nil }
        let clean = s.hasPrefix("./") ? String(s.dropFirst(2)) : s
        if let hint = hintDir, !hint.isEmpty {
            let cand = ((NSHomeDirectory() as NSString).appendingPathComponent(hint) as NSString).appendingPathComponent(clean)
            if fileExists(cand) { return cand }
        }
        for ws in workspaces {
            let cand = (ws as NSString).appendingPathComponent(clean)
            if fileExists(cand) { return cand }
        }
        return nil
    }

    private func fileExists(_ path: String) -> Bool {
        let low = path.lowercased()
        for m in Self.sensitiveMarkers where low.contains(m) { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
}

// MARK: - App Delegate (11s rotating Menu Bar Quota + Event-Driven Hover)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let quotaStore = QuotaStore()
    private let hoverWatcher = HoverWatcher()
    private var showWeekly = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        statusItem.button?.title = "AGY"
        rebuildMenu()

        hoverWatcher.start()
        refreshQuota()

        Timer.scheduledTimer(withTimeInterval: 11.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.quotaStore.loadFromDisk()
            self.showWeekly.toggle()
            self.updateTitle()
        }
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
    }

    @objc private func refreshQuota() {
        quotaStore.refresh { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTitle()
                self?.rebuildMenu()
            }
        }
    }

    private func updateTitle() {
        let st = quotaStore.state
        let pickWeek = (st.five_hour != nil && st.weekly != nil) ? showWeekly : (st.weekly != nil)
        if pickWeek, let ww = st.weekly {
            let cd = ww.countdown(isWeek: true)
            statusItem.button?.title = cd.isEmpty ? "wk \(ww.usedPercent)%" : "wk \(ww.usedPercent)% · \(cd)"
        } else if let w5 = st.five_hour {
            let cd = w5.countdown(isWeek: false)
            statusItem.button?.title = cd.isEmpty ? "5h \(w5.usedPercent)%" : "5h \(w5.usedPercent)% · \(cd)"
        } else {
            statusItem.button?.title = "AGY"
        }
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        hoverWatcher.isEnabled.toggle()
        rebuildMenu()
    }

    @objc private func openAccessibilityPrefs() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func rebuildMenu() {
        let menu = NSMenu()
        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(
                title: "⚠ Activa Antigravity en Accesibilidad (click aquí)",
                action: #selector(openAccessibilityPrefs),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        let st = quotaStore.state
        if let w5 = st.five_hour {
            let cd = w5.countdown(isWeek: false)
            addMonoItem(menu, "5h    \(w5.barString())  \(w5.usedPercent)%" + (cd.isEmpty ? "" : " ↻ \(cd)"))
        }
        if let ww = st.weekly {
            let cd = ww.countdown(isWeek: true)
            addMonoItem(menu, "week  \(ww.barString())  \(ww.usedPercent)%" + (cd.isEmpty ? "" : " ↻ \(cd)"))
        }
        if st.five_hour == nil && st.weekly == nil {
            let item = NSMenuItem(title: "Esperando cuota de AGY…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let h = NSMenuItem(title: hoverWatcher.isEnabled ? "Hover Preview: On ✓" : "Hover Preview: Off", action: #selector(toggleHover(_:)), keyEquivalent: "")
        h.target = self
        menu.addItem(h)
        let r = NSMenuItem(title: "Refrescar cuota", action: #selector(refreshQuota), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Salir", action: #selector(quitApp), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
    }

    private func addMonoItem(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )
        menu.addItem(item)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
