import AppKit
import ApplicationServices
import Foundation

enum StageBarEdge: String, CaseIterable, Identifiable, Sendable {
    static let preferenceKey = "workstation.stageBarEdge"

    case top, bottom, left, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "顶部"
        case .bottom: "底部"
        case .left: "左侧"
        case .right: "右侧"
        }
    }

    var symbolName: String {
        switch self {
        case .top: "dock.arrow.up.rectangle"
        case .bottom: "dock.arrow.down.rectangle"
        case .left: "sidebar.leading"
        case .right: "sidebar.trailing"
        }
    }

    var isVertical: Bool {
        self == .left || self == .right
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .top
    }
}

enum StageLayout: Equatable, Hashable, Sendable {
    case single(Client)
    case splitTwo(Client, Client, CGFloat)
    case splitThree(Client, Client, Client)

    var label: String {
        switch self {
        case .single(let c): c.label
        case .splitTwo(let l, let r, _): "\(l.shortLabel) | \(r.shortLabel)"
        case .splitThree(let p, let tr, let br): "\(p.shortLabel) | \(tr.shortLabel)+\(br.shortLabel)"
        }
    }

    var involvedClients: [Client] {
        switch self {
        case .single(let c): [c]
        case .splitTwo(let l, let r, _): [l, r]
        case .splitThree(let p, let tr, let br): [p, tr, br]
        }
    }
}

struct StageBarMetrics: Equatable, Sendable {
    static let verticalWidthKey = "workstation.dock.verticalWidth"
    static let verticalLengthPercentKey = "workstation.dock.verticalLengthPercent"
    static let horizontalHeightKey = "workstation.dock.horizontalHeight"
    static let horizontalLengthPercentKey = "workstation.dock.horizontalLengthPercent"

    static let verticalWidthRange: ClosedRange<CGFloat> = 56...180
    static let verticalLengthPercentRange: ClosedRange<CGFloat> = 45...100
    static let horizontalHeightRange: ClosedRange<CGFloat> = 40...64
    static let horizontalLengthPercentRange: ClosedRange<CGFloat> = 55...100

    let horizontalHeight: CGFloat
    let horizontalWidth: CGFloat
    let verticalWidth: CGFloat
    let verticalHeight: CGFloat
    let uiScale: CGFloat

    static func savedVerticalWidth(for screen: NSScreen?, defaults: UserDefaults = .standard) -> CGFloat {
        let saved = defaults.double(forKey: verticalWidthKey)
        if saved >= verticalWidthRange.lowerBound {
            return min(verticalWidthRange.upperBound, CGFloat(saved))
        }
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return min(96, max(72, floor(visible.width * 0.048)))
    }

    static func savedVerticalLengthPercent(defaults: UserDefaults = .standard) -> CGFloat {
        let saved = defaults.double(forKey: verticalLengthPercentKey)
        if saved >= verticalLengthPercentRange.lowerBound {
            return min(verticalLengthPercentRange.upperBound, CGFloat(saved))
        }
        return 76
    }

    static func savedHorizontalHeight(for screen: NSScreen?, defaults: UserDefaults = .standard) -> CGFloat {
        let saved = defaults.double(forKey: horizontalHeightKey)
        if saved >= horizontalHeightRange.lowerBound {
            return min(horizontalHeightRange.upperBound, CGFloat(saved))
        }
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return min(52, max(44, floor(visible.height * 0.046)))
    }

    static func savedHorizontalLengthPercent(defaults: UserDefaults = .standard) -> CGFloat {
        let saved = defaults.double(forKey: horizontalLengthPercentKey)
        if saved >= horizontalLengthPercentRange.lowerBound {
            return min(horizontalLengthPercentRange.upperBound, CGFloat(saved))
        }
        return 98
    }

