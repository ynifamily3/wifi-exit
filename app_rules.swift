import AppKit
import Foundation
import NetworkExtension
import Security
import SwiftUI
import SystemExtensions
import UniformTypeIdentifiers

let appProxyID = "com.miel.WifiExit.AppRules.proxy"

enum SplitControl {
    static func manager() async throws -> NETransparentProxyManager? {
        let values: [NETransparentProxyManager] = try await withCheckedThrowingContinuation { continuation in
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: managers ?? []) }
            }
        }
        return values.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == appProxyID }
    }
    static func save(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }
    static func message(_ data: Data, manager: NETransparentProxyManager) async throws -> Data? {
        guard let session = manager.connection as? NETunnelProviderSession else { throw relayHostError("프록시 세션 없음") }
        return try await withCheckedThrowingContinuation { c in
            do { try session.sendProviderMessage(data) { response in c.resume(returning: response) } }
            catch { c.resume(throwing: error) }
        }
    }
    static func currentConfig(_ fallback: SplitConfig, manager: NETransparentProxyManager?) async throws -> SplitConfig {
        var result = fallback
        if let data = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? Data,
           let saved = try? JSONDecoder().decode(SplitConfig.self, from: data), saved.problem == nil,
           (saved.revision ?? 0) >= (result.revision ?? 0) { result = saved }
        if let manager, manager.connection.status == .connected,
           let data = try await message(Data("status".utf8), manager: manager),
           let report = try? JSONDecoder().decode(SplitReport.self, from: data), let live = report.configuration,
           live.problem == nil, (live.revision ?? 0) >= (result.revision ?? 0) { result = live }
        return result
    }
    @discardableResult
    static func store(_ requested: SplitConfig, enable: Bool = false) async throws -> SplitConfig {
        var config = requested
        if config.configurationID == nil { config.configurationID = UUID().uuidString }
        config.revision = max((config.revision ?? 0) + 1, Int(Date().timeIntervalSince1970 * 1000))
        if let error = config.problem { throw relayHostError(error) }
        let existing = try await manager()
        guard existing != nil || enable else { return config }
        let manager = existing ?? NETransparentProxyManager()
        if !enable, manager.connection.status == .connected {
            // Updating VPN preferences restarts the transparent proxy. Apply and persist
            // inside the provider instead, so new connections never bypass it during an edit.
            let result = try await message(try JSONEncoder().encode(config), manager: manager)
            guard result == Data("ok".utf8) else { throw relayHostError("확장이 새 규칙을 적용·저장하지 못했어요") }
            return config
        }
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = appProxyID
        protocolConfig.serverAddress = "Wi-Fi Exit 앱별 스플리팅"
        protocolConfig.providerConfiguration = ["config": try JSONEncoder().encode(config)]
        manager.protocolConfiguration = protocolConfig
        manager.localizedDescription = "Wi-Fi Exit 앱별 스플리팅"
        // A turned-on proxy that is merely disconnected (e.g. after a reboot, app update or a
        // save while it was down) must come back too, otherwise every rule silently stops applying.
        let on = enable || manager.isEnabled
        if on { keepConnected(manager) }
        try await save(manager)
        if on { try manager.connection.startVPNTunnel() }
        return config
    }
    /// Turned-on proxy reconnects by itself: on demand covers reboots and system-initiated stops.
    static func keepConnected(_ manager: NETransparentProxyManager) {
        manager.isEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]
        manager.isOnDemandEnabled = true
    }
    /// Repairs a turned-on proxy left disconnected or saved before on-demand existed.
    static func ensureRunning(_ manager: NETransparentProxyManager) async throws {
        guard manager.isEnabled else { return }
        if !manager.isOnDemandEnabled { keepConnected(manager); try await save(manager) }
        if manager.connection.status == .disconnected || manager.connection.status == .invalid {
            try manager.connection.startVPNTunnel()
        }
    }
    static func disable(remove: Bool = false) async throws {
        guard let manager = try await manager() else { return }
        let latest = try await currentConfig(SplitConfig(), manager: manager)
        if remove, manager.connection.status == .connected { _ = try await message(Data("clear".utf8), manager: manager) }
        // Turn on-demand off first, or the system reconnects the proxy right after the stop.
        if let protocolConfig = manager.protocolConfiguration as? NETunnelProviderProtocol, !remove {
            protocolConfig.providerConfiguration = ["config": try JSONEncoder().encode(latest)]
            manager.protocolConfiguration = protocolConfig
        }
        manager.isOnDemandEnabled = false
        manager.isEnabled = false; try await save(manager)
        manager.connection.stopVPNTunnel()
        if remove {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.removeFromPreferences { error in if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        }
    }
    static func installed() -> String {
        let result = sh("/usr/bin/systemextensionsctl", ["list"])
        let lines = result.out.split(separator: "\n").filter { $0.contains(appProxyID) }
        if lines.contains(where: { $0.contains("[activated enabled]") }) { return "허용됨" }
        if lines.contains(where: { $0.contains("waiting for user") }) { return "시스템 설정에서 허용 필요" }
        return "등록 안 됨"
    }
    static func selectedApp(_ url: URL) throws -> SplitRule { try SplitIdentity.selectedApp(url) }

}
func relayHostError(_ text: String) -> NSError { NSError(domain: "WiFiExit.AppRules", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

final class SplitExtensionRequest: NSObject, OSSystemExtensionRequestDelegate {
    static var live: [SplitExtensionRequest] = []
    let update: (String) -> Void
    let done: (Bool, String?) -> Void
    init(activate: Bool, update: @escaping (String) -> Void, done: @escaping (Bool, String?) -> Void) {
        self.update = update; self.done = done; super.init()
        let request = activate ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: appProxyID, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: appProxyID, queue: .main)
        request.delegate = self; Self.live.append(self); OSSystemExtensionManager.shared.submitRequest(request)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        update("시스템 설정 → 일반 → 로그인 항목 및 확장 → 네트워크 확장에서 Wi-Fi Exit를 허용해 주세요")
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        finish(result == .completed, result == .completed ? nil : "재부팅 후 확장이 적용돼요. 이후 다시 켜 주세요")
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { finish(false, "\(error.localizedDescription) (\((error as NSError).domain):\((error as NSError).code))") }
    private func finish(_ ready: Bool, _ note: String?) { done(ready, note); Self.live.removeAll { $0 === self } }
}

@MainActor
final class SplitModel: ObservableObject {
    @Published var config: SplitConfig
    @Published var enabled = false
    @Published var connected = false
    @Published var extensionState = "확인 중"
    @Published var report = SplitReport()
    @Published var note: String?
    @Published var busy = false
    private let defaults = UserDefaults.standard
    init() {
        config = defaults.data(forKey: "appSplitConfig").flatMap { try? JSONDecoder().decode(SplitConfig.self, from: $0) } ?? SplitConfig()
    }
    func refresh() async {
        guard !busy else { return }
        extensionState = await background { SplitControl.installed() }
        do {
            let manager = try await SplitControl.manager()
            if let manager { try await SplitControl.ensureRunning(manager) }
            enabled = manager?.isEnabled == true; connected = manager?.connection.status == .connected
            config = try await SplitControl.currentConfig(config, manager: manager)
            if connected, let manager, let data = try await SplitControl.message(Data("status".utf8), manager: manager),
               let value = try? JSONDecoder().decode(SplitReport.self, from: data) { report = value }

        } catch { note = "상태 확인 실패: \(error.localizedDescription)" }
    }
    func save(_ new: SplitConfig) async {
        guard !busy else { return }; busy = true; note = nil
        do {
            let saved = try await SplitControl.store(new)
            config = saved; defaults.set(try JSONEncoder().encode(saved), forKey: "appSplitConfig")
        } catch { note = "저장 실패: \(error.localizedDescription)" }
        busy = false; await refresh()
    }
    func turnOn() {
        guard !busy else { return }
        guard config.rules.contains(where: \.enabled) || config.others?.enabled == true else { note = "먼저 앱 규칙을 추가해 주세요"; return }
        if SplitPolicy.requiresEngineMigration(config: FileManager.default.contents(atPath: Paths.config), status: FileManager.default.contents(atPath: Paths.status)) { note = "메뉴에서 엔진 갱신을 먼저 실행해 주세요. 이전 버전의 라우트를 정리해야 해요"; return }
        busy = true; note = nil
        _ = SplitExtensionRequest(activate: true, update: { [weak self] text in self?.note = text }) { [weak self] ready, message in
            guard let self else { return }
            if !ready { self.note = message; self.busy = false; return }
            Task {
                do {
                    self.config = try await SplitControl.store(self.config, enable: true)
                    self.defaults.set(try JSONEncoder().encode(self.config), forKey: "appSplitConfig")
                }
                catch { self.note = "켜기 실패: \(error.localizedDescription)" }
                self.busy = false; await self.refresh()
            }
        }
    }
    func turnOff(remove: Bool = false) async {
        guard !busy else { return }; busy = true; note = nil
        do {
            try await SplitControl.disable(remove: remove)
            if remove {
                _ = SplitExtensionRequest(activate: false, update: { [weak self] text in self?.note = text }) { [weak self] _, message in
                    self?.note = message ?? "확장 제거를 요청했어요"; self?.busy = false
                }
            }
        } catch { note = error.localizedDescription }
        if !remove || note != nil { busy = false }
        await refresh()
    }
}

/// 앱별 스플리팅 창. 규칙 창과 같은 모양: 왼쪽 목록(앱 · 위에서부터, 규칙 없는 앱), 오른쪽 그룹 폼.
/// 켜기·끄기와 앱 추가는 도구 막대에, 확장·중계 상태는 창 부제목에 둔다.
/// 목록은 Little Snitch 의 규칙 목록처럼 실제 앱 아이콘과 켜기 상자를 보여 준다.
struct AppRulesView: View {
    @StateObject private var model = SplitModel()
    @State private var selection: String?
    @State private var draft: SplitRule?
    @State private var newRule = false
    @State private var confirmRemove = false
    private static let othersTag = "others"
    private var candidates: [String] {
        var result = ["wifi", "wired", "tether", "vpn:any"]
        for e in model.report.exits where !result.contains(e.selector) { result.append(e.selector) }
        for e in readStatus()?.exits ?? [] where e.name == "vpn" && !e.portal.isEmpty {
            let selector = "vpn:" + e.portal; if !result.contains(selector) { result.append(selector) }
        }
        return result
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("앱 · 위에서부터") {
                    ForEach(model.config.rules) { rule in
                        AppRuleListItem(rule: rule) { on in
                            var next = model.config
                            if let i = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[i].enabled = on }
                            Task { await model.save(next) }
                        }
                        .tag(rule.id)
                    }
                    .onMove { from, to in var next = model.config; next.rules.move(fromOffsets: from, toOffset: to); Task { await model.save(next) } }
                    if model.config.rules.isEmpty {
                        Text("없음 — + 로 앱을 추가하세요").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("규칙 없는 앱") {
                    let others = model.config.others ?? OthersPolicy()
                    HStack(spacing: 9) {
                        Image(systemName: "square.dashed").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("나머지 앱")
                            Text(others.enabled ? "VPN이 켜져 있으면 \(Exits.label(others.exits.first ?? "wifi"))로" : "평소 경로")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Self.othersTag)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .disabled(model.busy)
        } detail: {
            VStack(spacing: 0) {
                if let note = model.note { noteBand(note) }
                Group {
                    if selection == Self.othersTag { othersForm }
                    else if draft != nil { editor }
                    else {
                        ContentUnavailableView("앱을 고르세요", systemImage: "app.badge",
                                               description: Text("+ 로 앱 추가"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(detailTitle)
            .navigationSubtitle(statusLine)
            .toolbar {
                // Little Snitch 의 필터 빠른 스위치처럼 켜짐을 눌린 상태로 보이는 전원 단추
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: Binding(get: { model.enabled }, set: { on in
                        if on { model.turnOn() } else { Task { await model.turnOff() } }
                    })) { Label(model.enabled ? "앱별 스플리팅 끄기" : "앱별 스플리팅 켜기", systemImage: "power") }
                    .toggleStyle(.button).disabled(model.busy)
                    .help(model.enabled ? "앱별 중계 끄기 (호스트 규칙은 그대로)" : "앱별 중계 켜기")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(action: pickApp) { Label("앱 추가", systemImage: "plus") }
                        .help("앱 추가…").disabled(model.busy)
                    Menu {
                        Button("상태 새로고침") { Task { await model.refresh() } }
                        Button("시스템 설정 열기") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!) }
                        Divider()
                        Button("프록시 구성 및 확장 제거…", role: .destructive) { confirmRemove = true }
                    } label: { Label("더 보기", systemImage: "ellipsis.circle") }
                    .disabled(model.busy)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onReceive(AppModel.shared.$pendingSplitApp) { url in
            // 라우팅 보기에서 "앱별 스플리팅에 추가…"로 연 앱
            guard let url else { return }
            AppModel.shared.pendingSplitApp = nil
            choose(url)
        }
        .onChange(of: selection) { _, value in
            if value == nil && newRule { return }
            draft = model.config.rules.first { $0.id == value }; newRule = false
        }
        .task { while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for: .seconds(2)) } }
        .confirmationDialog("앱별 스플리팅의 프록시 구성과 확장을 제거할까요?", isPresented: $confirmRemove) {
            Button("제거", role: .destructive) { Task { await model.turnOff(remove: true) } }
        }
    }

    private var detailTitle: String {
        if selection == Self.othersTag { return "규칙 없는 앱" }
        return draft.map { $0.name.isEmpty ? $0.signingID : $0.name } ?? "앱별 스플리팅"
    }

    /// "켜짐 · 확장 허용됨 · 연결 3 · 중계 120 · 차단 2"
    private var statusLine: String {
        var parts = [model.connected ? "켜짐" : model.enabled ? "켜는 중" : "꺼짐", "확장 \(model.extensionState)"]
        if model.connected {
            parts += ["연결 \(model.report.active)", "중계 \(model.report.accepted)", "차단 \(model.report.blocked)"]
        }
        return parts.joined(separator: " · ")
    }

    private func noteBand(_ note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarn)
            Text(note).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.note = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("닫기")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.statusWarn.opacity(0.12)))
        .padding(.horizontal, 20).padding(.top, 12)
    }

    /// "Only chosen apps use the VPN": while a VPN holds the default route, apps without a rule leave through Wi-Fi.
    private var othersForm: some View {
        let others = model.config.others ?? OthersPolicy()
        let save: (OthersPolicy) -> Void = { value in var next = model.config; next.others = value; Task { await model.save(next) } }
        return Form {
            Section {
                Toggle("VPN이 켜져 있으면 다른 출구로 보내기", isOn: Binding(get: { others.enabled }, set: { var o = others; o.enabled = $0; save(o) }))
                Picker("출구", selection: Binding(get: { others.exits.first ?? "wifi" }, set: { var o = others; o.exits = [$0]; save(o) })) {
                    ForEach(["wifi", "wired", "tether"], id: \.self) { Text(Exits.label($0)).tag($0) }
                }
                .disabled(!others.enabled)
            } footer: {
                Text("VPN 출구를 정한 앱만 VPN으로. DNS는 그대로.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).disabled(model.busy)
    }

    private func binding<T>(_ path: WritableKeyPath<SplitRule, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // Little Snitch 의 인스펙터처럼 맨 위에 앱 아이콘과 이름
                    HStack(spacing: 12) {
                        AppIcon(signingID: draft!.signingID, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft!.name.isEmpty ? draft!.signingID : draft!.name).font(.title3.bold())
                            Text(draft!.exits.isEmpty ? "모든 연결을 막아요" : draft!.exits.map(Exits.label).joined(separator: " → ") + " · 없으면 " + (draft!.fallback == "system" ? "평소 경로" : "차단"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("이 앱 규칙 사용", isOn: binding(\.enabled)).toggleStyle(.switch).labelsHidden().help("이 앱 규칙 사용")
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("이름", text: binding(\.name))
                    Toggle("같은 제작자의 보조 프로세스도 포함", isOn: binding(\.helpers)).disabled(draft?.teamID.isEmpty == true)
                    DisclosureGroup("앱 식별 정보") {
                        LabeledContent("서명 ID", value: draft!.signingID)
                        LabeledContent("제작자 팀", value: draft!.teamID.isEmpty ? "팀 ID 없음 · 정확한 서명 ID로 구분" : draft!.teamID)
                    }
                }
                Section("출구 순위") {
                    if draft!.exits.isEmpty { Text("출구 없음 — 이 앱의 연결을 차단해요").foregroundStyle(.secondary) }
                    ForEach(Array(draft!.exits.enumerated()), id: \.element) { index, name in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 12)
                            ExitBadge(name: name, size: 24)
                            Text(Exits.label(name))
                            Spacer()
                            if draft!.exits.count > 1 {
                                Button { draft!.exits.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(index == 0).help("위로")
                                Button { draft!.exits.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(index == draft!.exits.count - 1).help("아래로")
                            }
                            Button { draft!.exits.remove(at: index) } label: { Image(systemName: "minus.circle.fill") }
                                .foregroundStyle(.secondary).help("출구 빼기")
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu {
                        ForEach(candidates.filter { !draft!.exits.contains($0) }, id: \.self) { name in Button(Exits.label(name)) { draft!.exits.append(name) } }
                    } label: { Label("출구 추가", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(draft!.exits.count >= 6)
                }
                Section {
                    Picker("출구가 없을 때", selection: binding(\.fallback)) {
                        Text("차단").tag("block"); Text("평소 시스템 경로").tag("system")
                    }
                } footer: {
                    Text("이미 열린 연결은 앱을 다시 열어야 바뀌어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.report.exits.isEmpty {
                    Section("지금 쓸 수 있는 출구") {
                        ForEach(model.report.exits, id: \.iface) { exit in
                            HStack {
                                Text(exit.label)
                                Spacer()
                                if !exit.healthy { Text("응답 없음").foregroundStyle(Color.statusWarn) }
                            }
                        }
                    }
                }
            }.formStyle(.grouped).disabled(model.busy)
            Divider()
            HStack {
                if !newRule {
                    Button("규칙 삭제", role: .destructive) {
                        var next = model.config; next.rules.removeAll { $0.id == draft!.id }
                        Task { await model.save(next); if model.note == nil { draft = nil; selection = nil } }
                    }
                    .buttonStyle(.borderless).foregroundStyle(Color.statusError)
                }
                Spacer()
                Button(newRule ? "추가" : "저장") {
                    var next = model.config
                    if let index = next.rules.firstIndex(where: { $0.id == draft!.id }) { next.rules[index] = draft! }
                    else { next.rules.append(draft!) }
                    let id = draft!.id
                    Task { await model.save(next); if model.note == nil { selection = id; newRule = false } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!newRule && draft == model.config.rules.first { $0.id == draft?.id })
            }
            .padding(.horizontal, 20).padding(.vertical, 12).disabled(model.busy)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }

    /// 고른 앱: 이미 규칙이 있으면 그 규칙을, 없으면 새 규칙 초안을 연다
    private func choose(_ url: URL) {
        do {
            let rule = try SplitControl.selectedApp(url)
            if let existing = model.config.rules.first(where: { $0.signingID == rule.signingID && $0.teamID == rule.teamID }) {
                selection = existing.id; draft = existing; newRule = false
            } else { selection = nil; draft = rule; newRule = true }
        } catch { model.note = error.localizedDescription }
    }
}

/// 앱 규칙 목록의 한 줄: 앱 아이콘 + 이름 + 출구 순위, 오른쪽에 켜기 상자.
struct AppRuleListItem: View {
    let rule: SplitRule
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 9) {
            AppIcon(signingID: rule.signingID, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name.isEmpty ? rule.signingID : rule.name).lineLimit(1)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(rule.enabled ? (rule.exits.isEmpty ? "차단" : rule.exits.map(Exits.label).joined(separator: " → ")) : "꺼짐")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                .toggleStyle(.checkbox).labelsHidden().help(rule.enabled ? "이 앱 규칙 끄기" : "이 앱 규칙 켜기")
        }
        .padding(.vertical, 2)
    }
}

/// 서명 ID(= 대개 번들 ID)로 찾은 앱 아이콘. 못 찾으면 빈 앱 기호.
struct AppIcon: View {
    let signingID: String
    var size: CGFloat = 22
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.icon(signingID) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.7)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }

    private static func icon(_ id: String) -> NSImage? {
        if let hit = cache[id] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = image
        return image
    }
}

/// CLI shares the same config store and activation/removal path as the window.
enum AppSplitCLI {
    static func run(_ args: [String], uninstallAll: Bool = false) -> Never {
        Task { @MainActor in
            do {
                var config = UserDefaults.standard.data(forKey: "appSplitConfig").flatMap { try? JSONDecoder().decode(SplitConfig.self, from: $0) } ?? SplitConfig()
                let existing = try await SplitControl.manager()
                config = try await SplitControl.currentConfig(config, manager: existing)
                let command = args.first ?? "edit"
                switch command {
                case "edit":
                    exit(sh("/usr/bin/open", ["wifi-exit://app-rules"]).ok ? 0 : 1)
                case "status":
                    let manager = try await SplitControl.manager()
                    var value: [String: Any] = ["enabled": manager?.isEnabled == true, "connected": manager?.connection.status == .connected,
                        "extension": SplitControl.installed(), "rules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.rules)),
                        "others": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.others ?? OthersPolicy()))]
                    if let manager, manager.connection.status == .connected,
                       let report = try await SplitControl.message(Data("status".utf8), manager: manager) {
                        value["report"] = try JSONSerialization.jsonObject(with: report)
                    }
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                case "add":
                    guard args.count >= 2 else { throw relayHostError("apps add <앱.app 경로> [--via wifi,wired] [--else block|system]") }
                    var rule = try SplitControl.selectedApp(URL(fileURLWithPath: args[1]))
                    var index = 2
                    while index < args.count {
                        guard index + 1 < args.count else { throw relayHostError("옵션 값이 없어요") }
                        if args[index] == "--via", let exits = Exits.parseList(args[index + 1]) { rule.exits = exits }
                        else if args[index] == "--else", ["block", "system"].contains(args[index + 1]) { rule.fallback = args[index + 1] }
                        else { throw relayHostError("옵션: --via <출구 목록> --else block|system") }
                        index += 2
                    }
                    if let index = config.rules.firstIndex(where: { $0.signingID == rule.signingID && $0.teamID == rule.teamID }) {
                        rule.id = config.rules[index].id; config.rules[index] = rule
                    } else { config.rules.append(rule) }
                    config = try await SplitControl.store(config)
                    UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "appSplitConfig")
                    print("등록: \(rule.name) · \(rule.signingID) · \(rule.exits.map(Exits.label).joined(separator: " → "))")
                case "rm", "on", "off":
                    guard args.count == 2, let index = config.rules.firstIndex(where: { $0.id == args[1] || $0.signingID == args[1] }) else { throw relayHostError("등록된 앱 ID를 넣어 주세요") }
                    if command == "rm" { config.rules.remove(at: index) } else { config.rules[index].enabled = command == "on" }
                    config = try await SplitControl.store(config)
                    UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "appSplitConfig")
                case "others":
                    // apps others on [--via wifi] | off — VPN이 기본 경로일 때 규칙 없는 앱의 출구
                    guard args.count >= 2, ["on", "off"].contains(args[1]) else { throw relayHostError("apps others on [--via wifi|wired|tether,…] | off") }
                    var others = config.others ?? OthersPolicy()
                    others.enabled = args[1] == "on"
                    if args.count == 4, args[2] == "--via", let exits = Exits.parseList(args[3]), !exits.isEmpty { others.exits = exits }
                    else if args.count != 2 { throw relayHostError("옵션: --via <출구 목록>") }
                    config.others = others
                    config = try await SplitControl.store(config)
                    UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "appSplitConfig")
                    print(others.enabled ? "VPN이 켜져 있으면 규칙 없는 앱 → \(others.exits.map(Exits.label).joined(separator: " → "))" : "규칙 없는 앱은 평소 경로")
                case "enable":
                    guard config.rules.contains(where: \.enabled) || config.others?.enabled == true else { throw relayHostError("먼저 앱을 등록해 주세요") }
                    if SplitPolicy.requiresEngineMigration(config: FileManager.default.contents(atPath: Paths.config), status: FileManager.default.contents(atPath: Paths.status)) { throw relayHostError("엔진 갱신을 먼저 실행해 주세요") }
                    let ready: Bool = await withCheckedContinuation { continuation in
                        _ = SplitExtensionRequest(activate: true, update: { print($0); fflush(stdout) }) { ready, note in
                            if let note { print(note) }; continuation.resume(returning: ready)
                        }
                    }
                    guard ready else { exit(1) }
                    config = try await SplitControl.store(config, enable: true)
                    UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "appSplitConfig")
                    print("앱별 스플리팅 시작 요청됨")
                case "disable", "remove":
                    try await SplitControl.disable(remove: command == "remove")
                    if command == "remove", SplitControl.installed() != "등록 안 됨" {
                        let _: Bool = await withCheckedContinuation { continuation in
                            _ = SplitExtensionRequest(activate: false, update: { print($0) }) { ready, note in
                                if let note { print(note) }; continuation.resume(returning: ready)
                            }
                        }
                    }
                default: throw relayHostError("apps [edit|status|add <앱.app>|rm|on|off <앱ID>|others on|off|enable|disable|remove]")
                }
                if uninstallAll {
                    UserDefaults.standard.removeObject(forKey: "appSplitConfig")
                    if Engine.installedAtAll() {
                        let result = Engine.run(["uninstall"])
                        if !result.ok { exit(shInteractive("/usr/bin/sudo", [Paths.engine, "uninstall"])) }
                        print(result.out, terminator: "")
                    }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("wifi-exit: " + error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        dispatchMain()
    }
}
