import AppKit
import QuartzCore
import SwiftUI

enum WorkstationSheet: Identifiable {
    case compose(Composer)
    case settings

    var id: String {
        switch self {
        case .compose(let draft): "compose-\(draft.id)"
        case .settings: "settings"
        }
    }
}

enum StatusScope: String, CaseIterable, Identifiable {
    case active, all, archived
    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: "进行中"
        case .all: "全部"
        case .archived: "归档"
        }
    }
}

@MainActor
final class WorkstationModel: ObservableObject {
    let store: BridgeStore
    let stageManager = WindowStageManager()
    let themeStore = WorkstationThemeStore()
    let codexRunner = CodexRunner()

    @Published var threads: [ConversationThread] = []
    @Published var selectedThreadID: UUID?
    @Published var clientFilter: Client?
    @Published var statusScope: StatusScope = .active
    @Published var searchQuery = ""
    @Published var feedback: (message: String, isError: Bool)?
    @Published var stageBanner: String?
    @Published var showRawMarkdown = false
    @Published var sheet: WorkstationSheet?
    @Published var isStageBarVisible = true
    @Published var isMainWindowVisible = true
    @Published var stageBarEdge: StageBarEdge = StageBarEdge.saved() {
        didSet {
            UserDefaults.standard.set(stageBarEdge.rawValue, forKey: StageBarEdge.preferenceKey)
            onStageBarEdgeChanged?(stageBarEdge)
        }
    }

    var onToggleMainWindow: (() -> Void)?
    var onShowMainWindow: (() -> Void)?
    var onHideMainWindow: (() -> Void)?
    var onToggleStageBar: (() -> Void)?
    var onRaiseStageBar: (() -> Void)?
    var onStageBarEdgeChanged: ((StageBarEdge) -> Void)?
    var onDockGeometryChanged: (() -> Void)?
    var onToggleDockSizeHud: (() -> Void)?
    var onUpdateBadge: ((Int) -> Void)?
    var activeScreenProvider: (() -> NSScreen?)?

    private var activeScreen: NSScreen? { activeScreenProvider?() ?? NSScreen.main }

    private var watcher: MailboxWatcher?
    private var knownPacketIDs: Set<UUID> = []
    private var bannerClearTask: Task<Void, Never>?

    init(store: BridgeStore) {
        self.store = store
    }

    func start() {
        refresh(initial: true)
        let watcher = MailboxWatcher(directory: store.directory) { [weak self] in
            self?.refresh(fromWatcher: true)
        }
        watcher.start()
        self.watcher = watcher
        stageManager.startMonitoringTrust { [weak self] in
            self?.showBanner("分屏权限已生效，浏览器式切换与一键分屏已就绪！")
            self?.report("分屏权限已生效，现在可以直接使用一键分屏。")
        }
    }

    var filteredThreads: [ConversationThread] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return threads.filter { thread in
            switch statusScope {
            case .active: if !thread.isActive { return false }
            case .archived: if thread.status != .archived { return false }
            case .all: break
            }
            if let clientFilter {
                let matches = thread.waitingFor == clientFilter
                    || thread.latest.to == clientFilter
                    || thread.participants.contains(clientFilter)
                if !matches { return false }
            }
            if !needle.isEmpty {
                let hit = thread.subject.lowercased().contains(needle)
                    || (thread.workspacePath?.lowercased().contains(needle) ?? false)
                    || thread.messages.contains { $0.body.lowercased().contains(needle) }
                if !hit { return false }
            }
            return true
        }
    }

    var selectedThread: ConversationThread? {
        filteredThreads.first { $0.id == selectedThreadID }
            ?? threads.first { $0.id == selectedThreadID }
    }

    var activePendingThread: ConversationThread? {
        threads.first { $0.isActive }
    }

    var totalPendingCount: Int {
        threads.count { $0.isActive }
    }

    func waitingCount(for client: Client) -> Int {
        threads.count { $0.isActive && $0.waitingFor == client }
    }

    func refresh(initial: Bool = false, fromWatcher: Bool = false, reportSuccess: Bool = false) {
        do {
            let loaded = try store.threads(includeArchived: true)
            let newIDs = Set(loaded.flatMap { $0.messages.map(\.id) })

            if fromWatcher && !initial {
                let added = newIDs.subtracting(knownPacketIDs)
                if !added.isEmpty,
                   let newest = loaded.flatMap(\.messages)
                    .filter({ added.contains($0.id) })
                    .sorted(by: { $0.createdAt > $1.createdAt })
                    .first {
                    showBanner("收到 \(newest.from.label) → \(newest.to.label)：\(newest.subject)")
                    NSSound(named: .init("Glass"))?.play()
                }
            }

            knownPacketIDs = newIDs
            threads = loaded
            stageManager.refreshStatus()
            onUpdateBadge?(totalPendingCount)

            if selectedThread == nil {
                selectedThreadID = filteredThreads.first?.id
            }
            if reportSuccess {
                report("黑板已刷新（共 \(loaded.count) 条线程）。")
            }
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    func saveCompose(_ payload: ComposePayload, draft: Composer) throws {
        let saved: Packet
        switch draft {
        case .workflow(let tpl):
            let steps = payload.template.makeSteps()
            saved = try store.send(
                from: payload.from, to: payload.to, subject: payload.subject, body: payload.body,
                workspacePath: payload.workspacePath,
                attachedFiles: payload.attachedFiles.isEmpty ? nil : payload.attachedFiles,
                gitDiffSummary: payload.gitDiffSummary,
                templateId: tpl == .custom ? nil : tpl.rawValue,
                workflowSteps: steps.isEmpty ? nil : steps
            )
        case .reply(let thread):
            saved = try store.reply(
                to: thread.latest.id, from: payload.from, body: payload.body,
                nextTo: payload.nextTo, markDone: payload.markDone,
                workspacePath: payload.workspacePath,
                attachedFiles: payload.attachedFiles.isEmpty ? nil : payload.attachedFiles
            )
        }

        sheet = nil
        refresh()
        selectedThreadID = saved.effectiveThreadId
        report("已保存到无语黑板，当前等待 \(saved.to.label)。")

        if payload.launchSplitAfterSave, let thread = threads.first(where: { $0.id == saved.effectiveThreadId }) {
            dispatchThread(thread, splitWithSender: true)
        }
    }

    func quickCaptureClipboardReply(for thread: ConversationThread) {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report("剪贴板为空，请先在客户端复制回复后再点一键存回执。", isError: true)
            showBanner("剪贴板没有可导入的回复文本")
            return
        }
        let responder = thread.waitingFor ?? thread.latest.to
        do {
            let reply = try store.reply(to: thread.latest.id, from: responder, body: pasted)
            refresh()
            selectedThreadID = reply.effectiveThreadId
            let nextClient = threads.first(where: { $0.id == reply.effectiveThreadId })?.waitingFor
            if let nextClient, nextClient.supportsLocalMCP {
                _ = copy(makeShortMCPPrompt(subject: thread.subject, target: nextClient))
                report("已从剪贴板存入 \(responder.label) 回执，并已复制 \(nextClient.label) 接力指令。")
                showBanner("已存 \(responder.label) 回执 → 接力指令已入剪贴板")
            } else {
                report("已从剪贴板存入 \(responder.label) 回执。")
                showBanner("已存 \(responder.label) 回执")
            }
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    func runCodexAutonomously(for thread: ConversationThread, sandbox: CodexSandboxMode) {
        selectedThreadID = thread.id
        showBanner("⚡ 正在后台直跑 Codex（\(sandbox.label)）…")
        report("正在运行本地 Codex（\(sandbox.label)），结果将自动写入当前线程…")
        codexRunner.run(thread: thread, sandbox: sandbox, store: store) { [weak self] result in
            guard let self else { return }
            self.refresh()
            switch result {
            case .success(let saved):
                self.selectedThreadID = saved.effectiveThreadId
                self.report("⚡ Codex 自动执行完成，回执已写入当前线程。")
                self.showBanner("⚡ Codex 已完成并写入回执：\(thread.subject)")
                NSSound(named: .init("Glass"))?.play()
            case .failure(let error):
                self.report(error.localizedDescription, isError: true)
                self.showBanner("Codex 执行失败：\(error.localizedDescription)")
            }
        }
    }

    func launchAutoPilotInAntigravity(for thread: ConversationThread) {
        let prompt = """
        /wuyu-flow 请全自动接管并跑完无语工作站线程 `\(thread.id.uuidString)`（\(thread.subject)）。
        要求：全程不要让我当传声筒，由 Antigravity 与官方 codex MCP 自动完成独立审查、修改代码、复跑验证的多轮闭环，并把每一轮结果实时写入无语工作站直到标记完成。
        """
        guard copy(prompt) else { return }
        onHideMainWindow?()
        stageManager.focusSingle(.antigravity, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
            self?.onRaiseStageBar?()
        }) { [weak self] msg, isErr in
            self?.report(isErr ? msg : "已复制全自动 /wuyu-flow 指令并切到 Antigravity，粘贴回车后即可全程零传声筒并在工作台看实时直播。", isError: isErr)
            self?.showBanner("已复制全自动协同指令 → 切至 Antigravity 粘贴发送即可看直播")
        }
    }

    func dispatchThread(_ thread: ConversationThread, splitWithSender: Bool) {
        let target = thread.waitingFor ?? thread.latest.to
        let sender = thread.latest.from == target ? (thread.root.from == target ? .codex : thread.root.from) : thread.latest.from

        let copiedDescription: String
        if target.supportsLocalMCP {
            guard copy(makeShortMCPPrompt(subject: thread.subject, target: target)) else { return }
            copiedDescription = "极简 MCP 接力指令"
        } else {
            let packed = GitContextHelper.packGeminiContext(packet: thread.latest, thread: thread)
            guard copy(packed.text) else { return }
            copiedDescription = packed.skippedFiles.isEmpty
                ? "完整任务包"
                : "任务包（另有 \(packed.skippedFiles.count) 个文件需手动拖入附件）"
        }

        onHideMainWindow?()
        if splitWithSender && sender != target {
            stageManager.applySplitTwo(sender, target, ratio: 0.50, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
                self?.onRaiseStageBar?()
            }) { [weak self] msg, isErr in
                self?.report(isErr ? msg : "已复制\(copiedDescription)，\(msg)", isError: isErr)
                self?.showBanner(isErr ? msg : "已复制\(copiedDescription) → \(sender.shortLabel) | \(target.shortLabel)")
            }
        } else {
            stageManager.focusSingle(target, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
                self?.onRaiseStageBar?()
            }) { [weak self] msg, isErr in
                self?.report(isErr ? msg : "已复制\(copiedDescription)，\(msg)", isError: isErr)
                self?.showBanner(isErr ? msg : "已复制\(copiedDescription) → \(target.label)")
            }
        }
    }

    func focusTab(_ client: Client) {
        onHideMainWindow?()
        stageManager.focusSingle(client, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
            self?.onRaiseStageBar?()
        }) { [weak self] msg, isErr in
            self?.report(msg, isError: isErr)
            if isErr { self?.showBanner(msg) }
        }
    }

    func applySplit(_ left: Client, _ right: Client, ratio: CGFloat = 0.50) {
        if !stageManager.isAccessibilityTrusted {
            stageManager.requestAccessibilityPermission()
        }
        onHideMainWindow?()
        stageManager.applySplitTwo(left, right, ratio: ratio, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
            self?.onRaiseStageBar?()
        }) { [weak self] msg, isErr in
            self?.report(msg, isError: isErr)
            self?.showBanner(msg)
        }
    }

    func applyThreeSplit(_ primary: Client, _ topRight: Client, _ bottomRight: Client) {
        if !stageManager.isAccessibilityTrusted {
            stageManager.requestAccessibilityPermission()
        }
        onHideMainWindow?()
        stageManager.applySplitThree(primary, topRight, bottomRight, edge: stageBarEdge, on: activeScreen, reserveBar: isStageBarVisible, afterPlace: { [weak self] in
            self?.onRaiseStageBar?()
        }) { [weak self] msg, isErr in
            self?.report(msg, isError: isErr)
            self?.showBanner(msg)
        }
    }

    func setStatus(_ status: PacketStatus, for thread: ConversationThread) {
        do {
            _ = try store.updateStatus(threadOrPacketId: thread.id, status: status)
            refresh()
            report("状态已更新为「\(status.label)」。")
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    func deleteThread(_ thread: ConversationThread) {
        do {
            try store.deleteThread(thread.id)
            if selectedThreadID == thread.id { selectedThreadID = nil }
            refresh()
            report("已删除协作线程「\(thread.subject)」。")
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    func openCompose(_ template: WorkflowTemplate = .implementReviewFix) {
        onShowMainWindow?()
        sheet = .compose(.workflow(template))
    }

    func openReply(_ thread: ConversationThread) {
        onShowMainWindow?()
        sheet = .compose(.reply(thread))
    }

    func openSettings() {
        onShowMainWindow?()
        sheet = .settings
    }

    func setDockVerticalWidth(_ width: CGFloat) {
        let clamped = min(StageBarMetrics.verticalWidthRange.upperBound, max(StageBarMetrics.verticalWidthRange.lowerBound, round(width)))
        UserDefaults.standard.set(Double(clamped), forKey: StageBarMetrics.verticalWidthKey)
        stageManager.updateMetrics(for: activeScreen)
        onDockGeometryChanged?()
    }

    func setDockVerticalLengthPercent(_ pct: CGFloat) {
        let clamped = min(StageBarMetrics.verticalLengthPercentRange.upperBound, max(StageBarMetrics.verticalLengthPercentRange.lowerBound, round(pct)))
        UserDefaults.standard.set(Double(clamped), forKey: StageBarMetrics.verticalLengthPercentKey)
        stageManager.updateMetrics(for: activeScreen)
        onDockGeometryChanged?()
    }

    func setDockHorizontalHeight(_ height: CGFloat) {
        let clamped = min(StageBarMetrics.horizontalHeightRange.upperBound, max(StageBarMetrics.horizontalHeightRange.lowerBound, round(height)))
        UserDefaults.standard.set(Double(clamped), forKey: StageBarMetrics.horizontalHeightKey)
        stageManager.updateMetrics(for: activeScreen)
        onDockGeometryChanged?()
    }

    func setDockHorizontalLengthPercent(_ pct: CGFloat) {
        let clamped = min(StageBarMetrics.horizontalLengthPercentRange.upperBound, max(StageBarMetrics.horizontalLengthPercentRange.lowerBound, round(pct)))
        UserDefaults.standard.set(Double(clamped), forKey: StageBarMetrics.horizontalLengthPercentKey)
        stageManager.updateMetrics(for: activeScreen)
        onDockGeometryChanged?()
    }

    func resetDockDimensions() {
        stageManager.resetBarDimensions(on: activeScreen)
        onDockGeometryChanged?()
    }

    func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            report("写入剪贴板失败。", isError: true)
            return false
        }
        return true
    }

    func report(_ message: String, isError: Bool = false) {
        feedback = (message, isError)
    }

    func showBanner(_ text: String) {
        stageBanner = text
        bannerClearTask?.cancel()
        bannerClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.8))
            guard !Task.isCancelled else { return }
            self?.stageBanner = nil
        }
    }

    private func makeShortMCPPrompt(subject: String, target: Client) -> String {
        "请调用 MCP 工具 wuyu_get_current（client=\"\(target.rawValue)\"）读取无语工作站当前待办「\(subject)」，按要求完成本阶段后调用 wuyu_submit_reply 写回执。"
    }
}