    static func forScreen(_ screen: NSScreen?, defaults: UserDefaults = .standard) -> StageBarMetrics {
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let m: CGFloat = 6
        let maxW = max(720, visible.width - m * 2)
        let maxH = max(420, visible.height - m * 2)

        let vWidth = savedVerticalWidth(for: screen, defaults: defaults)
        let vPct = savedVerticalLengthPercent(defaults: defaults) / 100.0
        let vHeight = min(maxH, max(400, floor(maxH * vPct)))

        let hHeight = savedHorizontalHeight(for: screen, defaults: defaults)
        let hPct = savedHorizontalLengthPercent(defaults: defaults) / 100.0
        let hWidth = min(maxW, max(720, floor(maxW * hPct)))

        let uiScale = min(1.35, max(0.88, vWidth / 72.0))
        return StageBarMetrics(
            horizontalHeight: hHeight,
            horizontalWidth: hWidth,
            verticalWidth: vWidth,
            verticalHeight: vHeight,
            uiScale: uiScale
        )
    }
}

@MainActor
final class WindowStageManager: ObservableObject {
    static let barMargin: CGFloat = 6
    static let windowGap: CGFloat = 6

    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published var activeLayout: StageLayout?
    @Published var runningClients: Set<Client> = []
    @Published var barMetrics: StageBarMetrics = StageBarMetrics.forScreen(NSScreen.main)

    private var trustPollTask: Task<Void, Never>?

    func updateMetrics(for screen: NSScreen? = nil) {
        let updated = StageBarMetrics.forScreen(screen ?? NSScreen.main ?? NSScreen.screens.first)
        if updated != barMetrics {
            barMetrics = updated
        }
    }

