// Wi-Fi Exit 앱 규칙: 투명 프록시 시스템 확장을 담고 켜고 끄는 작은 앱.
//   그냥 열면 상태와 켜기·끄기 버튼이 있는 작은 창.
//   명령으로: WifiExitAppRules activate | deactivate | enable | disable | remove | status [--json]
//   - activate   확장 등록 요청 (처음엔 시스템 설정에서 허용 필요)
//   - enable     프록시 설정을 만들고 켬 (처음엔 "프록시 구성 추가" 허용 필요)
//   - disable    프록시 끔 (확장은 남음)
//   - remove     프록시 설정 지움
//   - deactivate 확장 제거 요청 (재부팅 때 지워짐)

import AppKit
import NetworkExtension
import SwiftUI
import SystemExtensions

let extID = "com.miel.WifiExit.AppRules.proxy"
let proxyName = "Wi-Fi Exit 앱 규칙"

// MARK: - 확장·프록시 제어

struct ProxyState: Codable, Equatable {
    var installed = "unknown"     // activated | waiting | none | unknown
    var configured = false
    var enabled = false
    var connection = "none"       // none | disconnected | connecting | connected | disconnecting | invalid
}

enum Control {
    /// 시스템 확장 상태: systemextensionsctl 목록에서 읽는다 (공개 API 가 없다)
    static func installedState() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        p.arguments = ["list"]
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return "unknown" }
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        done.wait()
        let lines = out.split(separator: "\n").filter { $0.contains(extID) }
        if lines.contains(where: { $0.contains("[activated enabled]") }) { return "activated" }
        if lines.contains(where: { $0.contains("waiting for user") }) { return "waiting" }
        return "none"
    }

    static func connectionText(_ s: NEVPNStatus) -> String {
        switch s {
        case .connected: return "connected"
        case .connecting, .reasserting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .invalid: return "invalid"
        @unknown default: return "none"
        }
    }

    static func manager(_ done: @escaping (NETransparentProxyManager?, Error?) -> Void) {
        NETransparentProxyManager.loadAllFromPreferences { ms, err in done(ms?.first, err) }
    }

    static func state(_ done: @escaping (ProxyState) -> Void) {
        var st = ProxyState()
        st.installed = installedState()
        manager { m, _ in
            if let m {
                st.configured = true
                st.enabled = m.isEnabled
                st.connection = connectionText(m.connection.status)
            }
            done(st)
        }
    }

    static func enable(_ done: @escaping (String?) -> Void) {
        manager { existing, err in
            if let err { done("설정을 읽지 못했어요: \(err.localizedDescription)"); return }
            let m = existing ?? NETransparentProxyManager()
            let p = NETunnelProviderProtocol()
            p.providerBundleIdentifier = extID
            p.serverAddress = proxyName
            m.protocolConfiguration = p
            m.localizedDescription = proxyName
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err { done("설정을 저장하지 못했어요: \(err.localizedDescription)"); return }
                m.loadFromPreferences { _ in
                    do { try m.connection.startVPNTunnel(); done(nil) } catch { done("켜지 못했어요: \(error.localizedDescription)") }
                }
            }
        }
    }

    static func disable(_ done: @escaping (String?) -> Void) {
        manager { m, _ in
            guard let m else { done(nil); return }
            m.connection.stopVPNTunnel()
            m.isEnabled = false
            m.saveToPreferences { err in done(err.map { "끄지 못했어요: \($0.localizedDescription)" }) }
        }
    }

    static func remove(_ done: @escaping (String?) -> Void) {
        manager { m, _ in
            guard let m else { done(nil); return }
            m.connection.stopVPNTunnel()
            m.removeFromPreferences { err in done(err.map { "지우지 못했어요: \($0.localizedDescription)" }) }
        }
    }
}

/// 확장 등록·제거 요청 (결과는 콜백으로)
final class SysextRequest: NSObject, OSSystemExtensionRequestDelegate {
    static var live: [SysextRequest] = []
    let onUpdate: (String) -> Void
    let onDone: (String?) -> Void

    init(activate: Bool, onUpdate: @escaping (String) -> Void, onDone: @escaping (String?) -> Void) {
        self.onUpdate = onUpdate; self.onDone = onDone
        super.init()
        let r = activate ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extID, queue: .main)
                         : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extID, queue: .main)
        r.delegate = self
        SysextRequest.live.append(self)
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func request(_ r: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func requestNeedsUserApproval(_ r: OSSystemExtensionRequest) {
        onUpdate("시스템 설정 → 일반 → 로그인 항목 및 확장 → 네트워크 확장에서 허용해 주세요")
    }
    func request(_ r: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        finish(result == .willCompleteAfterReboot ? "재부팅하면 적용돼요" : nil)
    }
    func request(_ r: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish("실패: \(error.localizedDescription)")
    }
    private func finish(_ msg: String?) {
        onDone(msg)
        SysextRequest.live.removeAll { $0 === self }
    }
}

// MARK: - 명령 줄

