import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var themeStore: WorkstationThemeStore
    @ObservedObject var stageManager: WindowStageManager
    @Binding var stageBarEdge: StageBarEdge
    var onDockGeometryChanged: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.workstationPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    @AppStorage("workstation.codexReasoningEffort") private var codexEffort = "medium"
    @AppStorage("workstation.codexProxyURL") private var codexProxyURL = ""
    @AppStorage(StageBarMetrics.verticalWidthKey) private var dockVerticalWidth: Double = 88
    @AppStorage(StageBarMetrics.verticalLengthPercentKey) private var dockVerticalLengthPercent: Double = 76
    @AppStorage(StageBarMetrics.horizontalHeightKey) private var dockHorizontalHeight: Double = 46
    @AppStorage(StageBarMetrics.horizontalLengthPercentKey) private var dockHorizontalLengthPercent: Double = 98
    @State private var appPaths: [Client: String] = [:]
    @State private var mcpStatus: MCPHealthStatus = .inspect()
    @State private var bgHexInput = ""
    @State private var fgHexInput = ""
    @State private var accentHexInput = ""

    private var fontSlider: Binding<Double> {
        Binding(
            get: { Double(themeStore.fontPercent) },
            set: { themeStore.fontPercent = Int($0.rounded()) }
        )
    }

    private var currentRGB: (bg: RGBColor, fg: RGBColor, accent: RGBColor, isDark: Bool) {
        themeStore.effectiveRGB(for: scheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceSection
                    themeSection
                    accessibilitySection
                    clientBindingsSection
                    mcpAndUpdateSection
                }
                .padding(22)
            }

            divider
            HStack {
                Text("配色与设置即时生效并保存在本机")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.quiet)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WorkstationButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
        }
        .frame(width: 620, height: 680)
        .foregroundStyle(palette.ink)
        .background(palette.canvas)
        .tint(palette.accent)
        .environment(\.workstationTextScale, 1)
        .onAppear {
            loadCurrentPaths()
            syncHexInputs()
            syncDockSliders()
            stageManager.refreshStatus()
            mcpStatus = .inspect()
        }
        .onChange(of: themeStore.preset) { syncHexInputs() }
        .onChange(of: themeStore.appearance) { syncHexInputs() }
        .onChange(of: themeStore.customBackgroundHex) { syncHexInputs() }
        .onChange(of: themeStore.customForegroundHex) { syncHexInputs() }
        .onChange(of: themeStore.customAccentHex) { syncHexInputs() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .background(palette.accentWash, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("工作站设置")
                    .font(.system(size: 17, weight: .semibold))
                Text("多套配色主题、自定义色值、窗口分屏权限与客户端绑定")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle().fill(palette.line).frame(height: 1)
    }

    // MARK: - Appearance Card (Antigravity-style grouped rows)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance · 外观与排版")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)

            VStack(spacing: 0) {
                settingRow("外观模式") {
                    Picker("外观模式", selection: $themeStore.appearance) {
                        ForEach(WorkstationAppearance.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                divider.padding(.horizontal, 14)

                settingRow("对比度") {
                    Picker("对比度", selection: $themeStore.contrast) {
                        ForEach(WorkstationContrast.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                divider.padding(.horizontal, 14)

                settingRow("悬浮切换栏停靠位置") {
                    Picker("停靠位置", selection: $stageBarEdge) {
                        ForEach(StageBarEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                divider.padding(.horizontal, 14)

                if stageBarEdge.isVertical {
                    settingRow("左右悬浮栏宽度（\(Int(dockVerticalWidth.rounded()))px）") {
                        HStack(spacing: 8) {
                            Slider(value: $dockVerticalWidth, in: 56...180, step: 2)
                                .frame(width: 175)
                                .onChange(of: dockVerticalWidth) { onDockGeometryChanged?() }
                            Button("重置") {
                                stageManager.resetBarDimensions()
                                syncDockSliders()
                                onDockGeometryChanged?()
                            }
                            .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                        }
                    }

                    divider.padding(.horizontal, 14)

                    settingRow("左右悬浮栏长度（\(Int(dockVerticalLengthPercent.rounded()))% 屏高）") {
                        Slider(value: $dockVerticalLengthPercent, in: 45...100, step: 1)
                            .frame(width: 225)
                            .onChange(of: dockVerticalLengthPercent) { onDockGeometryChanged?() }
                    }
                } else {
                    settingRow("顶底悬浮栏长度（\(Int(dockHorizontalLengthPercent.rounded()))% 屏宽）") {
                        HStack(spacing: 8) {
                            Slider(value: $dockHorizontalLengthPercent, in: 55...100, step: 1)
                                .frame(width: 175)
                                .onChange(of: dockHorizontalLengthPercent) { onDockGeometryChanged?() }
                            Button("重置") {
                                stageManager.resetBarDimensions()
                                syncDockSliders()
                                onDockGeometryChanged?()
                            }
                            .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                        }
                    }

                    divider.padding(.horizontal, 14)

                    settingRow("顶底悬浮栏高度（\(Int(dockHorizontalHeight.rounded()))px）") {
                        Slider(value: $dockHorizontalHeight, in: 40...64, step: 1)
                            .frame(width: 225)
                            .onChange(of: dockHorizontalHeight) { onDockGeometryChanged?() }
                    }
                }

                divider.padding(.horizontal, 14)

                settingRow("界面字号（\(themeStore.fontPercent)%）") {
                    HStack(spacing: 8) {
                        Text("A").font(.system(size: 10.5)).foregroundStyle(palette.quiet)
                        Slider(
                            value: fontSlider,
                            in: Double(WorkstationTextSize.range.lowerBound)...Double(WorkstationTextSize.range.upperBound),
                            step: Double(WorkstationTextSize.step)
                        )
                        .frame(width: 165)
                        Text("A").font(.system(size: 15)).foregroundStyle(palette.quiet)
                    }
                }
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line) }
        }
    }

    // MARK: - Multi-Theme Studio Card (Matches Antigravity's Theme Picker!)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Theme · 主题配色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                if themeStore.hasCustomOverrides {
                    Button("恢复预设默认") {
                        themeStore.clearCustomOverrides()
                    }
                    .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                }
            }

            VStack(spacing: 0) {
                settingRow("Preset · 配色预设") {
                    Picker("配色预设", selection: Binding(
                        get: { themeStore.preset },
                        set: { themeStore.selectPreset($0) }
                    )) {
                        ForEach(WorkstationThemePreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 195)
                }

                divider.padding(.horizontal, 14)

                // 3-column wide swatch grid so long preset names (Gruvbox Material / Tokyo Night / One Dark Pro) never truncate
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(WorkstationThemePreset.allCases) { preset in
                        presetSwatchTile(preset)
                    }
                }
                .padding(14)

                divider.padding(.horizontal, 14)

                colorOverrideRow(
                    title: "Background",
                    rgb: currentRGB.bg,
                    hexText: $bgHexInput,
                    onApplyHex: { themeStore.customBackgroundHex = $0 }
                )

                divider.padding(.horizontal, 14)

                colorOverrideRow(
                    title: "Foreground",
                    rgb: currentRGB.fg,
                    hexText: $fgHexInput,
                    onApplyHex: { themeStore.customForegroundHex = $0 }
                )

                divider.padding(.horizontal, 14)

                colorOverrideRow(
                    title: "Accent",
                    rgb: currentRGB.accent,
                    hexText: $accentHexInput,
                    onApplyHex: { themeStore.customAccentHex = $0 }
                )
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line) }
        }
    }

    private func presetSwatchTile(_ preset: WorkstationThemePreset) -> some View {
        let triplet = preset.triplet(dark: currentRGB.isDark)
        let active = themeStore.preset == preset && !themeStore.hasCustomOverrides
        return Button {
            themeStore.selectPreset(preset)
        } label: {
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    Circle().fill(RGBColor(hex: triplet.background).color).frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(palette.line, lineWidth: 0.8) }
                    Circle().fill(RGBColor(hex: triplet.foreground).color).frame(width: 10, height: 10)
                    Circle().fill(RGBColor(hex: triplet.accent).color).frame(width: 10, height: 10)
                }
                .fixedSize()
                Text(preset.label)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? palette.accent : palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(active ? palette.accentWash : palette.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? palette.accent : palette.line, lineWidth: active ? 1.3 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func colorOverrideRow(
        title: String,
        rgb: RGBColor,
        hexText: Binding<String>,
        onApplyHex: @escaping (String) -> Void
    ) -> some View {
        settingRow(title) {
            HStack(spacing: 10) {
                // Crisp 18x18 rounded-square swatch backed by a full hit-target native ColorPicker
                RoundedRectangle(cornerRadius: 5)
                    .fill(rgb.color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(palette.ink.opacity(0.22), lineWidth: 1)
                    }
                    .overlay {
                        ColorPicker("", selection: Binding(
                            get: { rgb.color },
                            set: { newColor in
                                let ns = NSColor(newColor)
                                let hex = RGBColor(nsColor: ns).hexString
                                hexText.wrappedValue = hex
                                onApplyHex(hex)
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .opacity(0.02)
                        .frame(width: 24, height: 24)
                        .clipped()
                    }
                    .help("点击打开系统取色器")

                TextField("#RRGGBB", text: hexText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.ink)
                    .frame(width: 72, alignment: .leading)
                    .onSubmit {
                        if let parsed = RGBColor(hexString: hexText.wrappedValue) {
                            hexText.wrappedValue = parsed.hexString
                            onApplyHex(parsed.hexString)
                        } else {
                            hexText.wrappedValue = rgb.hexString
                        }
                    }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(palette.field, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.line) }
        }
    }

    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.ink)
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Accessibility & Stage

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("窗口编排与一键分屏权限")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Label(
                    stageManager.isAccessibilityTrusted ? "已授权" : "未授权",
                    systemImage: stageManager.isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(stageManager.isAccessibilityTrusted ? palette.success : palette.warning)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("在「系统设置 → 隐私与安全性 → 设备控制和数据访问（辅助功能）」中授权本应用。如列表中已有旧的「无语工作站」，先点「−」删除，再把 Finder 中的 ~/Applications/无语工作站.app 拖入列表。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.muted)
                HStack(spacing: 8) {
                    Button("打开系统设置") { stageManager.requestAccessibilityPermission() }
                        .buttonStyle(WorkstationButtonStyle(.primary, compact: true))
                    Button("Finder 定位应用") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .buttonStyle(WorkstationButtonStyle(.secondary, compact: true))
                    Button("重新检测") { stageManager.refreshStatus() }
                        .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                }
            }
            .padding(13)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line) }
        }
    }

    // MARK: - Client Bindings

    private var clientBindingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("四个桌面客户端路径绑定")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)

            VStack(spacing: 6) {
                ForEach(Client.allCases) { client in
                    let candidates = client.candidateAppURLs()
                    let currentPath = appPaths[client] ?? client.resolvedAppURL()?.path ?? "未找到"
                    HStack(spacing: 10) {
                        ClientGlyph(client: client, size: 15)
                            .foregroundStyle(palette.clientColor(client))
                            .frame(width: 26, height: 26)
                            .background(palette.clientWash(client), in: RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.label).font(.system(size: 12.5, weight: .semibold))
                            Text(currentPath).font(.system(size: 10.5)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()

                        if candidates.count > 1 {
                            Menu("切换") {
                                ForEach(candidates, id: \.path) { url in
                                    Button(url.lastPathComponent) { saveCustomPath(url.path, for: client) }
                                }
                                Divider()
                                Button("浏览其他 .app…") { pickApp(for: client) }
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 56)
                        } else {
                            Button("选择…") { pickApp(for: client) }
                                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line) }
                }
            }
        }
    }

    // MARK: - MCP & Update Info

    private var mcpAndUpdateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MCP 集成与本地更新目录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Button("打开源码目录") {
                    let src = Bundle.main.object(forInfoDictionaryKey: "WuyuSourceDir") as? String
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/scratch/wuyu-workstation").path
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: src)
                }
                .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
                Button("刷新检测") { mcpStatus = .inspect() }
                    .buttonStyle(WorkstationButtonStyle(.quiet, compact: true))
            }
            VStack(alignment: .leading, spacing: 7) {
                statusRow("Antigravity 挂载无语黑板 MCP（wuyu-workstation）", ok: mcpStatus.antigravityHasWuyu)
                statusRow("Antigravity 直连官方 Codex MCP（codex mcp-server）", ok: mcpStatus.antigravityHasCodex)
                statusRow("Codex 挂载无语黑板 MCP（wuyu-workstation）", ok: mcpStatus.codexHasWuyu)
                divider.padding(.vertical, 2)
                HStack(spacing: 10) {
                    Text("直跑 Codex 推理强度")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Picker("推理强度", selection: $codexEffort) {
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                        Text("xhigh").tag("xhigh")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                HStack(spacing: 10) {
                    Text("Codex 代理（留空自动读系统代理）")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    TextField("例如 http://127.0.0.1:7890", text: $codexProxyURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .frame(width: 220)
                        .background(palette.field, in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line) }
                }
                divider.padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark").font(.system(size: 11)).foregroundStyle(palette.quiet)
                    Text("当前应用：\(Bundle.main.bundleURL.path)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.quiet)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line) }
        }
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? palette.success : palette.quiet)
                .font(.system(size: 12))
            Text(title).font(.system(size: 11.5)).foregroundStyle(ok ? palette.ink : palette.muted)
            Spacer()
            Text(ok ? "已就绪" : "未配置")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ok ? palette.success : palette.quiet)
        }
    }

    private func syncDockSliders() {
        let m = StageBarMetrics.forScreen(NSScreen.main)
        dockVerticalWidth = Double(m.verticalWidth)
        dockVerticalLengthPercent = Double(StageBarMetrics.savedVerticalLengthPercent())
        dockHorizontalHeight = Double(m.horizontalHeight)
        dockHorizontalLengthPercent = Double(StageBarMetrics.savedHorizontalLengthPercent())
    }

    private func syncHexInputs() {
        let rgb = currentRGB
        bgHexInput = rgb.bg.hexString
        fgHexInput = rgb.fg.hexString
        accentHexInput = rgb.accent.hexString
    }

    private func loadCurrentPaths() {
        var map: [Client: String] = [:]
        for c in Client.allCases { map[c] = c.resolvedAppURL()?.path ?? "未检测到" }
        appPaths = map
    }

    private func saveCustomPath(_ path: String, for client: Client) {
        UserDefaults.standard.set(path, forKey: client.customAppPathKey)
        appPaths[client] = path
        stageManager.refreshStatus()
    }

    private func pickApp(for client: Client) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "绑定 \(client.label)"
        if panel.runModal() == .OK, let url = panel.url { saveCustomPath(url.path, for: client) }
    }
}

struct MCPHealthStatus {
    let antigravityHasWuyu: Bool
    let antigravityHasCodex: Bool
    let codexHasWuyu: Bool

    static func inspect() -> MCPHealthStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agyConfigURL = home.appendingPathComponent(".gemini/config/mcp_config.json")
        var agyWuyu = false
        var agyCodex = false
        if let data = try? Data(contentsOf: agyConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            agyWuyu = servers["wuyu-workstation"] != nil
            agyCodex = servers["codex"] != nil
        }

        let codexConfigURL = home.appendingPathComponent(".codex/config.toml")
        var codexWuyu = false
        if let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) {
            codexWuyu = text.contains("mcp_servers.wuyu-workstation")
                || text.contains("mcp_servers.\"wuyu-workstation\"")
                || text.contains("[mcp_servers.wuyu_workstation]")
        }
        return MCPHealthStatus(antigravityHasWuyu: agyWuyu, antigravityHasCodex: agyCodex, codexHasWuyu: codexWuyu)
    }
}