    func startMonitoringTrust(onBecomeTrusted: @escaping @MainActor () -> Void) {
        refreshStatus()
        guard !isAccessibilityTrusted else { return }
        trustPollTask?.cancel()
        trustPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                guard let self else { break }
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted != self.isAccessibilityTrusted {
                    self.isAccessibilityTrusted = nowTrusted
                    if nowTrusted {
                        onBecomeTrusted()
                        break
                    }
                }
            }
        }
    }

    func refreshStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        var running = Set<Client>()
        for client in Client.allCases {
            if runningApplication(for: client) != nil {
                running.insert(client)
            }
        }
        runningClients = running
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshStatus()
    }

    func stageBarFrame(edge: StageBarEdge, on screen: NSScreen? = nil) -> CGRect {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let metrics = StageBarMetrics.forScreen(targetScreen)
        barMetrics = metrics
        guard let visible = targetScreen?.visibleFrame else {
            return CGRect(x: 8, y: 800, width: 1200, height: metrics.horizontalHeight)
        }
        let m = Self.barMargin
        switch edge {
        case .top:
            return CGRect(
                x: floor(visible.midX - metrics.horizontalWidth / 2),
                y: visible.maxY - metrics.horizontalHeight - m,
                width: metrics.horizontalWidth,
                height: metrics.horizontalHeight
            )
        case .bottom:
            return CGRect(
                x: floor(visible.midX - metrics.horizontalWidth / 2),
                y: visible.minY + m,
                width: metrics.horizontalWidth,
                height: metrics.horizontalHeight
            )
        case .left:
            return CGRect(
                x: visible.minX + m,
                y: floor(visible.midY - metrics.verticalHeight / 2),
                width: metrics.verticalWidth,
                height: metrics.verticalHeight
            )
        case .right:
            return CGRect(
                x: visible.maxX - metrics.verticalWidth - m,
                y: floor(visible.midY - metrics.verticalHeight / 2),
                width: metrics.verticalWidth,
                height: metrics.verticalHeight
            )
        }
    }

    func saveResizedBarFrame(_ frame: CGRect, edge: StageBarEdge, on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = targetScreen?.visibleFrame else { return }
        let m = Self.barMargin
        let maxW = max(720, visible.width - m * 2)
        let maxH = max(420, visible.height - m * 2)
        let defaults = UserDefaults.standard

        if edge.isVertical {
            let clampedW = min(StageBarMetrics.verticalWidthRange.upperBound, max(StageBarMetrics.verticalWidthRange.lowerBound, round(frame.width)))
            let pct = min(StageBarMetrics.verticalLengthPercentRange.upperBound, max(StageBarMetrics.verticalLengthPercentRange.lowerBound, round((frame.height / maxH) * 100)))
            defaults.set(Double(clampedW), forKey: StageBarMetrics.verticalWidthKey)
            defaults.set(Double(pct), forKey: StageBarMetrics.verticalLengthPercentKey)
        } else {
            let clampedH = min(StageBarMetrics.horizontalHeightRange.upperBound, max(StageBarMetrics.horizontalHeightRange.lowerBound, round(frame.height)))
            let pct = min(StageBarMetrics.horizontalLengthPercentRange.upperBound, max(StageBarMetrics.horizontalLengthPercentRange.lowerBound, round((frame.width / maxW) * 100)))
            defaults.set(Double(clampedH), forKey: StageBarMetrics.horizontalHeightKey)
            defaults.set(Double(pct), forKey: StageBarMetrics.horizontalLengthPercentKey)
        }
        barMetrics = StageBarMetrics.forScreen(targetScreen)
    }

    func resetBarDimensions(on screen: NSScreen? = nil) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: StageBarMetrics.verticalWidthKey)
        defaults.removeObject(forKey: StageBarMetrics.verticalLengthPercentKey)
        defaults.removeObject(forKey: StageBarMetrics.horizontalHeightKey)
        defaults.removeObject(forKey: StageBarMetrics.horizontalLengthPercentKey)
        barMetrics = StageBarMetrics.forScreen(screen ?? NSScreen.main ?? NSScreen.screens.first)
    }

    func stageCanvasFrame(edge: StageBarEdge = .top, on screen: NSScreen? = nil, reserveBar: Bool = true) -> CGRect {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let metrics = StageBarMetrics.forScreen(targetScreen)
        guard let visible = targetScreen?.visibleFrame else {
            return CGRect(x: 0, y: 0, width: 1440, height: 840)
        }
        let m = Self.barMargin
        var leftInset = m
        var rightInset = m
        var topInset = m
        var bottomInset = m

        if reserveBar {
            switch edge {
            case .top: topInset = metrics.horizontalHeight + m * 2
            case .bottom: bottomInset = metrics.horizontalHeight + m * 2
            case .left: leftInset = metrics.verticalWidth + m * 2
            case .right: rightInset = metrics.verticalWidth + m * 2
            }
        }

        return CGRect(
            x: visible.minX + leftInset,
            y: visible.minY + bottomInset,
            width: max(640, visible.width - leftInset - rightInset),
            height: max(420, visible.height - topInset - bottomInset)
        )
    }

    func detectSnapEdge(for panelFrame: CGRect, on screen: NSScreen? = nil, currentEdge: StageBarEdge) -> StageBarEdge? {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = targetScreen?.visibleFrame else { return nil }
        let threshold: CGFloat = 64

        let distLeft = abs(panelFrame.minX - visible.minX)
        let distRight = abs(visible.maxX - panelFrame.maxX)
        let distTop = abs(visible.maxY - panelFrame.maxY)
        let distBottom = abs(panelFrame.minY - visible.minY)

        let candidates: [(StageBarEdge, CGFloat)] = [
            (.left, distLeft),
            (.right, distRight),
            (.top, distTop),
            (.bottom, distBottom),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else {
            return nil
        }
        return nearest.0 == currentEdge ? nil : nearest.0
    }

    func focusSingle(
        _ client: Client,
        edge: StageBarEdge,
        on screen: NSScreen? = nil,
        reserveBar: Bool = true,
        afterPlace: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor (String, Bool) -> Void
    ) {
        let layout = StageLayout.single(client)
        let canvas = stageCanvasFrame(edge: edge, on: screen, reserveBar: reserveBar)
        applyLayout(layout, slots: [(client, canvas)], afterPlace: afterPlace, completion: completion)
    }

    func applySplitTwo(
        _ left: Client,
        _ right: Client,
        ratio: CGFloat = 0.50,
        edge: StageBarEdge,
        on screen: NSScreen? = nil,
        reserveBar: Bool = true,
        afterPlace: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor (String, Bool) -> Void
    ) {
        let layout = StageLayout.splitTwo(left, right, ratio)
        let canvas = stageCanvasFrame(edge: edge, on: screen, reserveBar: reserveBar)
        let gap = Self.windowGap
        let leftWidth = floor((canvas.width - gap) * ratio)
        let rightWidth = canvas.width - gap - leftWidth
        let leftRect = CGRect(x: canvas.minX, y: canvas.minY, width: leftWidth, height: canvas.height)
        let rightRect = CGRect(x: canvas.minX + leftWidth + gap, y: canvas.minY, width: rightWidth, height: canvas.height)
        applyLayout(layout, slots: [(left, leftRect), (right, rightRect)], afterPlace: afterPlace, completion: completion)
    }

    func applySplitThree(
        _ primary: Client,
        _ topRight: Client,
        _ bottomRight: Client,
        edge: StageBarEdge,
        on screen: NSScreen? = nil,
        reserveBar: Bool = true,
        afterPlace: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor (String, Bool) -> Void
    ) {
        let layout = StageLayout.splitThree(primary, topRight, bottomRight)
        let canvas = stageCanvasFrame(edge: edge, on: screen, reserveBar: reserveBar)
        let gap = Self.windowGap
        let leftWidth = floor((canvas.width - gap) * 0.52)
        let rightWidth = canvas.width - gap - leftWidth
        let halfHeight = floor((canvas.height - gap) * 0.5)
        let bottomHeight = canvas.height - gap - halfHeight

        let leftRect = CGRect(x: canvas.minX, y: canvas.minY, width: leftWidth, height: canvas.height)
        let topRightRect = CGRect(x: canvas.minX + leftWidth + gap, y: canvas.minY + bottomHeight + gap, width: rightWidth, height: halfHeight)
        let bottomRightRect = CGRect(x: canvas.minX + leftWidth + gap, y: canvas.minY, width: rightWidth, height: bottomHeight)

        applyLayout(layout, slots: [(primary, leftRect), (topRight, topRightRect), (bottomRight, bottomRightRect)], afterPlace: afterPlace, completion: completion)
    }

    private func applyLayout(
        _ layout: StageLayout,
        slots: [(Client, CGRect)],
        afterPlace: (@MainActor () -> Void)?,
        completion: @escaping @MainActor (String, Bool) -> Void
    ) {
        refreshStatus()
        activeLayout = layout

        Task { @MainActor in
            var missing: [String] = []
            var placedCount = 0
            let trusted = AXIsProcessTrusted()
            isAccessibilityTrusted = trusted

            // Place secondary windows first, primary window last so primary ends up focused
            let orderedSlots = Array(slots.reversed())
            var movedWindows: [(pid: pid_t, window: AXUIElement, rect: CGRect)] = []

            for (client, appKitRect) in orderedSlots {
                if let existing = runningApplication(for: client) {
                    // SILKY FAST PATH: For already-running apps, position/size BEFORE raising to front
                    // (and skip AX resize entirely if already within 5pt of target rect -> zero flicker!).
                    if trusted, let window = primaryStandardWindow(pid: existing.processIdentifier) {
                        let alreadyAligned = isWindowAligned(window, to: appKitRect, tolerance: 5)
                        if !alreadyAligned {
                            placeAXWindow(pid: existing.processIdentifier, window: window, appKitRect: appKitRect)
                            movedWindows.append((existing.processIdentifier, window, appKitRect))
                        }
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        placedCount += 1
                    }
                    _ = await launchAndActivate(client: client)
                    if trusted, placedCount == 0 || primaryStandardWindow(pid: existing.processIdentifier) == nil {
                        if let window = await waitForStandardWindow(pid: existing.processIdentifier) {
                            if !isWindowAligned(window, to: appKitRect, tolerance: 5) {
                                placeAXWindow(pid: existing.processIdentifier, window: window, appKitRect: appKitRect)
                                movedWindows.append((existing.processIdentifier, window, appKitRect))
                            }
                            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                            placedCount += 1
                        }
                    }
                } else {
                    guard let app = await launchAndActivate(client: client) else {
                        missing.append(client.label)
                        continue
                    }
                    if trusted, let window = await waitForStandardWindow(pid: app.processIdentifier) {
                        placeAXWindow(pid: app.processIdentifier, window: window, appKitRect: appKitRect)
                        movedWindows.append((app.processIdentifier, window, appKitRect))
                        placedCount += 1
                    }
                }
            }

            // Only run stabilization pass on windows that actually moved AND drifted > 6pt (eliminates double-jump flicker!)
            if trusted && !movedWindows.isEmpty {
                try? await Task.sleep(for: .milliseconds(110))
                for item in movedWindows {
                    if !isWindowAligned(item.window, to: item.rect, tolerance: 6) {
                        placeAXWindow(pid: item.pid, window: item.window, appKitRect: item.rect)
                    }
                    AXUIElementPerformAction(item.window, kAXRaiseAction as CFString)
                }
            }

            afterPlace?()
            refreshStatus()

            if !missing.isEmpty {
                completion("未找到应用：\(missing.joined(separator: "、"))。请在设置中绑定路径。", true)
            } else if !trusted {
                let msg = slots.count > 1
                    ? "尚未授权分屏权限：请在「设备控制和数据访问」先用 − 移除旧条目，再拖入 ~/Applications/无语工作站.app。"
                    : "已切换到 \(layout.label)（授予分屏权限后可自动贴合画布）。"
                completion(msg, slots.count > 1)
            } else if placedCount >= slots.count {
                completion("已切换：\(layout.label)。", false)
            } else if placedCount > 0 {
                completion("已部分排布 \(layout.label)（部分应用仍在启动中，稍后再点一次即可对齐）。", false)
            } else {
                completion("已激活 \(layout.label)，未检测到可调整的标准窗口。", true)
            }
        }
    }

    func runningApplication(for client: Client) -> NSRunningApplication? {
        let targetURL = client.resolvedAppURL()?.standardizedFileURL
        let targetBundleID = client.resolvedBundleID()
        if let targetURL {
            for app in NSWorkspace.shared.runningApplications {
                if app.bundleURL?.standardizedFileURL == targetURL { return app }
            }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first
    }

    private func launchAndActivate(client: Client) async -> NSRunningApplication? {
        guard let url = client.resolvedAppURL() else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.hidesOthers = false
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            app.unhide()
            return app
        } catch {
            if let existing = runningApplication(for: client) {
                existing.unhide()
                existing.activate()
                return existing
            }
            return nil
        }
    }

    private func waitForStandardWindow(pid: pid_t) async -> AXUIElement? {
        for _ in 0..<25 {
            if let window = primaryStandardWindow(pid: pid) { return window }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func primaryStandardWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let win = unsafeDowncast(focused, to: AXUIElement.self)
            if isStandardWindow(win) { return win }
        }

        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let main = mainRef,
           CFGetTypeID(main) == AXUIElementGetTypeID() {
            let win = unsafeDowncast(main, to: AXUIElement.self)
            if isStandardWindow(win) { return win }
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let list = windowsRef as? [AXUIElement] {
            return list.first(where: { isStandardWindow($0) }) ?? list.first
        }
        return nil
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String {
            return subrole == (kAXStandardWindowSubrole as String)
        }
        return true
    }

    private func isWindowAligned(_ window: AXUIElement, to appKitRect: CGRect, tolerance: CGFloat) -> Bool {
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let minimized = minRef as? Bool, minimized {
            return false
        }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else {
            return false
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &pos)
        AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        let targetX = appKitRect.origin.x
        let targetY = primaryHeight - appKitRect.maxY
        return abs(pos.x - targetX) <= tolerance
            && abs(pos.y - targetY) <= tolerance
            && abs(size.width - appKitRect.width) <= tolerance
            && abs(size.height - appKitRect.height) <= tolerance
    }

    private func placeAXWindow(pid: pid_t, window: AXUIElement, appKitRect: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)

        let enhancedAttr = "AXEnhancedUserInterface" as CFString
        var wasEnhanced = false
        var enhancedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, enhancedAttr, &enhancedRef) == .success,
           let flag = enhancedRef as? Bool, flag {
            wasEnhanced = true
            AXUIElementSetAttributeValue(appElement, enhancedAttr, kCFBooleanFalse)
        }
        defer {
            if wasEnhanced {
                AXUIElementSetAttributeValue(appElement, enhancedAttr, kCFBooleanTrue)
            }
        }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let minimized = minRef as? Bool, minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        let fullScreenAttr = "AXFullScreen" as CFString
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, fullScreenAttr, &fsRef) == .success,
           let isFS = fsRef as? Bool, isFS {
            AXUIElementSetAttributeValue(window, fullScreenAttr, kCFBooleanFalse)
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        var pos = CGPoint(x: appKitRect.origin.x, y: primaryHeight - appKitRect.maxY)
        var size = CGSize(width: appKitRect.width, height: appKitRect.height)

        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
    }
}