enum CLI {
    static let commands: Set<String> = ["activate", "deactivate", "enable", "disable", "remove", "status"]

    static func run(_ args: [String]) -> Never {
        func out(_ s: String) { print(s); fflush(stdout) }
        func end(_ err: String?) -> Never { if let err { FileHandle.standardError.write((err + "\n").data(using: .utf8)!); exit(1) }; exit(0) }
        switch args.first ?? "status" {
        case "activate":
            _ = SysextRequest(activate: true, onUpdate: out) { e in out(e ?? "확장 켜짐"); end(e?.hasPrefix("실패") == true ? e : nil) }
        case "deactivate":
            _ = SysextRequest(activate: false, onUpdate: out) { e in out(e ?? "확장 제거 요청됨 (재부팅 때 지워짐)"); end(e?.hasPrefix("실패") == true ? e : nil) }
        case "enable": Control.enable { e in if e == nil { out("프록시 켬") }; end(e) }
        case "disable": Control.disable { e in if e == nil { out("프록시 끔") }; end(e) }
        case "remove": Control.remove { e in if e == nil { out("프록시 설정 지움") }; end(e) }
        default:
            Control.state { st in
                if args.contains("--json"), let d = try? JSONEncoder().encode(st) { out(String(decoding: d, as: UTF8.self)) }
                else { out("확장 \(st.installed) · 프록시 설정 \(st.configured ? (st.enabled ? "켜짐" : "꺼짐") : "없음") · 연결 \(st.connection)") }
                end(nil)
            }
        }
        dispatchMain()
    }
}

// MARK: - 창

@MainActor
final class Model: ObservableObject {
    @Published var st = ProxyState()
    @Published var note: String?
    @Published var busy = false

    func refresh() { Control.state { s in DispatchQueue.main.async { self.st = s } } }

    func turnOn() {
        busy = true; note = nil
        _ = SysextRequest(activate: true, onUpdate: { m in DispatchQueue.main.async { self.note = m } }) { e in
            DispatchQueue.main.async {
                if let e, e.hasPrefix("실패") { self.note = e; self.busy = false; self.refresh(); return }
                Control.enable { e2 in DispatchQueue.main.async { self.note = e2; self.busy = false; self.refresh() } }
            }
        }
    }
    func turnOff() {
        busy = true
        Control.disable { e in DispatchQueue.main.async { self.note = e; self.busy = false; self.refresh() } }
    }
    func uninstall() {
        busy = true
        Control.remove { _ in
            DispatchQueue.main.async {
                _ = SysextRequest(activate: false, onUpdate: { _ in }) { e in
                    DispatchQueue.main.async { self.note = e ?? "확장 제거 요청됨 (재부팅 때 지워져요)"; self.busy = false; self.refresh() }
                }
            }
        }
    }
}

struct MainView: View {
    @StateObject private var m = Model()

    private var on: Bool { m.st.installed == "activated" && m.st.enabled && m.st.connection == "connected" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(on ? Color.green : Color.secondary.opacity(0.45))
                        Image(systemName: on ? "checkmark.shield.fill" : "shield.slash").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }.frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(on ? "앱 규칙 켜짐" : "앱 규칙 꺼짐").font(.title3.bold())
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if m.busy { ProgressView().controlSize(.small) }
                }.padding(.vertical, 4)
            }
            if let n = m.note { Section { Label(n, systemImage: "info.circle").foregroundStyle(.orange) } }
            Section {
                LabeledContent("시스템 확장", value: installedText)
                LabeledContent("프록시 설정", value: m.st.configured ? (m.st.enabled ? "켜짐" : "꺼짐") : "없음")
                LabeledContent("연결", value: m.st.connection)
            } footer: {
                Text("지금 단계(A1)에서는 확장이 모든 연결을 그대로 돌려보내요. 앱 규칙 적용은 다음 단계에서 들어가요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("켜기") { m.turnOn() }.buttonStyle(.borderedProminent).disabled(m.busy || on)
                    Button("끄기") { m.turnOff() }.disabled(m.busy || !m.st.enabled)
                    Spacer()
                    Button("확장 제거", role: .destructive) { m.uninstall() }.disabled(m.busy || m.st.installed == "none")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { m.refresh() }
    }

    private var installedText: String {
        switch m.st.installed {
        case "activated": return "켜짐"
        case "waiting": return "허용 기다리는 중"
        case "none": return "없음"
        default: return "모름"
        }
    }
    private var summary: String {
        if m.st.installed == "waiting" { return "시스템 설정에서 허용해 주세요" }
        if on { return "고른 앱의 연결을 정한 출구로 보내요" }
        return "켜면 시스템 확장과 프록시 구성을 한 번 허용해야 해요"
    }
}

struct AppRulesApp: App {
    var body: some Scene {
        Window("Wi-Fi Exit 앱 규칙", id: "main") { MainView() }
            .windowResizability(.contentSize)
    }
}

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let a = args.first, CLI.commands.contains(a) { CLI.run(args) }
        NSApplication.shared.setActivationPolicy(.regular)
        AppRulesApp.main()
    }
}
