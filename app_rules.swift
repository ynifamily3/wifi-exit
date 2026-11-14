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
        guard config.rules.contains(where: \.enabled) else { note = "먼저 앱 규칙을 추가해 주세요"; return }
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

struct AppRulesView: View {
    @StateObject private var model = SplitModel()
    @State private var selection: String?
    @State private var draft: SplitRule?
    @State private var newRule = false
    @State private var confirmRemove = false
    private var candidates: [String] {
        var result = ["wifi", "wired", "tether", "vpn:any"]
        for e in model.report.exits where !result.contains(e.selector) { result.append(e.selector) }
        for e in readStatus()?.exits ?? [] where e.name == "vpn" && !e.portal.isEmpty {
            let selector = "vpn:" + e.portal; if !result.contains(selector) { result.append(selector) }
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.connected ? "앱별 스플리팅 켜짐" : "앱별 스플리팅 꺼짐").font(.headline)
                    Text("확장 \(model.extensionState) · 연결 \(model.report.active) · 누적 중계 \(model.report.accepted) · 차단 \(model.report.blocked)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.enabled ? "끄기" : "켜기") {
                    if model.enabled { Task { await model.turnOff() } } else { model.turnOn() }
                }.disabled(model.busy)
                Menu {
                    Button("상태 새로고침") { Task { await model.refresh() } }
                    Button("시스템 설정 열기") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!) }
                    Button("프록시 구성 및 확장 제거…", role: .destructive) { confirmRemove = true }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize().disabled(model.busy)
            }.padding(16)
            if let note = model.note { Text(note).foregroundStyle(.orange).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10) }
            Divider()
            HSplitView {
                VStack(alignment: .leading) {
                    List(selection: $selection) {
                        ForEach(model.config.rules) { rule in
                            HStack {
                                Image(systemName: "app.fill")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.name)
                                    Text(rule.enabled ? (rule.exits.isEmpty ? "차단" : rule.exits.map(Exits.label).joined(separator: " → ")) : "꺼짐")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.tag(rule.id)
                        }
                        .onMove { from, to in var next = model.config; next.rules.move(fromOffsets: from, toOffset: to); Task { await model.save(next) } }
                    }
                    Button("앱 추가…", action: pickApp).padding(12).disabled(model.busy)
                }.frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                Group {
                    if draft != nil { editor }
                    else { ContentUnavailableView("앱을 선택해 주세요", systemImage: "app.badge", description: Text("앱 추가로 출구를 지정할 앱을 고르세요")) }
                }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("호스트 규칙을 먼저 적용하고 선택한 앱의 새 TCP·UDP 연결만 중계해요. 다른 앱과 시스템 DNS 설정은 그대로예요. 켜거나 앱을 추가한 뒤에는 해당 앱을 다시 열어 기존 연결도 갱신해 주세요.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: selection) { _, value in
            if value == nil && newRule { return }
            draft = model.config.rules.first { $0.id == value }; newRule = false
        }
        .task { while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for: .seconds(2)) } }
        .confirmationDialog("앱별 스플리팅의 프록시 구성과 확장을 제거할까요?", isPresented: $confirmRemove) {
            Button("제거", role: .destructive) { Task { await model.turnOff(remove: true) } }
        }
    }
    private func binding<T>(_ path: WritableKeyPath<SplitRule, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }
    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("앱 이름", text: binding(\.name))
                    Toggle("이 앱 규칙 사용", isOn: binding(\.enabled))
                    Toggle("같은 제작자의 보조 프로세스도 포함", isOn: binding(\.helpers)).disabled(draft?.teamID.isEmpty == true)
                    DisclosureGroup("앱 식별 정보") {
                        LabeledContent("서명 ID", value: draft!.signingID)
                        LabeledContent("제작자 팀", value: draft!.teamID.isEmpty ? "팀 ID 없음 · 정확한 서명 ID로 구분" : draft!.teamID)
                    }
                }
                Section("출구 순위") {
                    if draft!.exits.isEmpty { Text("출구 없음 — 이 앱의 연결을 차단해요").foregroundStyle(.secondary) }
                    ForEach(Array(draft!.exits.enumerated()), id: \.element) { index, name in
                        HStack {
                            Text("\(index + 1). \(Exits.label(name))")
                            Spacer()
                            Button { draft!.exits.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                            Button { draft!.exits.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == draft!.exits.count - 1)
                            Button { draft!.exits.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        }.buttonStyle(.borderless)
                    }
                    Menu("출구 추가") {
                        ForEach(candidates.filter { !draft!.exits.contains($0) }, id: \.self) { name in Button(Exits.label(name)) { draft!.exits.append(name) } }
                    }.disabled(draft!.exits.count >= 6)
                }
                Section {
                    Picker("출구가 없을 때", selection: binding(\.fallback)) {
                        Text("차단").tag("block"); Text("평소 시스템 경로").tag("system")
                    }
                    Text("연결 중인 출구가 끊기거나 규칙이 바뀌면 기존 중계 연결을 닫아요. 앱이 다시 연결할 때 출구 순위를 적용해요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.report.exits.isEmpty {
                    Section("지금 사용 가능한 출구") {
                        ForEach(model.report.exits, id: \.iface) { exit in Text(exit.label + (exit.healthy ? "" : " · 응답 없음")) }
                    }
                }
            }.formStyle(.grouped).disabled(model.busy)
            HStack {
                if !newRule {
                    Button("규칙 삭제", role: .destructive) {
                        var next = model.config; next.rules.removeAll { $0.id == draft!.id }
                        Task { await model.save(next); if model.note == nil { draft = nil; selection = nil } }
                    }
                }
                Spacer()
                Button(newRule ? "추가" : "저장") {
                    var next = model.config
                    if let index = next.rules.firstIndex(where: { $0.id == draft!.id }) { next.rules[index] = draft! }
                    else { next.rules.append(draft!) }
                    let id = draft!.id
                    Task { await model.save(next); if model.note == nil { selection = id; newRule = false } }
                }.buttonStyle(.borderedProminent)
            }.padding(12).disabled(model.busy)
        }
    }
    private func pickApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rule = try SplitControl.selectedApp(url)
            if let existing = model.config.rules.first(where: { $0.signingID == rule.signingID && $0.teamID == rule.teamID }) {
                selection = existing.id; draft = existing; newRule = false
            } else { selection = nil; draft = rule; newRule = true }
        } catch { model.note = error.localizedDescription }
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
                        "extension": SplitControl.installed(), "rules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.rules))]
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
                case "enable":
                    guard config.rules.contains(where: \.enabled) else { throw relayHostError("먼저 앱을 등록해 주세요") }
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
                default: throw relayHostError("apps [edit|status|add <앱.app>|rm|on|off <앱ID>|enable|disable|remove]")
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