// MARK: - Floating Mac Liquid-Glass 4-Edge Dock Bar

private struct StageBarView: View {
    @ObservedObject var model: WorkstationModel
    @ObservedObject var stage: WindowStageManager
    @ObservedObject var themeStore: WorkstationThemeStore
    @Environment(\.colorScheme) private var scheme
    @Namespace private var tabNamespace
    @State private var hoveredClient: Client?
    @State private var hoveredUtility: String?

    private var palette: WorkstationPalette { themeStore.palette(for: scheme) }
    private var isVertical: Bool { model.stageBarEdge.isVertical }

    var body: some View {
        GeometryReader { geo in
            let liveW = max(56, geo.size.width)
            let liveH = max(40, geo.size.height)
            Group {
                if isVertical {
                    verticalRail(width: liveW, height: liveH)
                } else {
                    horizontalBar(height: liveH)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectGlass(material: .hudWindow, blendingMode: .behindWindow)
                palette.sidebar.opacity(0.68)
            }
            .clipShape(RoundedRectangle(cornerRadius: isVertical ? 16 : 13, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: isVertical ? 16 : 13, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.26),
                            palette.line.opacity(0.85),
                            palette.line.opacity(0.55),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.80), value: stage.activeLayout)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isMainWindowVisible)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.stageBarEdge)
        .environment(\.workstationPalette, palette)
        .environment(\.workstationTextScale, 1)
    }

    // MARK: Horizontal Dock Bar (Top / Bottom — Live Resizable)

    private func horizontalBar(height: CGFloat) -> some View {
        let hScale = min(1.22, max(0.90, height / 46.0))
        let btnSize = max(26, round(28 * hScale))
        return HStack(spacing: 8) {
            Button { model.onToggleMainWindow?() } label: {
                HStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: round(22 * hScale), height: round(22 * hScale))
                    Text("无语")
                        .font(.system(size: round(12.5 * hScale), weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                .padding(.horizontal, 8)
                .frame(height: round(30 * hScale))
                .background(
                    model.isMainWindowVisible ? palette.accentWash : palette.hover.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                )
                .scaleEffect(hoveredUtility == "brand" ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { hoveredUtility = h ? "brand" : nil } }
            .help("展开 / 收起无语工作台面板（⌘\\）")

            barDividerHorizontal

            HStack(spacing: 3) {
                ForEach(Client.allCases) { client in horizontalClientTab(client, hScale: hScale) }
            }
            .padding(2.5)
            .background(palette.field.opacity(0.55), in: RoundedRectangle(cornerRadius: 9.5, style: .continuous))

            barDividerHorizontal

            HStack(spacing: 4) {
                splitPresetButton("Codex | AGY", active: stage.activeLayout == .splitTwo(.codex, .antigravity, 0.50), hScale: hScale) {
                    model.applySplit(.codex, .antigravity, ratio: 0.50)
                }
                splitPresetButton("Codex | Gem", active: stage.activeLayout == .splitTwo(.codex, .gemini, 0.54), hScale: hScale) {
                    model.applySplit(.codex, .gemini, ratio: 0.54)
                }
                splitOverflowMenu(width: btnSize, height: btnSize, iconSize: round(12 * hScale), wideLabel: nil)

                if !stage.isAccessibilityTrusted {
                    Button { stage.requestAccessibilityPermission() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield").font(.system(size: 10.5, weight: .semibold))
                            Text("授权分屏").font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(palette.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(palette.warningWash, in: Capsule())
                        .overlay { Capsule().strokeBorder(palette.warning.opacity(0.5)) }
                    }
                    .buttonStyle(.plain)
                    .help("打开「设备控制和数据访问」，移除旧条目后拖入 ~/Applications/无语工作站.app")
                }
            }

            Spacer(minLength: 6)

            if let banner = model.stageBanner {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
                    Text(banner).font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: round(28 * hScale))
                .background(palette.accentWash, in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else if let active = model.activePendingThread {
                HStack(spacing: 6) {
                    Button {
                        model.selectedThreadID = active.id
                        model.onShowMainWindow?()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(palette.clientColor(active.waitingFor)).frame(width: 7, height: 7)
                            Text("待 \(active.waitingFor?.shortLabel ?? "") · \(active.subject)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                                .frame(maxWidth: 210, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { model.dispatchThread(active, splitWithSender: true) } label: {
                        Text("接力")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(palette.accentText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button { model.quickCaptureClipboardReply(for: active) } label: {
                        Image(systemName: "clipboard")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.ink)
                            .frame(width: 22, height: 22)
                            .background(palette.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("从剪贴板一键保存为当前任务回执")
                }
                .padding(.leading, 9).padding(.trailing, 5)
                .frame(height: round(30 * hScale))
                .background(palette.surface.opacity(0.88), in: Capsule())
                .overlay { Capsule().strokeBorder(palette.line) }
            }

            HStack(spacing: 4) {
                newWorkflowIconButton(width: btnSize, height: btnSize, iconSize: round(12 * hScale), wideTitle: nil)
                themeQuickMenu(width: btnSize, height: btnSize, iconSize: round(12 * hScale), wideTitle: nil)
                dockEdgeMenu(width: btnSize, height: btnSize, iconSize: round(12 * hScale), wideTitle: nil)
                toggleMainWindowIconButton(size: btnSize)
                settingsIconButton(width: btnSize, height: btnSize, iconSize: round(12 * hScale), wideTitle: nil)
                collapseBarIconButton(width: max(22, btnSize - 4), height: btnSize, iconSize: round(11 * hScale))
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: Vertical Mac Dock Rail (Left / Right — Live Drag-Resizable & Auto Wide-Mode)

    private func verticalRail(width: CGFloat, height: CGFloat) -> some View {
        let isWide = width >= 112
        let scale = min(1.30, max(0.82, width / 74.0))
        let innerW = max(40, floor(width - 16))
        let tileH = isWide ? max(36, round(38 * min(1.15, scale))) : max(40, round(46 * scale))
        let utilH = isWide ? 30.0 : max(28, round(30 * scale))
        let iconSz = isWide ? 14.0 : max(12.5, round(15 * scale))
        let vSpacing = max(4, min(10, round((height - 460) / 36)))

        return VStack(spacing: vSpacing) {
            // Brand / Toggle Main Workstation
            Button { model.onToggleMainWindow?() } label: {
                Group {
                    if isWide {
                        HStack(spacing: 8) {
                            Image(nsImage: NSApplication.shared.applicationIconImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                            Text("无语工作站")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(width: innerW, height: 38)
                    } else {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: round(32 * scale), height: round(32 * scale))
                            .frame(width: innerW, height: max(38, round(42 * scale)))
                    }
                }
                .background(
                    model.isMainWindowVisible ? palette.accentWash : .clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .scaleEffect(hoveredUtility == "brand" ? 1.04 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { hoveredUtility = h ? "brand" : nil } }
            .help("展开 / 收起无语工作台面板（⌘\\）· 拖动边缘可自由调整宽度和长度")

            Rectangle().fill(palette.line).frame(width: max(28, innerW - 10), height: 1)

            // 4 Client Tabs
            VStack(spacing: max(4, vSpacing - 1)) {
                ForEach(Client.allCases) { client in
                    verticalClientTab(client, width: innerW, height: tileH, scale: scale, isWide: isWide)
                }
            }

            Rectangle().fill(palette.line).frame(width: max(28, innerW - 10), height: 1)

            // Quick Split Controls
            VStack(spacing: 5) {
                Button { model.applySplit(.codex, .antigravity, ratio: 0.50) } label: {
                    Group {
                        if isWide {
                            HStack(spacing: 7) {
                                Image(systemName: "rectangle.split.2x1").font(.system(size: 13, weight: .medium))
                                Text("Codex | AGY").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                        } else {
                            VStack(spacing: 2) {
                                Image(systemName: "rectangle.split.2x1").font(.system(size: iconSz, weight: .medium))
                                Text("双拼").font(.system(size: max(9, round(9.5 * scale)), weight: .medium))
                            }
                        }
                    }
                    .foregroundStyle(stage.activeLayout == .splitTwo(.codex, .antigravity, 0.50) ? palette.accent : palette.muted)
                    .frame(width: innerW, height: isWide ? 34 : max(36, round(38 * scale)))
                    .background(
                        stage.activeLayout == .splitTwo(.codex, .antigravity, 0.50) ? palette.accentWash : palette.surface.opacity(0.68),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(stage.activeLayout == .splitTwo(.codex, .antigravity, 0.50) ? palette.accent.opacity(0.55) : palette.line)
                    }
                }
                .buttonStyle(.plain)
                .help("一键双拼：Codex | Antigravity")

                splitOverflowMenu(width: innerW, height: utilH, iconSize: iconSz, wideLabel: isWide ? "更多分屏" : nil)
            }

            if let active = model.activePendingThread {
                Button {
                    model.selectedThreadID = active.id
                    model.onShowMainWindow?()
                } label: {
                    Group {
                        if isWide {
                            HStack(spacing: 6) {
                                Circle().fill(palette.clientColor(active.waitingFor)).frame(width: 7, height: 7)
                                Text(active.subject).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                        } else {
                            VStack(spacing: 2) {
                                Circle().fill(palette.clientColor(active.waitingFor)).frame(width: 7, height: 7)
                                Text("待办").font(.system(size: max(9, round(9.5 * scale)), weight: .semibold)).foregroundStyle(palette.ink)
                            }
                        }
                    }
                    .frame(width: innerW, height: isWide ? 32 : max(32, round(34 * scale)))
                    .background(palette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.line) }
                }
                .buttonStyle(.plain)
                .help("当前待办：\(active.subject)")
            }

            Spacer(minLength: 2)

            if !stage.isAccessibilityTrusted {
                Button { stage.requestAccessibilityPermission() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 12))
                        if isWide { Text("授权分屏").font(.system(size: 11, weight: .semibold)) }
                    }
                    .foregroundStyle(palette.warning)
                    .frame(width: innerW, height: utilH)
                    .background(palette.warningWash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("点击打开系统设置授权分屏权限")
            }

            Rectangle().fill(palette.line).frame(width: max(28, innerW - 10), height: 1)

            // Bottom Utility Controls (Uniform pill sizing & alignment!)
            VStack(spacing: 5) {
                newWorkflowIconButton(width: innerW, height: utilH, iconSize: iconSz, wideTitle: isWide ? "新建协同" : nil)
                if isWide {
                    HStack(spacing: 5) {
                        let subW = floor((innerW - 10) / 3)
                        themeQuickMenu(width: subW, height: utilH, iconSize: 13, wideTitle: nil)
                        dockEdgeMenu(width: subW, height: utilH, iconSize: 13, wideTitle: nil)
                        settingsIconButton(width: subW, height: utilH, iconSize: 13, wideTitle: nil)
                    }
                } else {
                    themeQuickMenu(width: innerW, height: utilH, iconSize: iconSz, wideTitle: nil)
                    dockEdgeMenu(width: innerW, height: utilH, iconSize: iconSz, wideTitle: nil)
                    settingsIconButton(width: innerW, height: utilH, iconSize: iconSz, wideTitle: nil)
                }
                collapseBarIconButton(width: innerW, height: max(22, utilH - 6), iconSize: 11)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    // MARK: Shared Interactive Controls

    private func horizontalClientTab(_ client: Client, hScale: CGFloat) -> some View {
        let isActive = stage.activeLayout == .single(client)
        let isInSplit = stage.activeLayout?.involvedClients.contains(client) ?? false
        let running = stage.runningClients.contains(client)
        let waiting = model.waitingCount(for: client)
        let hovered = hoveredClient == client

        return Button { model.focusTab(client) } label: {
            HStack(spacing: 5) {
                ClientGlyph(client: client, size: round(13 * hScale))
                    .foregroundStyle(isActive || isInSplit || hovered ? palette.clientColor(client) : palette.muted)
                Text(client.shortLabel)
                    .font(.system(size: round(11.5 * hScale), weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive || hovered ? palette.ink : palette.muted)
                if waiting > 0 {
                    Text("\(waiting)")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(palette.clientColor(client), in: Capsule())
                } else if running {
                    Circle().fill(palette.success.opacity(0.9)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: round(27 * hScale))
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(palette.clientWash(client))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .strokeBorder(palette.clientColor(client).opacity(0.6), lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "activeClientTab", in: tabNamespace)
                } else if isInSplit || hovered {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(palette.hover.opacity(isInSplit ? 0.78 : 0.55))
                }
            }
            .scaleEffect(hovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.70)) { hoveredClient = h ? client : nil } }
        .help("切到 \(client.label) 单页（\(client.roleHint)）")
    }

    private func verticalClientTab(_ client: Client, width: CGFloat, height: CGFloat, scale: CGFloat, isWide: Bool) -> some View {
        let isActive = stage.activeLayout == .single(client)
        let isInSplit = stage.activeLayout?.involvedClients.contains(client) ?? false
        let running = stage.runningClients.contains(client)
        let waiting = model.waitingCount(for: client)
        let hovered = hoveredClient == client

        return Button { model.focusTab(client) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isWide {
                        HStack(spacing: 8) {
                            ClientGlyph(client: client, size: 15)
                                .foregroundStyle(isActive || isInSplit || hovered ? palette.clientColor(client) : palette.muted)
                            Text(client.label)
                                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive || hovered ? palette.ink : palette.muted)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if waiting > 0 {
                                Text("\(waiting)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(palette.clientColor(client), in: Capsule())
                            } else if running {
                                Circle().fill(palette.success).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 10)
                    } else {
                        VStack(spacing: 3) {
                            ClientGlyph(client: client, size: max(14, round(16.5 * scale)))
                                .foregroundStyle(isActive || isInSplit || hovered ? palette.clientColor(client) : palette.muted)
                            Text(client.shortLabel)
                                .font(.system(size: max(9, round(10 * scale)), weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive || hovered ? palette.ink : palette.muted)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: width, height: height)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(palette.clientWash(client))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(palette.clientColor(client).opacity(0.65), lineWidth: 1.15)
                            }
                            .matchedGeometryEffect(id: "activeClientTab", in: tabNamespace)
                    } else if isInSplit || hovered {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(palette.hover.opacity(isInSplit ? 0.80 : 0.58))
                    }
                }

                if !isWide {
                    if waiting > 0 {
                        Text("\(waiting)")
                            .font(.system(size: max(8.5, round(8.5 * scale)), weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1.5)
                            .background(palette.clientColor(client), in: Capsule())
                            .offset(x: 3, y: -3)
                    } else if running {
                        Circle()
                            .fill(palette.success)
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: -5, y: 5)
                    }
                }
            }
            .scaleEffect(hovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.68)) { hoveredClient = h ? client : nil } }
        .help("切到 \(client.label) 单页（\(client.roleHint)）")
    }

    private func splitPresetButton(_ title: String, active: Bool, hScale: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: round(11 * hScale), weight: active ? .semibold : .medium))
                .foregroundStyle(active ? palette.accent : palette.muted)
                .padding(.horizontal, 8)
                .frame(height: round(28 * hScale))
                .background(active ? palette.accentWash : palette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(active ? palette.accent.opacity(0.55) : palette.line)
                }
        }
        .buttonStyle(.plain)
    }

    private func splitOverflowMenu(width: CGFloat, height: CGFloat, iconSize: CGFloat, wideLabel: String?) -> some View {
        Menu {
            Button("Codex | Antigravity（主力 + 审查）") { model.applySplit(.codex, .antigravity, ratio: 0.50) }
            Button("Codex | Gemini（编码 + 多模态资料）") { model.applySplit(.codex, .gemini, ratio: 0.54) }
            Button("Codex | Claude（双代码/双视角）") { model.applySplit(.codex, .claude, ratio: 0.50) }
            Button("Antigravity | Gemini（Google 双端）") { model.applySplit(.antigravity, .gemini, ratio: 0.50) }
            Divider()
            Button("三端 1+2：Codex + Antigravity + Gemini") { model.applyThreeSplit(.codex, .antigravity, .gemini) }
            Button("三端 1+2：Codex + Antigravity + Claude") { model.applyThreeSplit(.codex, .antigravity, .claude) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.system(size: iconSize, weight: .medium))
                if let wideLabel {
                    Text(wideLabel).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(palette.muted)
            .padding(.horizontal, wideLabel == nil ? 0 : 9)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: height)
        .background(palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8.5, style: .continuous).strokeBorder(palette.line.opacity(0.8)) }
        .help("更多双拼 / 三端联合分屏布局")
    }

    private func newWorkflowIconButton(width: CGFloat, height: CGFloat, iconSize: CGFloat, wideTitle: String?) -> some View {
        Button { model.openCompose(.implementReviewFix) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: iconSize, weight: .semibold))
                if let wideTitle {
                    Text(wideTitle).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(palette.accentText)
            .frame(width: width, height: height)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("新建协作 / 启动 Workflow（⌘N）")
    }

    private func themeQuickMenu(width: CGFloat, height: CGFloat, iconSize: CGFloat, wideTitle: String?) -> some View {
        Menu {
            ForEach(WorkstationThemePreset.allCases) { preset in
                Button { themeStore.selectPreset(preset) } label: {
                    if themeStore.preset == preset && !themeStore.hasCustomOverrides {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
            Divider()
            Button("日间 / 夜间模式与自定义色值…") { model.openSettings() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette").font(.system(size: iconSize, weight: .medium))
                if let wideTitle { Text(wideTitle).font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(palette.accent)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: height)
        .background(palette.accentWash.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help("快速切换配色主题（当前：\(themeStore.preset.label)）")
    }

    private func dockEdgeMenu(width: CGFloat, height: CGFloat, iconSize: CGFloat, wideTitle: String?) -> some View {
        Menu {
            ForEach(StageBarEdge.allCases) { edge in
                Button { model.stageBarEdge = edge } label: {
                    if model.stageBarEdge == edge {
                        Label("停靠在\(edge.label)", systemImage: "checkmark")
                    } else {
                        Label("停靠在\(edge.label)", systemImage: edge.symbolName)
                    }
                }
            }
            Divider()
            Button("悬浮滑块微调宽/长（无需打开主窗口）…") {
                model.onToggleDockSizeHud?()
            }
            if isVertical {
                Menu("快速调整宽度") {
                    Button("紧凑窄栏（66 px）") { model.setDockVerticalWidth(66) }
                    Button("默认图标栏（80 px）") { model.setDockVerticalWidth(80) }
                    Button("宽侧边栏（132 px · 显示完整名称）") { model.setDockVerticalWidth(132) }
                    Button("特宽侧边栏（166 px）") { model.setDockVerticalWidth(166) }
                }
                Menu("快速调整长度") {
                    Button("短栏（58%）") { model.setDockVerticalLengthPercent(58) }
                    Button("适中（76%）") { model.setDockVerticalLengthPercent(76) }
                    Button("长栏（90%）") { model.setDockVerticalLengthPercent(90) }
                    Button("贴满全高（100%）") { model.setDockVerticalLengthPercent(100) }
                }
            } else {
                Menu("快速调整高度") {
                    Button("紧凑（42 px）") { model.setDockHorizontalHeight(42) }
                    Button("标准（48 px）") { model.setDockHorizontalHeight(48) }
                    Button("舒适（58 px）") { model.setDockHorizontalHeight(58) }
                }
                Menu("快速调整长度") {
                    Button("居中短栏（75%）") { model.setDockHorizontalLengthPercent(75) }
                    Button("标准（90%）") { model.setDockHorizontalLengthPercent(90) }
                    Button("贴满全宽（98%）") { model.setDockHorizontalLengthPercent(98) }
                }
            }
            Button("重置为默认尺寸") { model.resetDockDimensions() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.stageBarEdge.symbolName).font(.system(size: iconSize, weight: .medium))
                if let wideTitle { Text(wideTitle).font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(palette.muted)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: width, height: height)
        .background(palette.surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.line.opacity(0.7)) }
        .help("切换停靠方向或调节宽高 · 隐藏主窗口时也可直接拖边缘缩放")
    }

    private func toggleMainWindowIconButton(size: CGFloat) -> some View {
        Button { model.onToggleMainWindow?() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.isMainWindowVisible ? palette.accent : palette.muted)
                .frame(width: size, height: size)
                .background(model.isMainWindowVisible ? palette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("展开 / 收起工作台主界面")
    }

    private func settingsIconButton(width: CGFloat, height: CGFloat, iconSize: CGFloat, wideTitle: String?) -> some View {
        Button { model.openSettings() } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape").font(.system(size: iconSize, weight: .medium))
                if let wideTitle { Text(wideTitle).font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(palette.muted)
            .frame(width: width, height: height)
            .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("工作站设置与尺寸调节（⌘,）")
    }

    private func collapseBarIconButton(width: CGFloat, height: CGFloat, iconSize: CGFloat) -> some View {
        Button { model.onToggleStageBar?() } label: {
            Image(systemName: collapseChevronName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(palette.quiet)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("收起悬浮切换栏（可从顶部菜单栏图标随时唤回）")
    }

    private var collapseChevronName: String {
        switch model.stageBarEdge {
        case .top: "chevron.up"
        case .bottom: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    private var barDividerHorizontal: some View {
        Rectangle().fill(palette.line).frame(width: 1, height: 20)
    }
}

// MARK: - Responsive FlowLayout (Never breaks chip words at any font scale)

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Main V2.1 Workstation View

private struct BridgeView: View {
    @ObservedObject var model: WorkstationModel
    @ObservedObject var stage: WindowStageManager
    @ObservedObject var themeStore: WorkstationThemeStore
    @ObservedObject var codexRunner: CodexRunner

    @AppStorage("workstation.sidebarWidth") private var sidebarWidth: Double = 310
    @Environment(\.colorScheme) private var scheme
    @State private var showDiffExpanded = false
    @State private var dismissAccessibilityBanner = false
    @State private var dragStartWidth: Double?
    @State private var isHoveringDivider = false
    @FocusState private var searchFocused: Bool

    private var palette: WorkstationPalette { themeStore.palette(for: scheme) }
    private var clampedSidebarWidth: CGFloat { CGFloat(min(max(sidebarWidth, 230), 520)) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: clampedSidebarWidth)
            sidebarSplitter
            workspace
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 540)
        .background(palette.canvas)
        .tint(palette.accent)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .compose(let draft):
                ComposeView(draft: draft) { payload in
                    try model.saveCompose(payload, draft: draft)
                }
                .environment(\.workstationPalette, palette)
                .environment(\.workstationTextScale, WorkstationTextSize.scale(for: themeStore.fontPercent))
            case .settings:
                SettingsView(
                    themeStore: themeStore,
                    stageManager: stage,
                    stageBarEdge: $model.stageBarEdge,
                    onDockGeometryChanged: { model.onDockGeometryChanged?() }
                )
                .environment(\.workstationPalette, palette)
            }
        }
        .environment(\.workstationPalette, palette)
        .environment(\.workstationTextScale, WorkstationTextSize.scale(for: themeStore.fontPercent))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var sidebarSplitter: some View {
        ZStack {
            Rectangle()
                .fill(isHoveringDivider || dragStartWidth != nil ? palette.accent : palette.line)
                .frame(width: isHoveringDivider || dragStartWidth != nil ? 2 : 1)
        }
        .frame(width: 7)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringDivider = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = Double(clampedSidebarWidth) }
                    sidebarWidth = min(max((dragStartWidth ?? 310) + value.translation.width, 230), 520)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .onTapGesture(count: 2) { sidebarWidth = 310 }
        .help("左右拖动调整侧栏宽度（双击恢复默认）")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("无语工作站")
                        .workstationFont(14, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text("MCP 共享黑板 · \(themeStore.preset.label)")
                        .workstationFont(10)
                        .foregroundStyle(palette.quiet)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 12)

            Button { model.openCompose(.implementReviewFix) } label: {
                Label("新建协作 / Workflow", systemImage: "bolt.horizontal.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(WorkstationButtonStyle(.primary))
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 13)
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.quiet)
                TextField("搜索线程、项目或正文…", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .workstationFont(12)
                    .focused($searchFocused)
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(palette.quiet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(palette.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line) }
            .padding(.horizontal, 13)
            .padding(.bottom, 10)

            Picker("状态", selection: $model.statusScope) {
                ForEach(StatusScope.allCases) { scope in Text(scope.label).tag(scope) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 13)
            .padding(.bottom, 10)

            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                clientFilterChip(nil)
                ForEach(Client.allCases) { client in clientFilterChip(client) }
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 10)

            Rectangle().fill(palette.line).frame(height: 1)

            if model.filteredThreads.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(palette.quiet)
                    Text("当前筛选下暂无协作线程").workstationFont(12).foregroundStyle(palette.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $model.selectedThreadID) {
                    ForEach(model.filteredThreads) { thread in
                        threadRow(thread)
                            .tag(thread.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 4) {
                Button { model.onToggleStageBar?() } label: {
                    Label(model.isStageBarVisible ? "隐藏顶栏" : "显示顶栏", systemImage: "menubar.rectangle")
                }
                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                Spacer()
                Button { model.openSettings() } label: {
                    Label("设置与配色", systemImage: "paintpalette")
                }
                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
        }
        .frame(maxHeight: .infinity)
        .background(palette.sidebar)
    }

    private func clientFilterChip(_ client: Client?) -> some View {
        let active = model.clientFilter == client
        let count = client.map { model.waitingCount(for: $0) } ?? model.totalPendingCount
        return Button {
            model.clientFilter = client
            if model.selectedThread == nil { model.selectedThreadID = model.filteredThreads.first?.id }
        } label: {
            HStack(spacing: 4) {
                ClientGlyph(client: client, size: 12)
                    .foregroundStyle(active ? palette.clientColor(client) : palette.muted)
                Text(client?.shortLabel ?? "全部")
                    .workstationFont(11, weight: active ? .semibold : .medium)
                    .foregroundStyle(active ? palette.ink : palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if count > 0 {
                    Text("\(count)")
                        .workstationFont(10, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(active ? palette.clientColor(client) : palette.quiet)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(active ? palette.clientWash(client) : palette.surface.opacity(0.6), in: Capsule())
            .overlay { Capsule().strokeBorder(active ? palette.clientColor(client).opacity(0.5) : palette.line) }
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
    }

    private func threadRow(_ thread: ConversationThread) -> some View {
        let selected = model.selectedThreadID == thread.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(palette.statusColor(thread.status)).frame(width: 7, height: 7)
                Text(thread.subject).workstationFont(12.5, weight: .semibold).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(thread.updatedAt.formatted(.relative(presentation: .named))).workstationFont(10).foregroundStyle(palette.quiet)
            }
            HStack(spacing: 5) {
                if let waiting = thread.waitingFor {
                    Text("待 \(waiting.shortLabel)")
                        .workstationFont(10, weight: .semibold)
                        .foregroundStyle(palette.clientColor(waiting))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(palette.clientWash(waiting), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(thread.status.label).workstationFont(10, weight: .medium).foregroundStyle(palette.statusColor(thread.status))
                }
                Text(thread.participants.map(\.shortLabel).joined(separator: " ⇄ "))
                    .workstationFont(10).foregroundStyle(palette.muted).lineLimit(1)
                Spacer(minLength: 2)
                if !thread.workflowSteps.isEmpty {
                    Text("\(thread.completedStepCount)/\(thread.workflowSteps.count)")
                        .workstationFont(10, weight: .medium).monospacedDigit().foregroundStyle(palette.accent)
                }
                Text("\(thread.messages.count)轮").workstationFont(10).foregroundStyle(palette.quiet)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(selected ? palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ClientGlyph(client: model.clientFilter, size: 15)
                    .foregroundStyle(palette.clientColor(model.clientFilter))
                Text(model.clientFilter?.label ?? "全部协作线程")
                    .workstationFont(13, weight: .semibold)
                    .foregroundStyle(palette.ink)

                Spacer()

                if !model.isStageBarVisible {
                    HStack(spacing: 4) {
                        Button("Codex | AGY") { model.applySplit(.codex, .antigravity) }
                            .buttonStyle(WorkstationButtonStyle(.secondary, compact: true))
                        Button("Codex | Gem") { model.applySplit(.codex, .gemini) }
                            .buttonStyle(WorkstationButtonStyle(.secondary, compact: true))
                    }
                }

                Button { model.refresh(reportSuccess: true) } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .frame(height: 56)

            Rectangle().fill(palette.line).frame(height: 1)

            if !stage.isAccessibilityTrusted && !dismissAccessibilityBanner {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x1.fill").foregroundStyle(palette.warning)
                    Text("若「设备控制和数据访问」里已有旧条目，请先点「−」删除，再把 ~/Applications/无语工作站.app 拖入列表即可启用一键分屏。")
                        .workstationFont(11.5)
                        .foregroundStyle(palette.ink)
                    Spacer()
                    Button("Finder 定位应用") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .buttonStyle(WorkstationButtonStyle(.secondary, compact: true))
                    Button("打开系统设置") { stage.requestAccessibilityPermission() }
                        .buttonStyle(WorkstationButtonStyle(.primary, compact: true))
                    Button { dismissAccessibilityBanner = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.quiet)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(palette.warningWash)
                Rectangle().fill(palette.line).frame(height: 1)
            }

            if let thread = model.selectedThread {
                threadDetail(thread).id(thread.id)
            } else {
                emptyState
            }

            if let feedback = model.feedback {
                Rectangle().fill(palette.line).frame(height: 1)
                HStack(spacing: 7) {
                    Image(systemName: feedback.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(feedback.isError ? palette.danger : palette.success)
                    Text(feedback.message)
                        .workstationFont(11)
                        .foregroundStyle(feedback.isError ? palette.danger : palette.muted)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
            }
        }
    }

    private func fluidContentWidth(for availableWidth: CGFloat) -> CGFloat {
        let scale = WorkstationTextSize.scale(for: themeStore.fontPercent)
        // Always fill ~85% of the workspace canvas; gently expand up to ~91% as font scale grows
        let ratio = min(0.91, max(0.84, 0.85 + max(0, scale - 1.0) * 0.17))
        let maxAllowed = max(480, availableWidth - 32)
        return min(maxAllowed, max(540, floor(availableWidth * ratio)))
    }

    private var emptyState: some View {
        GeometryReader { proxy in
            let targetWidth = fluidContentWidth(for: proxy.size.width)
            VStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 76, height: 76)
                Text("开始一次多模型协同 Workflow")
                    .workstationFont(22, weight: .semibold).foregroundStyle(palette.ink)
                Text("Codex 主力实现 · Antigravity（Gemini 4 + 内置 Claude）审查与编排 · Gemini Ultra 多模态初读")
                    .workstationFont(12.5).foregroundStyle(palette.muted).multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    quickLaunchCard(.implementReviewFix)
                    quickLaunchCard(.codeDiffReview)
                    quickLaunchCard(.multimodalToCode)
                }
                .padding(.top, 6)
                .frame(width: targetWidth)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func quickLaunchCard(_ template: WorkflowTemplate) -> some View {
        Button { model.openCompose(template) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(template.title).workstationFont(13, weight: .semibold).foregroundStyle(palette.ink).lineLimit(1)
                Text(template.subtitle).workstationFont(11.5).foregroundStyle(palette.muted).lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("立即启动").workstationFont(11.5, weight: .semibold).foregroundStyle(palette.accent)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 162, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line) }
        }
        .buttonStyle(.plain)
    }

    private func threadDetail(_ thread: ConversationThread) -> some View {
        let isLocalCodexRunning = codexRunner.runningThreadID == thread.id
        let isLiveInProgress = thread.status == .inProgress || isLocalCodexRunning

        return VStack(spacing: 0) {
            GeometryReader { proxy in
                let targetWidth = fluidContentWidth(for: proxy.size.width)
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            threadHeader(thread)
                            if !thread.workflowSteps.isEmpty { workflowStepper(thread) }
                            if thread.workspacePath != nil || !thread.attachedFiles.isEmpty || thread.gitDiffSummary != nil {
                                contextCard(thread)
                            }
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(thread.messages.enumerated()), id: \.element.id) { idx, message in
                                    messageCard(message, index: idx + 1)
                                        .id(message.id)
                                }
                            }
                            if isLiveInProgress {
                                liveActivityCard(isLocalCodexRunning: isLocalCodexRunning)
                                    .id("live-activity-anchor")
                            }
                        }
                        .frame(width: targetWidth, alignment: .leading)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: thread.messages.count) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if isLiveInProgress {
                                scrollProxy.scrollTo("live-activity-anchor", anchor: .bottom)
                            } else if let lastID = thread.messages.last?.id {
                                scrollProxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            Rectangle().fill(palette.line).frame(height: 1)
            actionBar(thread)
        }
    }

    private func liveActivityCard(isLocalCodexRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(isLocalCodexRunning
                    ? "⚡ Codex 正在工作站内自动执行（已用时 \(codexRunner.elapsedSeconds)s）"
                    : "⚡ 多模型自动协同进行中（实时直播，新轮次将自动上屏）")
                    .workstationFont(12.5, weight: .semibold)
                    .foregroundStyle(palette.accent)
                Spacer()
                if isLocalCodexRunning {
                    Button("停止") { codexRunner.cancel() }
                        .buttonStyle(WorkstationButtonStyle(.subtleDanger, compact: true))
                }
            }
            if isLocalCodexRunning {
                if !codexRunner.liveStatusText.isEmpty {
                    Text(codexRunner.liveStatusText)
                        .workstationFont(11.5, weight: .medium)
                        .foregroundStyle(palette.ink)
                }
                if !codexRunner.liveLogLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(codexRunner.liveLogLines.suffix(5).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.codeSurface, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("Antigravity 与 Codex 正在通过官方 MCP 自动交互，无需手动复制粘贴；每完成一轮都会自动落盘并滚动显示在上方。")
                    .workstationFont(11.5)
                    .foregroundStyle(palette.muted)
            }
        }
        .padding(15)
        .background(palette.accentWash.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.accent.opacity(0.55), lineWidth: 1.2)
        }
    }

    private func threadHeader(_ thread: ConversationThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(PacketStatus.allCases) { st in
                        Button(st.label) { model.setStatus(st, for: thread) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(palette.statusColor(thread.status)).frame(width: 7, height: 7)
                        Text(thread.status.label).workstationFont(11, weight: .semibold)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(palette.statusColor(thread.status))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(palette.surface, in: Capsule())
                    .overlay { Capsule().strokeBorder(palette.line) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if let waiting = thread.waitingFor {
                    HStack(spacing: 5) {
                        ClientGlyph(client: waiting, size: 12)
                        Text("当前等待 \(waiting.label)").workstationFont(11, weight: .semibold)
                    }
                    .foregroundStyle(palette.clientColor(waiting))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(palette.clientWash(waiting), in: Capsule())
                }

                Spacer()

                Toggle("原文", isOn: $model.showRawMarkdown).toggleStyle(.checkbox).workstationFont(11).foregroundStyle(palette.muted)

                Button {
                    if model.copy(thread.id.uuidString) { model.report("已复制线程 ID。") }
                } label: { Label("ID", systemImage: "number") }
                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                .help(thread.id.uuidString)

                Button { model.deleteThread(thread) } label: { Image(systemName: "trash") }
                    .buttonStyle(WorkstationButtonStyle(.subtleDanger, compact: true))
                    .help("删除整个协作线程")
            }

            Text(thread.subject).workstationFont(21, weight: .semibold).foregroundStyle(palette.ink).textSelection(.enabled)
        }
    }

    private func workflowStepper(_ thread: ConversationThread) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ChipFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(thread.workflowSteps) { step in
                    let done = step.completedPacketID != nil
                    let current = thread.currentStage?.index == step.index && thread.isActive
                    HStack(spacing: 6) {
                        if step.index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.quiet)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: done ? "checkmark.circle.fill" : (current ? "record.circle" : "circle"))
                                .font(.system(size: 12))
                                .foregroundStyle(done ? palette.success : (current ? palette.clientColor(step.client) : palette.quiet))
                            Text("\(step.index + 1). \(step.client.shortLabel) · \(step.role)")
                                .workstationFont(11.5, weight: current ? .semibold : .medium)
                                .foregroundStyle(current ? palette.ink : palette.muted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(current ? palette.clientWash(step.client) : palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(current ? palette.clientColor(step.client).opacity(0.6) : palette.line) }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
            if let stage = thread.currentStage, thread.isActive {
                HStack(alignment: .top, spacing: 7) {
                    Text("当前阶段指引：")
                        .workstationFont(11, weight: .semibold)
                        .foregroundStyle(palette.accent)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(stage.instruction)
                        .workstationFont(11.5)
                        .foregroundStyle(palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line) }
    }

    private func contextCard(_ thread: ConversationThread) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let ws = thread.workspacePath {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(palette.accent).font(.system(size: 12))
                    Text(ws).workstationFont(11.5).foregroundStyle(palette.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Finder 打开") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ws) }
                        .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                }
            }
            if !thread.attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(thread.attachedFiles, id: \.self) { file in
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text").font(.system(size: 10))
                                    Text(URL(fileURLWithPath: file).lastPathComponent).workstationFont(11)
                                }
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(palette.accentWash, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("点击在 Finder 中定位：\(file)")
                        }
                    }
                }
            }
            if let diff = thread.gitDiffSummary {
                DisclosureGroup("Git 变更上下文摘要", isExpanded: $showDiffExpanded) {
                    MarkdownContentView(text: diff, showRaw: false).padding(.top, 6)
                }
                .workstationFont(11.5, weight: .semibold)
            }
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line) }
    }

    private func messageCard(_ packet: Packet, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Text("#\(index)").workstationFont(10.5, weight: .bold).monospacedDigit().foregroundStyle(palette.quiet)
                clientChip(packet.from)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.quiet)
                clientChip(packet.to)
                Spacer()
                Text(packet.createdAt.formatted(date: .abbreviated, time: .shortened)).workstationFont(10.5).foregroundStyle(palette.quiet)
                Button {
                    if model.copy(packet.body) { model.report("已复制第 \(index) 轮正文。") }
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(palette.muted) }
                .buttonStyle(.plain)
            }
            Rectangle().fill(palette.line.opacity(0.7)).frame(height: 1)
            MarkdownContentView(text: packet.body, showRaw: model.showRawMarkdown)
        }
        .padding(17)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line).allowsHitTesting(false) }
    }

    private func clientChip(_ client: Client) -> some View {
        HStack(spacing: 5) {
            ClientGlyph(client: client, size: 13)
            Text(client.label)
        }
        .workstationFont(11, weight: .semibold)
        .foregroundStyle(palette.clientColor(client))
        .padding(.horizontal, 7).padding(.vertical, 3.5)
        .background(palette.clientWash(client), in: RoundedRectangle(cornerRadius: 6))
    }

    private func actionBar(_ thread: ConversationThread) -> some View {
        let target = thread.waitingFor ?? thread.latest.to
        return HStack(spacing: 8) {
            Button { model.openReply(thread) } label: { Label("写回执", systemImage: "arrowshape.turn.up.left") }
                .buttonStyle(WorkstationButtonStyle(.secondary))
            Button { model.quickCaptureClipboardReply(for: thread) } label: { Label("剪贴板存回执", systemImage: "clipboard") }
                .buttonStyle(WorkstationButtonStyle(.quiet))
            Spacer(minLength: 8)

            Menu {
                Button("只读审查（read-only）") {
                    model.runCodexAutonomously(for: thread, sandbox: .readOnly)
                }
                Button("允许修改项目代码（workspace-write）") {
                    model.runCodexAutonomously(for: thread, sandbox: .workspaceWrite)
                }
            } label: {
                Label(codexRunner.runningThreadID == thread.id ? "Codex 运行中…" : "直跑 Codex", systemImage: "terminal")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line) }
            .disabled(codexRunner.isRunning)
            .help("工作站直接后台调用本地 codex exec 执行本阶段并自动写回执")

            Button { model.launchAutoPilotInAntigravity(for: thread) } label: {
                Label("全自动协同", systemImage: "bolt.fill")
            }
            .buttonStyle(WorkstationButtonStyle(.primary))
            .help("复制 1 条全自动 /wuyu-flow 指令并切到 Antigravity，后续 Gemini 4 ↔ Codex 多轮自动交互并直播上屏")

            Button { model.dispatchThread(thread, splitWithSender: true) } label: {
                Label("双拼 \(target.shortLabel)", systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(WorkstationButtonStyle(.secondary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}

// MARK: - Floating Panel Subclass, Always-Active Edge Resizer, Mini Size HUD & Coordinator

private final class StageBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ResizeEdgeMask: OptionSet, Equatable {
    let rawValue: Int
    static let left = ResizeEdgeMask(rawValue: 1 << 0)
    static let right = ResizeEdgeMask(rawValue: 1 << 1)
    static let top = ResizeEdgeMask(rawValue: 1 << 2)
    static let bottom = ResizeEdgeMask(rawValue: 1 << 3)
}

@MainActor
private final class StageBarEdgeResizeOverlay: NSView {
    var edgeProvider: (() -> StageBarEdge)?
    var accentColorProvider: (() -> NSColor)?
    var onResizeBegan: (() -> Void)?
    var onResizeChanged: ((CGRect) -> Void)?
    var onResizeEnded: ((CGRect) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoveredMask: ResizeEdgeMask = []
    private var dragMask: ResizeEdgeMask = []
    private var isDragging = false
    private var dragStartMouse: NSPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragVisibleFrame: CGRect = .zero
    private var dragDockEdge: StageBarEdge = .top

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return resizeMask(at: local).isEmpty ? nil : self
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        updateHover(mask: resizeMask(at: local))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDragging else { return }
        let local = convert(event.locationInWindow, from: nil)
        updateHover(mask: resizeMask(at: local))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        updateHover(mask: [])
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let mask = resizeMask(at: local)
        guard !mask.isEmpty else { return }

        isDragging = true
        dragMask = mask
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = win.frame
        dragDockEdge = edgeProvider?() ?? .top
        dragVisibleFrame = (win.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1050)
        applyCursor(for: mask)
        needsDisplay = true
        onResizeBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        let visible = dragVisibleFrame
        let m = WindowStageManager.barMargin
        let maxW = max(720, visible.width - m * 2)
        let maxH = max(420, visible.height - m * 2)

        var newW = dragStartFrame.width
        var newH = dragStartFrame.height
        var newX = dragStartFrame.origin.x
        var newY = dragStartFrame.origin.y

        if dragDockEdge.isVertical {
            if dragMask.contains(.left) && dragDockEdge == .right {
                newW = clamp(dragStartFrame.width - dx, StageBarMetrics.verticalWidthRange)
            } else if dragMask.contains(.right) && dragDockEdge == .left {
                newW = clamp(dragStartFrame.width + dx, StageBarMetrics.verticalWidthRange)
            }
            newX = dragDockEdge == .right ? (visible.maxX - newW - m) : (visible.minX + m)

            let minH = max(400, floor(maxH * (StageBarMetrics.verticalLengthPercentRange.lowerBound / 100.0)))
            if dragMask.contains(.top) {
                newH = clamp(dragStartFrame.height + dy * 2, minH...maxH)
            } else if dragMask.contains(.bottom) {
                newH = clamp(dragStartFrame.height - dy * 2, minH...maxH)
            }
            newY = floor(visible.midY - newH / 2)
        } else {
            if dragMask.contains(.bottom) && dragDockEdge == .top {
                newH = clamp(dragStartFrame.height - dy, StageBarMetrics.horizontalHeightRange)
            } else if dragMask.contains(.top) && dragDockEdge == .bottom {
                newH = clamp(dragStartFrame.height + dy, StageBarMetrics.horizontalHeightRange)
            }
            newY = dragDockEdge == .top ? (visible.maxY - newH - m) : (visible.minY + m)

            let minW = max(720, floor(maxW * (StageBarMetrics.horizontalLengthPercentRange.lowerBound / 100.0)))
            if dragMask.contains(.right) {
                newW = clamp(dragStartFrame.width + dx * 2, minW...maxW)
            } else if dragMask.contains(.left) {
                newW = clamp(dragStartFrame.width - dx * 2, minW...maxW)
            }
            newX = floor(visible.midX - newW / 2)
        }

        let targetFrame = CGRect(x: round(newX), y: round(newY), width: round(newW), height: round(newH))
        win.setFrame(targetFrame, display: true)
        applyCursor(for: dragMask)
        onResizeChanged?(targetFrame)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let win = window else { return }
        isDragging = false
        let finalFrame = win.frame
        dragMask = []
        let local = convert(event.locationInWindow, from: nil)
        let stillOver = bounds.contains(local) ? resizeMask(at: local) : []
        hoveredMask = stillOver
        if stillOver.isEmpty {
            NSCursor.arrow.set()
        } else {
            applyCursor(for: stillOver)
        }
        needsDisplay = true
        onResizeEnded?(finalFrame)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mask = isDragging ? dragMask : hoveredMask
        guard !mask.isEmpty else { return }
        let base = accentColorProvider?() ?? NSColor.controlAccentColor
        base.withAlphaComponent(isDragging ? 0.92 : 0.68).setFill()

        if mask.contains(.left) {
            let h = min(44, max(20, bounds.height * 0.22))
            let rect = NSRect(x: 2.0, y: bounds.midY - h / 2, width: 3.0, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if mask.contains(.right) {
            let h = min(44, max(20, bounds.height * 0.22))
            let rect = NSRect(x: bounds.width - 5.0, y: bounds.midY - h / 2, width: 3.0, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if mask.contains(.top) {
            let w = min(44, max(20, bounds.width * 0.36))
            let rect = NSRect(x: bounds.midX - w / 2, y: bounds.height - 5.0, width: w, height: 3.0)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if mask.contains(.bottom) {
            let w = min(44, max(20, bounds.width * 0.36))
            let rect = NSRect(x: bounds.midX - w / 2, y: 2.0, width: w, height: 3.0)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func resizeMask(at p: NSPoint) -> ResizeEdgeMask {
        let dockEdge = edgeProvider?() ?? .top
        let xBand: CGFloat = dockEdge.isVertical ? 7.5 : 9.0
        let yBand: CGFloat = dockEdge.isVertical ? 9.0 : 6.0
        let cornerBand: CGFloat = 15.0

        var mask: ResizeEdgeMask = []
        switch dockEdge {
        case .right:
            let onLeft = p.x <= xBand
            let onTop = p.y >= bounds.height - yBand
            let onBottom = p.y <= yBand
            if onLeft { mask.insert(.left) }
            if onTop { mask.insert(.top) }
            if onBottom { mask.insert(.bottom) }
            if !mask.isEmpty {
                if p.x <= cornerBand && (onTop || onBottom) { mask.insert(.left) }
                if onLeft && p.y >= bounds.height - cornerBand { mask.insert(.top) }
                if onLeft && p.y <= cornerBand { mask.insert(.bottom) }
            }
        case .left:
            let onRight = p.x >= bounds.width - xBand
            let onTop = p.y >= bounds.height - yBand
            let onBottom = p.y <= yBand
            if onRight { mask.insert(.right) }
            if onTop { mask.insert(.top) }
            if onBottom { mask.insert(.bottom) }
            if !mask.isEmpty {
                if p.x >= bounds.width - cornerBand && (onTop || onBottom) { mask.insert(.right) }
                if onRight && p.y >= bounds.height - cornerBand { mask.insert(.top) }
                if onRight && p.y <= cornerBand { mask.insert(.bottom) }
            }
        case .top:
            let onBottom = p.y <= yBand
            let onLeft = p.x <= xBand
            let onRight = p.x >= bounds.width - xBand
            if onBottom { mask.insert(.bottom) }
            if onLeft { mask.insert(.left) }
            if onRight { mask.insert(.right) }
            if !mask.isEmpty {
                if p.y <= cornerBand && (onLeft || onRight) { mask.insert(.bottom) }
                if onBottom && p.x <= cornerBand { mask.insert(.left) }
                if onBottom && p.x >= bounds.width - cornerBand { mask.insert(.right) }
            }
        case .bottom:
            let onTop = p.y >= bounds.height - yBand
            let onLeft = p.x <= xBand
            let onRight = p.x >= bounds.width - xBand
            if onTop { mask.insert(.top) }
            if onLeft { mask.insert(.left) }
            if onRight { mask.insert(.right) }
            if !mask.isEmpty {
                if p.y >= bounds.height - cornerBand && (onLeft || onRight) { mask.insert(.top) }
                if onTop && p.x <= cornerBand { mask.insert(.left) }
                if onTop && p.x >= bounds.width - cornerBand { mask.insert(.right) }
            }
        }
        return mask
    }

    private func updateHover(mask: ResizeEdgeMask) {
        guard mask != hoveredMask else {
            if !mask.isEmpty { applyCursor(for: mask) }
            return
        }
        let wasActive = !hoveredMask.isEmpty
        hoveredMask = mask
        if mask.isEmpty {
            if wasActive { NSCursor.arrow.set() }
        } else {
            applyCursor(for: mask)
        }
        needsDisplay = true
    }

    private func applyCursor(for mask: ResizeEdgeMask) {
        if #available(macOS 15.0, *) {
            if mask == [.top, .left] {
                NSCursor.frameResize(position: .topLeft, directions: .all).set()
                return
            }
            if mask == [.top, .right] {
                NSCursor.frameResize(position: .topRight, directions: .all).set()
                return
            }
            if mask == [.bottom, .left] {
                NSCursor.frameResize(position: .bottomLeft, directions: .all).set()
                return
            }
            if mask == [.bottom, .right] {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                return
            }
        }
        let hasH = mask.contains(.left) || mask.contains(.right)
        let hasV = mask.contains(.top) || mask.contains(.bottom)
        if hasH && !hasV {
            NSCursor.resizeLeftRight.set()
        } else if hasV && !hasH {
            NSCursor.resizeUpDown.set()
        } else if hasH {
            NSCursor.resizeLeftRight.set()
        }
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

private struct DockSizeHudView: View {
    @ObservedObject var model: WorkstationModel
    @ObservedObject var stage: WindowStageManager
    @ObservedObject var themeStore: WorkstationThemeStore
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var palette: WorkstationPalette { themeStore.palette(for: scheme) }
    private var isVertical: Bool { model.stageBarEdge.isVertical }

    private var verticalWidthBinding: Binding<Double> {
        Binding(
            get: { Double(stage.barMetrics.verticalWidth) },
            set: { model.setDockVerticalWidth(CGFloat($0)) }
        )
    }

    private var verticalLengthBinding: Binding<Double> {
        Binding(
            get: { Double(StageBarMetrics.savedVerticalLengthPercent()) },
            set: { model.setDockVerticalLengthPercent(CGFloat($0)) }
        )
    }

    private var horizontalHeightBinding: Binding<Double> {
        Binding(
            get: { Double(stage.barMetrics.horizontalHeight) },
            set: { model.setDockHorizontalHeight(CGFloat($0)) }
        )
    }

    private var horizontalLengthBinding: Binding<Double> {
        Binding(
            get: { Double(StageBarMetrics.savedHorizontalLengthPercent()) },
            set: { model.setDockHorizontalLengthPercent(CGFloat($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("调节悬浮栏尺寸", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                Button("重置") { model.resetDockDimensions() }
                    .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .frame(width: 22, height: 22)
                        .background(palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                ForEach(StageBarEdge.allCases) { edge in
                    let active = model.stageBarEdge == edge
                    Button { model.stageBarEdge = edge } label: {
                        HStack(spacing: 4) {
                            Image(systemName: edge.symbolName).font(.system(size: 10.5))
                            Text(edge.label).font(.system(size: 11, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(active ? palette.accentText : palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                        .background(active ? palette.accent : palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isVertical {
                hudSliderRow(
                    title: "左右栏宽度",
                    valueText: "\(Int(round(stage.barMetrics.verticalWidth))) px",
                    value: verticalWidthBinding,
                    range: Double(StageBarMetrics.verticalWidthRange.lowerBound)...Double(StageBarMetrics.verticalWidthRange.upperBound)
                )
                hudSliderRow(
                    title: "左右栏长度",
                    valueText: "\(Int(round(StageBarMetrics.savedVerticalLengthPercent())))%",
                    value: verticalLengthBinding,
                    range: Double(StageBarMetrics.verticalLengthPercentRange.lowerBound)...Double(StageBarMetrics.verticalLengthPercentRange.upperBound)
                )
            } else {
                hudSliderRow(
                    title: "上下栏高度",
                    valueText: "\(Int(round(stage.barMetrics.horizontalHeight))) px",
                    value: horizontalHeightBinding,
                    range: Double(StageBarMetrics.horizontalHeightRange.lowerBound)...Double(StageBarMetrics.horizontalHeightRange.upperBound)
                )
                hudSliderRow(
                    title: "上下栏长度",
                    valueText: "\(Int(round(StageBarMetrics.savedHorizontalLengthPercent())))%",
                    value: horizontalLengthBinding,
                    range: Double(StageBarMetrics.horizontalLengthPercentRange.lowerBound)...Double(StageBarMetrics.horizontalLengthPercentRange.upperBound)
                )
            }

            Text("提示：隐藏主窗口时，也可直接把鼠标移到悬浮栏内侧或两端边缘拖拽缩放。")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
        .background {
            ZStack {
                VisualEffectGlass(material: .hudWindow, blendingMode: .behindWindow)
                palette.sidebar.opacity(0.84)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.workstationPalette, palette)
    }

    private func hudSliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.ink)
                Spacer()
                Text(valueText).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.accent)
            }
            Slider(value: value, in: range, step: 1)
                .tint(palette.accent)
        }
    }
}

@MainActor
private final class WorkstationCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: WorkstationModel
    var mainWindow: NSWindow!
    var stageBarPanel: StageBarPanel!
    var dockSizeHudPanel: StageBarPanel?
    var statusItem: NSStatusItem!
    private var isProgrammaticBarMove = false
    private var edgeSnapTask: Task<Void, Never>?

    init(store: BridgeStore) {
        self.model = WorkstationModel(store: store)
        super.init()
    }

    func start() {
        NSApplication.shared.appearance = model.themeStore.appearance.nativeAppearance
        setupMainWindow()
        setupStageBarPanel()
        setupStatusItem()

        model.onToggleMainWindow = { [weak self] in self?.toggleMainWindow() }
        model.onShowMainWindow = { [weak self] in self?.showMainWindow() }
        model.onHideMainWindow = { [weak self] in self?.hideMainWindow() }
        model.onToggleStageBar = { [weak self] in self?.toggleStageBar() }
        model.onRaiseStageBar = { [weak self] in self?.raiseStageBar() }
        model.onStageBarEdgeChanged = { [weak self] edge in self?.animateStageBar(to: edge) }
        model.onDockGeometryChanged = { [weak self] in self?.applyLiveDockGeometry() }
        model.onToggleDockSizeHud = { [weak self] in self?.toggleDockSizeHud() }
        model.onUpdateBadge = { [weak self] count in self?.updateStatusItemTitle(count: count) }
        model.activeScreenProvider = { [weak self] in self?.currentTargetScreen }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        model.start()
        showStageBar()
        showMainWindow()
    }

    private var currentTargetScreen: NSScreen? {
        stageBarPanel?.screen ?? mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    @objc private func handleScreenParametersChanged() {
        let screen = currentTargetScreen
        model.stageManager.updateMetrics(for: screen)
        if model.isStageBarVisible {
            animateStageBar(to: model.stageBarEdge, announce: false)
        } else {
            clampMainWindowInsideCanvas(animated: true)
        }
    }

    private func setupMainWindow() {
        let canvas = model.stageManager.stageCanvasFrame(edge: model.stageBarEdge, reserveBar: true)
        let width = min(1120, max(920, canvas.width * 0.80))
        let height = min(760, max(580, canvas.height * 0.86))
        let origin = CGPoint(x: canvas.midX - width / 2, y: canvas.midY - height / 2)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "无语工作站"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 880, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BridgeView(model: model, stage: model.stageManager, themeStore: model.themeStore, codexRunner: model.codexRunner))
        self.mainWindow = window
    }

    private func setupStageBarPanel() {
        let frame = model.stageManager.stageBarFrame(edge: model.stageBarEdge)
        let panel = StageBarPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: StageBarView(model: model, stage: model.stageManager, themeStore: model.themeStore))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let resizeOverlay = StageBarEdgeResizeOverlay(frame: container.bounds)
        resizeOverlay.autoresizingMask = [.width, .height]
        resizeOverlay.edgeProvider = { [weak self] in self?.model.stageBarEdge ?? .top }
        resizeOverlay.accentColorProvider = { [weak self] in
            guard let self else { return NSColor.controlAccentColor }
            let isDark = (self.stageBarPanel?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .darkAqua) == .darkAqua
            let rgb = self.model.themeStore.effectiveRGB(for: isDark ? .dark : .light).accent
            return NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
        resizeOverlay.onResizeBegan = { [weak self] in
            guard let self else { return }
            self.edgeSnapTask?.cancel()
            self.isProgrammaticBarMove = true
        }
        resizeOverlay.onResizeChanged = { [weak self] liveFrame in
            guard let self else { return }
            self.repositionDockSizeHud(near: liveFrame)
        }
        resizeOverlay.onResizeEnded = { [weak self] finalFrame in
            guard let self else { return }
            self.model.stageManager.saveResizedBarFrame(finalFrame, edge: self.model.stageBarEdge, on: self.stageBarPanel.screen ?? self.currentTargetScreen)
            self.clampMainWindowInsideCanvas(animated: false)
            self.repositionDockSizeHud(near: finalFrame)
            self.isProgrammaticBarMove = false
        }
        container.addSubview(resizeOverlay, positioned: .above, relativeTo: hostingView)

        panel.contentView = container
        self.stageBarPanel = panel
        applyStageBarSizeLimits(for: model.stageBarEdge)
    }

    private func toggleDockSizeHud() {
        if let hud = dockSizeHudPanel, hud.isVisible {
            hud.orderOut(nil)
            return
        }
        if !model.isStageBarVisible {
            showStageBar()
        }
        let hud = dockSizeHudPanel ?? makeDockSizeHudPanel()
        repositionDockSizeHud(near: stageBarPanel.frame)
        hud.orderFrontRegardless()
    }

    private func makeDockSizeHudPanel() -> StageBarPanel {
        let panel = StageBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 222),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: DockSizeHudView(
            model: model,
            stage: model.stageManager,
            themeStore: model.themeStore,
            onClose: { [weak self] in self?.dockSizeHudPanel?.orderOut(nil) }
        ))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.dockSizeHudPanel = panel
        return panel
    }

    private func repositionDockSizeHud(near barFrame: CGRect) {
        guard let hud = dockSizeHudPanel else { return }
        let screen = stageBarPanel.screen ?? currentTargetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1050)
        if let hosting = hud.contentView {
            let fit = hosting.fittingSize
            if fit.width > 100 && fit.height > 100 {
                hud.setContentSize(fit)
            }
        }
        let hudSize = hud.frame.size
        let gap: CGFloat = 10
        var origin: CGPoint
        switch model.stageBarEdge {
        case .right:
            origin = CGPoint(x: barFrame.minX - hudSize.width - gap, y: barFrame.midY - hudSize.height / 2)
        case .left:
            origin = CGPoint(x: barFrame.maxX + gap, y: barFrame.midY - hudSize.height / 2)
        case .top:
            origin = CGPoint(x: barFrame.midX - hudSize.width / 2, y: barFrame.minY - hudSize.height - gap)
        case .bottom:
            origin = CGPoint(x: barFrame.midX - hudSize.width / 2, y: barFrame.maxY + gap)
        }
        origin.x = min(visible.maxX - hudSize.width - 8, max(visible.minX + 8, origin.x))
        origin.y = min(visible.maxY - hudSize.height - 8, max(visible.minY + 8, origin.y))
        hud.setFrameOrigin(origin)
    }

    private func applyStageBarSizeLimits(for edge: StageBarEdge) {
        let visible = (currentTargetScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1050)
        if edge.isVertical {
            stageBarPanel.minSize = NSSize(width: StageBarMetrics.verticalWidthRange.lowerBound, height: 400)
            stageBarPanel.maxSize = NSSize(width: StageBarMetrics.verticalWidthRange.upperBound, height: visible.height - 12)
        } else {
            stageBarPanel.minSize = NSSize(width: 720, height: StageBarMetrics.horizontalHeightRange.lowerBound)
            stageBarPanel.maxSize = NSSize(width: visible.width - 12, height: StageBarMetrics.horizontalHeightRange.upperBound)
        }
    }

    func applyLiveDockGeometry() {
        guard model.isStageBarVisible else { return }
        isProgrammaticBarMove = true
        let screen = currentTargetScreen
        applyStageBarSizeLimits(for: model.stageBarEdge)
        let targetFrame = model.stageManager.stageBarFrame(edge: model.stageBarEdge, on: screen)
        stageBarPanel.setFrame(targetFrame, display: true)
        clampMainWindowInsideCanvas(animated: false)
        if dockSizeHudPanel?.isVisible == true {
            repositionDockSizeHud(near: targetFrame)
        }
        isProgrammaticBarMove = false
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "无语工作站") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "无语"
            }
            button.imagePosition = .imageLeading
        }
        item.menu = buildStatusMenu()
        self.statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(menu, "展开 / 隐藏工作台面板", #selector(toggleMainWindowAction), key: "\\")
        addItem(menu, "显示 / 收起悬浮切换栏", #selector(toggleStageBarAction), key: "")

        let dockItem = NSMenuItem(title: "悬浮栏停靠方向", action: nil, keyEquivalent: "")
        let dockMenu = NSMenu(title: "悬浮栏停靠方向")
        addItem(dockMenu, "顶部", #selector(dockTop), key: "")
        addItem(dockMenu, "底部", #selector(dockBottom), key: "")
        addItem(dockMenu, "左侧", #selector(dockLeft), key: "")
        addItem(dockMenu, "右侧", #selector(dockRight), key: "")
        dockMenu.addItem(.separator())
        addItem(dockMenu, "悬浮滑块调节宽/长…", #selector(toggleDockSizeHudAction), key: "")
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)

        menu.addItem(.separator())
        addItem(menu, "切到 Codex", #selector(focusCodex), key: "1")
        addItem(menu, "切到 Antigravity", #selector(focusAntigravity), key: "2")
        addItem(menu, "切到 Gemini", #selector(focusGemini), key: "3")
        addItem(menu, "切到 Claude", #selector(focusClaude), key: "4")
        menu.addItem(.separator())
        addItem(menu, "双拼：Codex | Antigravity", #selector(splitCodexAGY), key: "")
        addItem(menu, "双拼：Codex | Gemini", #selector(splitCodexGemini), key: "")
        addItem(menu, "三端 1+2：Codex + AGY + Gemini", #selector(splitThreeAGYGem), key: "")
        menu.addItem(.separator())
        addItem(menu, "新建协作 / Workflow…", #selector(newWorkflowAction), key: "n")
        addItem(menu, "设置与配色…", #selector(showSettingsAction), key: ",")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出无语工作站", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func updateStatusItemTitle(count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    func showStageBar() {
        isProgrammaticBarMove = true
        let screen = currentTargetScreen
        let targetFrame = model.stageManager.stageBarFrame(edge: model.stageBarEdge, on: screen)
        stageBarPanel.setFrame(targetFrame, display: true)
        stageBarPanel.alphaValue = 0
        stageBarPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            stageBarPanel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.isProgrammaticBarMove = false }
        }
        model.isStageBarVisible = true
        clampMainWindowInsideCanvas(animated: true)
    }

    func animateStageBar(to edge: StageBarEdge, announce: Bool = true) {
        guard model.isStageBarVisible else { return }
        isProgrammaticBarMove = true
        let screen = currentTargetScreen
        applyStageBarSizeLimits(for: edge)
        let targetFrame = model.stageManager.stageBarFrame(edge: edge, on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            stageBarPanel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.isProgrammaticBarMove = false }
        }
        stageBarPanel.orderFrontRegardless()
        if dockSizeHudPanel?.isVisible == true {
            repositionDockSizeHud(near: targetFrame)
        }
        clampMainWindowInsideCanvas(animated: true)
        if announce {
            model.showBanner("悬浮栏已停靠到屏幕\(edge.label)")
        }
    }

    func raiseStageBar() {
        guard model.isStageBarVisible else { return }
        stageBarPanel.orderFrontRegardless()
    }

    func toggleStageBar() {
        if model.isStageBarVisible {
            dockSizeHudPanel?.orderOut(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stageBarPanel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.stageBarPanel.orderOut(nil)
                    self?.stageBarPanel.alphaValue = 1
                }
            }
            model.isStageBarVisible = false
        } else {
            showStageBar()
        }
    }

    func showMainWindow() {
        clampMainWindowInsideCanvas(animated: false, onlyIfVisible: false)
        if !mainWindow.isVisible {
            mainWindow.alphaValue = 0
            mainWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                mainWindow.animator().alphaValue = 1
            }
        } else {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        }
        model.isMainWindowVisible = true
        raiseStageBar()
    }

    private func clampMainWindowInsideCanvas(animated: Bool, onlyIfVisible: Bool = true) {
        guard model.isStageBarVisible, (!onlyIfVisible || mainWindow.isVisible) else { return }
        let canvas = model.stageManager.stageCanvasFrame(edge: model.stageBarEdge, on: currentTargetScreen, reserveBar: true)
        var frame = mainWindow.frame
        var changed = false

        if frame.width > canvas.width { frame.size.width = canvas.width; changed = true }
        if frame.height > canvas.height { frame.size.height = canvas.height; changed = true }
        if frame.maxY > canvas.maxY { frame.origin.y = canvas.maxY - frame.size.height; changed = true }
        if frame.minY < canvas.minY { frame.origin.y = canvas.minY; changed = true }
        if frame.minX < canvas.minX { frame.origin.x = canvas.minX; changed = true }
        if frame.maxX > canvas.maxX { frame.origin.x = canvas.maxX - frame.size.width; changed = true }

        guard changed else { return }
        if animated && mainWindow.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                mainWindow.animator().setFrame(frame, display: true)
            }
        } else {
            mainWindow.setFrame(frame, display: true)
        }
    }

    func hideMainWindow() {
        guard mainWindow.isVisible else {
            model.isMainWindowVisible = false
            return
        }
        model.isMainWindowVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            mainWindow.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.model.isMainWindowVisible else { return }
                self.mainWindow.orderOut(nil)
                self.mainWindow.alphaValue = 1
            }
        }
    }

    func toggleMainWindow() {
        if mainWindow.isVisible && model.isMainWindowVisible { hideMainWindow() } else { showMainWindow() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == stageBarPanel || win == mainWindow else { return }
        let targetScreen = win.screen ?? currentTargetScreen
        model.stageManager.updateMetrics(for: targetScreen)
        if model.isStageBarVisible, win == mainWindow {
            animateStageBar(to: model.stageBarEdge, announce: false)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == stageBarPanel, !isProgrammaticBarMove else { return }
        model.stageManager.saveResizedBarFrame(win.frame, edge: model.stageBarEdge, on: win.screen ?? currentTargetScreen)
        animateStageBar(to: model.stageBarEdge, announce: false)
    }

    func windowDidMove(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == stageBarPanel, !isProgrammaticBarMove else { return }
        edgeSnapTask?.cancel()
        edgeSnapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled, !self.isProgrammaticBarMove else { return }
            if let snapped = self.model.stageManager.detectSnapEdge(
                for: self.stageBarPanel.frame,
                on: self.stageBarPanel.screen,
                currentEdge: self.model.stageBarEdge
            ) {
                self.model.stageBarEdge = snapped
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow { hideMainWindow(); return false }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStageBar()
        showMainWindow()
        return true
    }

    @objc func toggleMainWindowAction() { toggleMainWindow() }
    @objc func toggleStageBarAction() { toggleStageBar() }
    @objc func toggleDockSizeHudAction() { toggleDockSizeHud() }
    @objc func dockTop() { model.stageBarEdge = .top }
    @objc func dockBottom() { model.stageBarEdge = .bottom }
    @objc func dockLeft() { model.stageBarEdge = .left }
    @objc func dockRight() { model.stageBarEdge = .right }
    @objc func focusCodex() { model.focusTab(.codex) }
    @objc func focusAntigravity() { model.focusTab(.antigravity) }
    @objc func focusGemini() { model.focusTab(.gemini) }
    @objc func focusClaude() { model.focusTab(.claude) }
    @objc func splitCodexAGY() { model.applySplit(.codex, .antigravity) }
    @objc func splitCodexGemini() { model.applySplit(.codex, .gemini) }
    @objc func splitThreeAGYGem() { model.applyThreeSplit(.codex, .antigravity, .gemini) }
    @objc func newWorkflowAction() { model.openCompose(.implementReviewFix) }
    @objc func showSettingsAction() { model.openSettings() }
}

@MainActor
private func makeBridgeMenu(coordinator: WorkstationCoordinator) -> NSMenu {
    let menu = NSMenu()
    let appItem = NSMenuItem(title: "无语工作站", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "无语工作站")
    let settings = NSMenuItem(title: "设置与配色…", action: #selector(WorkstationCoordinator.showSettingsAction), keyEquivalent: ",")
    settings.target = coordinator
    appMenu.addItem(settings)
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出无语工作站", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    menu.addItem(editItem)

    let stageItem = NSMenuItem(title: "调度", action: nil, keyEquivalent: "")
    let stageMenu = NSMenu(title: "调度")
    let togglePanel = NSMenuItem(title: "展开 / 隐藏工作台", action: #selector(WorkstationCoordinator.toggleMainWindowAction), keyEquivalent: "\\")
    togglePanel.target = coordinator
    stageMenu.addItem(togglePanel)
    let c1 = NSMenuItem(title: "切到 Codex", action: #selector(WorkstationCoordinator.focusCodex), keyEquivalent: "1"); c1.target = coordinator; stageMenu.addItem(c1)
    let c2 = NSMenuItem(title: "切到 Antigravity", action: #selector(WorkstationCoordinator.focusAntigravity), keyEquivalent: "2"); c2.target = coordinator; stageMenu.addItem(c2)
    let c3 = NSMenuItem(title: "切到 Gemini", action: #selector(WorkstationCoordinator.focusGemini), keyEquivalent: "3"); c3.target = coordinator; stageMenu.addItem(c3)
    let c4 = NSMenuItem(title: "切到 Claude", action: #selector(WorkstationCoordinator.focusClaude), keyEquivalent: "4"); c4.target = coordinator; stageMenu.addItem(c4)
    stageItem.submenu = stageMenu
    menu.addItem(stageItem)

    let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)

    return menu
}

@MainActor
func runBridgeUI(store: BridgeStore) {
    let app = NSApplication.shared
    let coordinator = WorkstationCoordinator(store: store)
    app.delegate = coordinator
    app.setActivationPolicy(.regular)
    app.mainMenu = makeBridgeMenu(coordinator: coordinator)
    coordinator.start()
    withExtendedLifetime(coordinator) {
        app.run()
    }
}
