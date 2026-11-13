// Wi-Fi Exit — 등록한 호스트(IP, CIDR, 도메인)가 유선 랜과 VPN 터널을 쓰지 않고 Wi-Fi 로만 나가게 하는 메뉴바 앱 + CLI.
//
// 실제 일은 root 엔진(engine.swift → /Library/PrivilegedHelperTools/com.miel.WifiExit.engine)이 상주하며 한다.
//   - Wi-Fi 게이트웨이로 가는 고정 라우트, pf 로 Wi-Fi 밖 인터페이스 차단, 도메인 주기 해석, /etc/resolver
//   - 네트워크가 바뀌는 순간(SCDynamicStore)과 설정이 바뀌는 순간 적용하고, 30초마다 한 번 더 맞춘다
// 앱과 CLI 는 상태를 state/status.json 에서 sudo 없이 읽고, 설정 변경만 sudoers 규칙으로 엔진에 맡긴다.

import AppKit
import Combine
import Darwin
import ServiceManagement
import SwiftUI

// MARK: - 셸

struct ShellResult {
    let code: Int32
    let out: String
    let err: String
    var ok: Bool { code == 0 }
    var message: String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

@discardableResult
func sh(_ path: String, _ args: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    p.standardInput = FileHandle.nullDevice
    let done: DispatchSemaphore
    do { done = try p.runWatched() } catch { return ShellResult(code: -1, out: "", err: "\(error)") }
    var errData = Data()
    let g = DispatchGroup()
    g.enter()
    DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    g.wait()
    done.wait()
    return ShellResult(code: p.terminationStatus,
                       out: String(decoding: outData, as: UTF8.self),
                       err: String(decoding: errData, as: UTF8.self))
}

/// 터미널을 그대로 물려 받아 돌린다 (sudo 암호 입력, 긴 출력).
/// Foundation 의 Process 는 자식을 새 프로세스 그룹에 넣어 터미널의 포그라운드에서 빼 버린다.
/// 그러면 sudo 가 암호를 숨긴 채 읽지 못하고 입력이 화면에 그대로 찍히므로 posix_spawn 으로 같은 그룹에서 돌린다.
func shInteractive(_ path: String, _ args: [String]) -> Int32 {
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return -1 }
    var st: Int32 = 0
    while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
    return (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// 관리자 암호 창을 띄워 root 로 셸 스크립트를 돌린다.
func runAsAdmin(_ script: String, prompt: String) -> ShellResult {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    return sh("/usr/bin/osascript",
              ["-e", "do shell script \"\(esc(script))\" with prompt \"\(esc(prompt))\" with administrator privileges"])
}

func background<T>(_ work: @escaping () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

func timeText(_ epoch: Int) -> String {
    guard epoch > 0 else { return "없음" }
    let d = Date(timeIntervalSince1970: TimeInterval(epoch))
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "M/d HH:mm"
    return f.string(from: d)
}

// MARK: - 엔진

enum Engine {
    /// 심볼릭 링크(~/.local/bin/wifi-exit)로 불려도 번들 안의 엔진을 찾는다.
    static var bundled: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/wifi-exitd")
    }

    static func installedAtAll() -> Bool { FileManager.default.fileExists(atPath: Paths.engine) }
    static func sudoOK() -> Bool { sh("/usr/bin/sudo", ["-n", "-l", Paths.engine]).ok }

    /// 코드 서명의 CDHash. 서명 시각(타임스탬프)이 달라도 코드가 같으면 같다.
    static func cdhash(_ path: String) -> String? {
        let r = sh("/usr/bin/codesign", ["-dvvv", path])
        return (r.err + r.out).split(separator: "\n").first { $0.hasPrefix("CDHash=") }.map(String.init)
    }

    /// 깔린 엔진이 앱에 든 엔진과 같고 sudo 가 암호 없이 허용하는지.
    static func ready() -> Bool {
        guard FileManager.default.fileExists(atPath: Paths.engine) else { return false }
        if let a = FileManager.default.contents(atPath: Paths.engine), let b = FileManager.default.contents(atPath: bundled.path), a != b {
            guard let ha = cdhash(Paths.engine), let hb = cdhash(bundled.path), ha == hb else { return false }
        }
        return sudoOK()
    }

    static var sudoersRule: String { "\(NSUserName()) ALL=(root) NOPASSWD: \(Paths.engine)\n" }

    /// 엔진·sudoers 를 깔고 데몬을 올리는 root 스크립트. v1(zsh 도우미) 설정은 엔진이 옮긴다.
    static func installScript(sudoersSrc: String) -> String {
        [
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /private/etc/sudoers.d",
            "/usr/bin/install -o root -g wheel -m 755 \(shQuote(bundled.path)) \(shQuote(Paths.engine))",
            "/usr/sbin/visudo -cf \(shQuote(sudoersSrc))",
            "/usr/bin/install -o root -g wheel -m 440 \(shQuote(sudoersSrc)) \(shQuote(Paths.sudoers))",
            "\(shQuote(Paths.engine)) install",
        ].joined(separator: " && ")
    }

    /// interactive: 터미널이면 sudo 로 암호를 묻고, 아니면 관리자 암호 창을 띄운다.
    static func install(interactive: Bool) -> ShellResult {
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            return ShellResult(code: -1, out: "", err: "번들에서 엔진을 찾지 못했어요: \(bundled.path)")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wifiexit-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sudoersSrc = tmp.appendingPathComponent("sudoers")
        do { try sudoersRule.write(to: sudoersSrc, atomically: true, encoding: .utf8) } catch {
            return ShellResult(code: -1, out: "", err: "\(error)")
        }
        let root = installScript(sudoersSrc: sudoersSrc.path)
        if interactive {
            let code = shInteractive("/usr/bin/sudo", ["/bin/sh", "-c", root])
            return ShellResult(code: code, out: "", err: code == 0 ? "" : "설치에 실패했어요 (종료 코드 \(code))")
        }
        return runAsAdmin(root, prompt: "Wi-Fi Exit가 라우트와 방화벽 규칙을 관리할 엔진을 설치합니다.")
    }

    /// 인자는 NFC 로 바꿔 넘긴다 (터미널에서 온 한글이 자모로 풀려 있으면 메모가 깨져 보인다).
    @discardableResult
    static func run(_ args: [String]) -> ShellResult {
        sh("/usr/bin/sudo", ["-n", Paths.engine] + args.map(\.precomposedStringWithCanonicalMapping))
    }
}

enum LoginItem {
    static var text: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires-approval"
        case .notRegistered: return "not-registered"
        case .notFound: return "not-found"
        @unknown default: return "unknown"
        }
    }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension RuleState {
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .fixing: return "arrow.triangle.2.circlepath.circle.fill"
        case .noExit: return "wifi.slash"
        case .unresolved: return "questionmark.circle"
        case .leak: return "exclamationmark.triangle.fill"
        case .off: return "circle"
        case .paused: return "pause.circle"
        case .bypass: return "arrow.uturn.right.circle"
        }
    }
    var color: Color {
        switch self {
        case .ok: return .green
        case .fixing, .unresolved: return .orange
        case .noExit: return .blue
        case .leak: return .red
        case .off, .paused, .bypass: return .secondary
        }
    }
}

extension Color {
    /// 출구 색 = 시스템 색. 초록·주황·빨강은 상태(정상·경고·오류)에 쓰므로 출구에는 쓰지 않는다 (차단만 빨강).
    static func exit(_ name: String) -> Color {
        switch Exits.kind(name) {
        case "wifi": return .blue
        case "wired": return .teal
        case "tether": return .pink
        case "block": return .red
        default: return .purple   // vpn
        }
    }
}

/// 출구 후보: 고정 이름 + VPN 별칭(~/.config/gpvpn/config 의 별칭=포털).
func exitCandidates() -> [String] {
    var aliases: [String] = []
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gpvpn/config").path
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !["default", "dns", "login"].contains(kv[0]), !kv[0].contains("."), Exits.isValid("vpn:" + kv[0]) else { continue }
            aliases.append("vpn:" + kv[0])
        }
    }
    if aliases.isEmpty { aliases = ["vpn:pass", "vpn:cloud"] }
    return ["wifi", "wired"] + aliases + ["vpn:any", "tether"]
}

let STALE_AFTER = 120   // 엔진이 이보다 오래 상태를 안 쓰면 데몬이 멈췄다고 본다

// MARK: - 앱 모델

@MainActor
final class AppModel: ObservableObject {
    @Published var status: EngineStatus?
    @Published var engineReady = false
    @Published var engineOutdated = false
    @Published var message: String?
    @Published var busy = false
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var config: EngineConfig?
    @Published var windowSelection: String?     // 편집 창에서 고른 것: "rule:<id>" | "profile:<이름>" | "new"
    @Published var drafts: [String: RuleDraft] = [:]   // 편집 창의 저장하지 않은 편집 (키는 windowSelection 과 같다)

    private var timer: Timer?

    init() {
        // 처음 실행하면 로그인 항목으로 한 번 등록한다. 이후엔 사용자가 정한 대로 둔다.
        if !UserDefaults.standard.bool(forKey: "loginItemAsked") {
            UserDefaults.standard.set(true, forKey: "loginItemAsked")
            try? LoginItem.set(true)
            loginItem = SMAppService.mainApp.status == .enabled
        }
        // 상태는 파일을 읽을 뿐이라 자주 읽어도 된다.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadStatus() }
        }
        Task { await refresh() }
    }

    enum Overall { case needsEngine, stale, paused, leak, noWifi, idle, ok }

    var overall: Overall {
        guard engineReady || engineOutdated, let s = status else { return .needsEngine }
        if s.ageSeconds > STALE_AFTER { return .stale }
        if s.paused { return .paused }
        if s.hasLeak { return .leak }
        if s.activeCount == 0 { return .idle }
        if !s.wifi.up { return .noWifi }
        return .ok
    }

    var menuSymbol: String {
        switch overall {
        case .needsEngine, .stale: return "wifi.exclamationmark"
        case .paused: return "wifi.circle"
        case .leak: return "exclamationmark.triangle.fill"
        case .noWifi: return "wifi.slash"
        case .idle: return "wifi"
        case .ok: return "wifi.circle.fill"
        }
    }

    func reloadStatus() {
        status = readStatus()
        // CLI(wifi-exit edit)가 남긴 선택
        // 앱 자신의 도메인(com.miel.WifiExit)은 suiteName 으로 열면 안 되고 standard 로 읽어야 한다
        if let p = UserDefaults.standard.string(forKey: "pendingSelection") {
            UserDefaults.standard.removeObject(forKey: "pendingSelection")
            windowSelection = p
        }
        if let d = FileManager.default.contents(atPath: Paths.config), let c = try? JSONDecoder().decode(EngineConfig.self, from: d), c != config {
            config = c
        }
    }

    /// 도메인 → 지금 풀린 IP
    var resolvedIPs: [String: [String]] {
        var out: [String: [String]] = [:]
        for r in status?.rules ?? [] { for t in r.targets where t.kind == .domain { out[t.target] = t.addresses.map(\.ip) } }
        return out
    }
    func exitUp(_ name: String) -> Bool { findExit(name, in: status?.exits ?? []) != nil }
    /// 출구가 없을 때 그 까닭 (어댑터가 안 보임, 케이블 없음 …). 엔진 상태가 바뀔 때까지 기억해 둔다.
    private var whyCache: (stamp: Int, reasons: [String: String?]) = (-1, [:])
    func exitAbsentReason(_ name: String) -> String? {
        let stamp = status?.generatedAt ?? 0
        if whyCache.stamp != stamp { whyCache = (stamp, [:]) }
        if let r = whyCache.reasons[name] { return r }
        let r = ExitWhy.reason(name, exits: status?.exits ?? [])
        whyCache.reasons[name] = .some(r)
        return r
    }
    /// "지금 있음" / "응답 없음" / "지금 없음 · 까닭"
    func exitStateText(_ name: String) -> String {
        let ms = matchingExits(name, in: status?.exits ?? [])
        if ms.isEmpty { return exitAbsentReason(name).map { "지금 없음 · \($0)" } ?? "지금 없음" }
        return ms.contains { $0.healthy != false } ? "지금 있음" : "응답 없음"
    }
    func profileHere(_ name: String) -> Bool {
        guard let s = status, let c = config else { return false }
        return CLI.facts(s, c).profileMatches(name)
    }

    /// 편집 창의 규칙을 엔진에 넘긴다. CLI 와 같은 add/set/on/off 명령이라 설정 파일도 같다.
    func saveRule(_ d: Rule, isNew: Bool, draftKey: String) async {
        let via = d.exits.isEmpty ? "none" : d.exits.joined(separator: ",")
        let when = d.when.isAlways ? "always" : d.when.text
        let common = ["--targets", d.targets.joined(separator: ","), "--via", via, "--else", d.elseAction, "--when", when,
                      "--check", d.check ?? "none", "--name", d.name]
        busy = true
        var r: ShellResult
        var id = d.id
        if isNew {
            r = await background { Engine.run(["add", d.targets[0], "--new"] + common) }
            if r.ok, let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("id ") }) { id = String(line.dropFirst(3)) }
        } else {
            r = await background { Engine.run(["set", d.id] + common) }
        }
        if r.ok, d.enabled != (config?.rules.first { $0.id == id }?.enabled ?? true) || (isNew && !d.enabled) {
            let rid = id
            r = await background { Engine.run([d.enabled ? "on" : "off", rid]) }
        }
        busy = false
        message = r.ok ? nil : "저장하지 못했어요: \(r.message)"
        await refresh()
        if r.ok {
            drafts[draftKey] = nil
            drafts["rule:" + id] = nil
            windowSelection = "rule:" + id
        }
    }

    func removeProfile(_ name: String) async {
        await perform(["profile", "rm", name], failure: "프로필을 지우지 못했어요")
        windowSelection = nil
    }

    func refresh() async {
        let (ready, installed, canRun) = await background { () -> (Bool, Bool, Bool) in
            let installed = Engine.installedAtAll()
            return (Engine.ready(), installed, installed && Engine.sudoOK())
        }
        engineReady = ready
        engineOutdated = installed && canRun && !ready
        reloadStatus()
    }

    private func perform(_ args: [String], failure: String) async {
        busy = true
        let r = await background { Engine.run(args) }
        busy = false
        message = r.ok ? nil : "\(failure): \(r.message)"
        await refresh()
    }

    func add(_ target: String, note: String) async {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var args = ["add", t]
        let n = note.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { args.append(n) }
        await perform(args, failure: "추가하지 못했어요")
    }
    func setEnabled(_ id: String, _ on: Bool) async { await perform([on ? "on" : "off", id], failure: "바꾸지 못했어요") }
    func remove(_ id: String) async { await perform(["rm", id], failure: "지우지 못했어요") }
    func edit(_ id: String, exits: [String], elseAction: String, when: String) async {
        let w = when.trimmingCharacters(in: .whitespaces)
        await perform(["set", id, "--via", exits.isEmpty ? "none" : exits.joined(separator: ","), "--else", elseAction,
                       "--when", w.isEmpty ? "always" : w], failure: "바꾸지 못했어요")
    }

    /// 지금 붙은 망을 이름 붙여 저장한다 (Wi-Fi 가 있으면 Wi-Fi, 없으면 유선).
    func saveProfile() async {
        guard let s = status else { return }
        let link = s.exits.first { $0.up && $0.name == "wifi" }?.name ?? s.exits.first { $0.up && ($0.name == "wired" || $0.name == "tether") }?.name
        guard let link else { message = "지금 연결된 Wi-Fi나 유선이 없어요."; return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "지금 \(Exits.label(link)) 망을 프로필로 저장"
        alert.informativeText = "게이트웨이 주소와 MAC으로 같은 망인지 가려요. 조건에 profile=<이름> 으로 씁니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "예: 사무실"
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await perform(["profile", "add", name, link], failure: "프로필을 저장하지 못했어요")
    }

    var profileNames: [String] { (config?.profiles.keys).map { $0.sorted() } ?? [] }
    func move(_ id: String, _ where_: String) async { await perform(["move", id, where_], failure: "순서를 바꾸지 못했어요") }
    func setPaused(_ p: Bool) async { await perform([p ? "pause" : "resume"], failure: "바꾸지 못했어요") }
    func apply() async { await perform(["apply"], failure: "적용하지 못했어요") }
    func resolve() async { await perform(["resolve"], failure: "도메인을 다시 풀지 못했어요") }

    func installEngine() async {
        busy = true
        let r = await background { Engine.install(interactive: false) }
        busy = false
        if !r.ok && !r.message.contains("-128") { message = "엔진 설치 실패: \(r.message)" } else { message = nil }
        await refresh()
    }

    func setLoginItem(_ on: Bool) {
        do { try LoginItem.set(on) } catch { message = "로그인 항목 변경 실패: \(error.localizedDescription)" }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func openLog() { sh("/usr/bin/open", ["-a", "Console", Paths.log]) }

    func uninstall() async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Wi-Fi Exit 설정을 모두 지울까요?"
        alert.informativeText = "고정 라우트, pf 차단 규칙, /etc/resolver 파일, 엔진과 데몬, sudoers 규칙을 지우고 앱을 끝냅니다. 등록한 호스트는 그 뒤로 평소 경로(유선·VPN)로 나갑니다."
        alert.addButton(withTitle: "모두 지우기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        let r = await background { Engine.run(["uninstall"]) }
        busy = false
        guard r.ok else { message = "지우지 못했어요: \(r.message)"; return }
        try? LoginItem.set(false)
        NSApp.terminate(nil)
    }
}

// MARK: - CLI
//
// 같은 실행 파일이 CLI 도 맡는다. ~/.local/bin/wifi-exit 심볼릭 링크로 부르거나
// 첫 인자가 하위 명령이면 CLI 로 돌고, 그 밖에는 메뉴바 앱으로 뜬다.

@main
enum Entry {
    static func main() {
        if CLI.shouldHandle(CommandLine.arguments) {
            exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
        }
        WifiExitApp.main()
    }
}

enum CLI {
    static let commands: Set<String> = ["status", "list", "ls", "add", "set", "move", "mv", "exits", "profile", "profiles", "explain", "why", "simulate", "sim", "diag", "edit", "health", "watch", "view", "rm", "remove", "on", "off", "pause", "resume",
                                        "resolve", "apply", "log", "selftest", "install", "uninstall", "login", "help", "-h", "--help"]

    static func shouldHandle(_ argv: [String]) -> Bool {
        if let a0 = argv.first, (a0 as NSString).lastPathComponent == "wifi-exit" { return true }
        return argv.count > 1 && commands.contains(argv[1])
    }

    static let usage = """
    wifi-exit — 등록한 호스트를 정한 출구(Wi-Fi·유선·VPN…)로만 내보낸다 (Wi-Fi Exit.app 의 CLI)

    사용법
      wifi-exit status [--json]          출구·기본 경로와 규칙별 상태 (새는 대상이 있으면 종료 코드 1)
      wifi-exit list [--json]            규칙 목록 (위에서부터 적용, 한 주소에는 처음 맞는 규칙 하나)
      wifi-exit exits                    지금 쓸 수 있는 출구
      wifi-exit add <대상> [--via 출구,…] [--else block|system|next] [메모]
                                         대상 = IPv4 | IPv4/프리픽스 | 도메인 | remaining(나머지 트래픽). 이미 있으면 켜고 바꾼다
                                         출구 기본값 wifi, 없을 때 기본값 block(차단)
      wifi-exit set <대상|id> [--via 출구,…] [--else …] [--when 조건] [--name 메모]
                                         add 도 --when 을 받는다. 조건이 안 맞으면 그 규칙은 건너뛴다
                                         --check host:port 를 주면 그 출구로 여기에 닿을 때만 그 출구를 쓴다 (none: 해제)
      wifi-exit profile [add <이름> [wifi|wired|tether] | rm <이름>]
                                         지금 붙은 망(게이트웨이 IP + MAC)을 이름 붙여 저장한다
      wifi-exit edit [대상|id]            규칙 편집 창을 연다
      wifi-exit view                     라우팅 보기 창: 연결이 앱 → 규칙 → 출구로 흐르는 모습
      wifi-exit watch [--json]           규칙 대상으로 가는 새 연결을 실시간으로 한 줄씩 (Ctrl-C 로 끝).
                                         보는 동안만 엔진이 pf 기록을 켠다
      wifi-exit health                   출구 상태 점검 결과 (10초마다, 두 번 연달아 실패하면 응답 없음)
      wifi-exit health fail <출구> [초]   시험: 그 출구(wifi·wired·vpn·en0…)를 잠시 응답 없음으로 둔다 (기본 60초)
      wifi-exit health clear | check     시험 해제 | 지금 바로 점검
      wifi-exit explain <대상|IP>          어떤 규칙이 왜 걸렸는지, 조건을 사실마다 따져 보여 준다
      wifi-exit simulate [--wifi on|off] [--wired on|off] [--tether on|off] [--vpn none|any|<별칭>]
                         [--profile <이름>|none] [--time HH:MM] [--day mon…sun] [--down <출구>]
                                         그 상황이면 규칙마다 어떻게 될지 (실제로는 아무것도 바꾸지 않는다)
      wifi-exit move <대상|id> up|down|top|bottom|<위치>
      wifi-exit rm <대상|규칙 id>         지운다
      wifi-exit on|off <대상|규칙 id>     켜고 끈다 (목록에는 남긴다)
      wifi-exit pause | resume           전체 규칙을 잠시 끄고 다시 켠다
      wifi-exit resolve                  도메인을 지금 다시 푼다 (평소엔 5분마다)
      wifi-exit apply                    규칙을 지금 다시 맞춘다 (평소엔 네트워크가 바뀌는 순간·30초마다)
      wifi-exit selftest [--port N]      출구마다 직접 접속해 보고 규칙이 막는지 확인한다 (기본 443)
      wifi-exit log [줄 수]               엔진 로그
      wifi-exit install                  엔진·데몬 설치/갱신 (sudo 암호를 한 번 묻는다)
      wifi-exit uninstall                라우트·차단 규칙·데몬·엔진을 모두 지운다
      wifi-exit login [on|off]           로그인 시 앱 실행

    출구     wifi | wired(유선) | tether(iPhone USB) | vpn:<별칭>(gpvpn 포털, 예: vpn:pass) | vpn:any | none(그냥 막기)
    없을 때  block 차단(다른 길로 새지 않음) | system 평소 경로 | next 다음 규칙에 넘김
    조건     vpn=none|any|<별칭>  link=wifi|wired|tether  profile=<이름>  default=wifi|wired|tether|vpn
             vpnover=wifi|wired|tether  time=09:00-18:00  day=mon-fri
             != · and(&&) · or(||) · not(!) · 괄호.  예) --when 'vpn=pass and (link=wired or profile=사무실)'

    동작
      경로   고른 출구의 게이트웨이(VPN 은 인터페이스)로 가는 고정 라우트. 출구가 바뀌면 바로 다시 건다
      차단   pf 로 고른 출구가 아닌 인터페이스로 나가는 패킷을 거절. 출구가 없고 block 이면 모든 곳에서 거절
      도메인 고른 출구의 DNS 로 5분마다 다시 풀고, 답에서 빠진 IP 는 1시간 더 유지. /etc/resolver 로 앱 조회도 같은 DNS 로

    종료 코드: 0 성공, 1 실패, 2 사용법 오류
    """

    static func run(_ args: [String]) -> Int32 {
        var rest = args
        let cmd = rest.isEmpty ? "status" : rest.removeFirst()
        let json = take(&rest, "--json")
        switch cmd {
        case "help", "-h", "--help":
            print(usage); return 0
        case "status":
            return status(json: json, listOnly: false)
        case "list", "ls":
            return status(json: json, listOnly: true)
        case "add":
            guard let t = rest.first(where: { !$0.hasPrefix("--") }) else { return usageError("추가할 대상을 주세요.") }
            return passthrough(["add"] + rest, show: t)
        case "set":
            guard let t = rest.first else { return usageError("바꿀 대상을 주세요.") }
            return passthrough(["set"] + rest, show: t)
        case "move", "mv":
            guard rest.count == 2 else { return usageError("move <대상|id> up|down|top|bottom|<위치>") }
            return passthrough(["move"] + rest, show: nil)
        case "exits":
            guard let s = readStatus() else { return status(json: false, listOnly: false) }
            printExits(s)
            return 0
        case "profile", "profiles":
            if rest.isEmpty || rest == ["ls"] { return listProfiles() }
            guard ensureEngine() else { return 1 }
            let r = Engine.run(["profile"] + rest)
            if !r.ok { return fail(r.message) }
            print(r.out, terminator: ""); return 0
        case "explain", "why":
            guard rest.count == 1 else { return usageError("explain <대상|IP>") }
            return explain(rest[0])
        case "simulate", "sim":
            return simulate(rest)
        case "watch":
            return watch(json: json)
        case "view":
            return sh("/usr/bin/open", ["wifi-exit://routes"]).ok ? 0 : fail("라우팅 보기 창을 열지 못했어요")
        case "health":
            if let sub = rest.first {
                guard ["fail", "clear", "check"].contains(sub) else { return usageError("health [fail <출구> [초] | clear | check]") }
                guard ensureEngine() else { return 1 }
                let r = Engine.run(["health"] + rest)
                if !r.ok { return fail(r.message) }
                print(r.out, terminator: "")
            }
            return printHealth()
        case "rm", "remove":
            guard rest.count == 1 else { return usageError("대상 하나를 주세요.") }
            guard ensureEngine() else { return 1 }
            let r = Engine.run(["rm", rest[0]])
            if !r.ok { return fail(r.message) }
            print("지웠어요: \(rest[0])"); return 0
        case "on", "off":
            guard rest.count == 1 else { return usageError("대상 하나를 주세요.") }
            return passthrough([cmd, rest[0]], show: rest[0])
        case "pause", "resume", "resolve", "apply":
            return passthrough([cmd], show: nil)
        case "edit":
            // 편집 창을 연다 (앱이 꺼져 있으면 띄운다)
            if let key = rest.first {
                guard let s = readStatus(),
                      let r = s.rules.first(where: { $0.id == key || $0.targets.contains { $0.target == (Target.parse(key)?.0 ?? key) } }) else {
                    return fail("등록되지 않은 대상: \(key)")
                }
                UserDefaults(suiteName: "com.miel.WifiExit")?.set("rule:" + r.id, forKey: "pendingSelection")
            }
            return sh("/usr/bin/open", ["wifi-exit://rules"]).ok ? 0 : fail("편집 창을 열지 못했어요")
        case "diag":
            guard ensureEngine() else { return 1 }
            return shInteractive("/usr/bin/sudo", ["-n", Paths.engine, "diag"])
        case "selftest":
            guard ensureEngine() else { return 1 }
            return shInteractive("/usr/bin/sudo", ["-n", Paths.engine, "selftest"] + rest)
        case "log":
            let n = Int(rest.first ?? "50") ?? 0
            guard n > 0 else { return usageError("줄 수는 숫자로 주세요.") }
            guard let text = try? String(contentsOfFile: Paths.log, encoding: .utf8) else { return fail("로그가 없어요 (\(Paths.log))") }
            print(text.split(separator: "\n").suffix(n).joined(separator: "\n"))
            return 0
        case "install":
            let r = Engine.install(interactive: isatty(0) != 0)
            if !r.ok { return fail(r.message) }
            print("엔진과 데몬을 설치했어요.")
            return status(json: false, listOnly: false)
        case "uninstall":
            guard Engine.installedAtAll() else { print("설치돼 있지 않아요."); return 0 }
            let r = Engine.run(["uninstall"])
            if r.ok { print(r.out, terminator: ""); return 0 }
            return shInteractive("/usr/bin/sudo", [Paths.engine, "uninstall"]) == 0 ? 0 : 1
        case "login":
            return login(rest.first)
        default:
            return usageError("알 수 없는 명령: \(cmd)\n\n\(usage)")
        }
    }

    // MARK: 명령

    static func ensureEngine() -> Bool {
        if !Engine.installedAtAll() || !Engine.sudoOK() {
            _ = fail("엔진이 설치돼 있지 않아요. `wifi-exit install` 을 먼저 실행하세요.")
            return false
        }
        if !Engine.ready() {
            FileHandle.standardError.write("wifi-exit: 엔진이 앱과 버전이 달라요. `wifi-exit install` 로 갱신하세요.\n".data(using: .utf8)!)
        }
        return true
    }

    /// 엔진에 명령을 넘기고, 바뀐 결과를 보여 준다. show 가 있으면 그 대상의 규칙만, 없으면 전체.
    static func passthrough(_ args: [String], show: String?) -> Int32 {
        guard ensureEngine() else { return 1 }
        let r = Engine.run(args)
        guard r.ok else { return fail(r.message) }
        guard let s = readStatus() else { return 0 }
        let key = show.flatMap { Target.parse($0)?.0 ?? $0.lowercased() }
        if let key, let rule = s.rules.first(where: { $0.id == key || $0.targets.contains { $0.target == key } }) {
            printRule(rule, in: s)
        } else {
            printSummary(s)
            s.rules.forEach { printRule($0, in: s) }
        }
        return 0
    }

    static func status(json: Bool, listOnly: Bool) -> Int32 {
        guard let s = readStatus() else {
            return fail(Engine.installedAtAll() ? "엔진 상태 파일이 없어요 (\(Paths.status)). `wifi-exit apply` 를 실행해 보세요."
                                                : "엔진이 설치돼 있지 않아요. `wifi-exit install` 을 먼저 실행하세요.")
        }
        if json {
            let data = FileManager.default.contents(atPath: Paths.status) ?? Data()
            if listOnly, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                printJSON(obj["rules"] ?? [])
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            if !listOnly { printSummary(s) }
            if s.rules.isEmpty { print(listOnly ? "등록된 대상이 없어요." : "규칙        없음 — `wifi-exit add <IP|도메인>`") }
            else {
                if !listOnly { print("규칙") }
                s.rules.forEach { printRule($0, in: s) }
            }
            if !s.errors.isEmpty { s.errors.forEach { print("  ! \($0)") } }
        }
        return s.hasLeak || s.ageSeconds > STALE_AFTER ? 1 : 0
    }

    static func printExits(_ s: EngineStatus) {
        if s.exits.isEmpty { print("출구        없음"); return }
        for (i, e) in s.exits.enumerated() {
            let head = i == 0 ? "출구        " : "            "
            let where_ = e.gateway.isEmpty ? e.iface : "\(e.iface) → \(e.gateway)"
            let dns = e.dns.isEmpty ? "" : " · DNS \(e.dns.prefix(2).joined(separator: ", "))"
            let mark = !e.up ? "○" : e.healthy == false ? "◐" : "●"
            let health = !e.up ? "" : e.healthy == false ? " · 응답 없음" : ""
            print("\(head)\(mark) \(e.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(e.up ? "\(where_) · \(e.ip)\(dns)\(health)" : "연결 안 됨 · \(ExitWhy.reason(e.name, exits: s.exits) ?? "주소나 게이트웨이 없음")")")
        }
        // 설정에는 있는데 지금 없는 종류: 왜 없는지
        let ports = ExitWhy.ports()
        for kind in ["wifi", "wired", "tether"] where !s.exits.contains(where: { $0.name == kind })
            && !ExitWhy.ports(for: kind, in: ports).isEmpty {
            if let why = ExitWhy.reason(kind, exits: s.exits, ports: ports) {
                print("            ○ \(Exits.label(kind).padding(toLength: 12, withPad: " ", startingAt: 0)) \(why)")
            }
        }
    }

    /// 엔진의 사건 소켓에 붙어 연결을 한 줄씩 보여 준다.
    static func watch(json: Bool) -> Int32 {
        guard FileManager.default.fileExists(atPath: Paths.eventsSock) else {
            return fail("엔진이 연결 사건을 내보내지 않아요 (\(Paths.eventsSock) 없음). `wifi-exit install` 로 엔진을 갱신하세요.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Paths.eventsSock.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { return fail(errno == EACCES ? "사건 소켓에 붙을 권한이 없어요 (admin 그룹만)" : "엔진 사건 소켓에 붙지 못했어요 (errno \(errno))") }
        let color = isatty(1) != 0 && !json
        if !json {
            print("규칙 대상으로 가는 새 연결을 보여 줘요. 보는 동안만 pf 기록이 켜져요. Ctrl-C 로 끝.")
            print("시각      앱            주소                         규칙              결과")
        }
        fflush(stdout)
        var st = readStatus(), stAt = Date()
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
            while let nl = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                if json { print(String(decoding: line, as: UTF8.self)); fflush(stdout); continue }
                guard let e = try? JSONDecoder().decode(ConnEvent.self, from: line) else { continue }
                if Date().timeIntervalSince(stAt) > 2 { st = readStatus(); stAt = Date() }
                print(formatEvent(e, st, color: color)); fflush(stdout)
            }
        }
        if !json { print("엔진과 연결이 끊겼어요.") }
        return 0
    }

    static func formatEvent(_ e: ConnEvent, _ s: EngineStatus?, color: Bool) -> String {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        let time = df.string(from: Date(timeIntervalSince1970: TimeInterval(e.t) / 1000))
        let rule = s?.rules.first { $0.id == e.rule }
        let pos = s?.rules.firstIndex { $0.id == e.rule }.map { $0 + 1 }
        // 주소 → 규칙에 적힌 이름(도메인)
        let target = rule?.targets.first { t in t.target == e.dst || t.addresses.contains { $0.ip == e.dst } }?.target ?? e.dst
        let host = target == e.dst ? "\(e.dst):\(e.dport)" : "\(target):\(e.dport)"
        var who = e.app ?? ""
        if who.isEmpty, let u = e.uid, let pw = getpwuid(uid_t(u)) { who = "(\(String(cString: pw.pointee.pw_name)))" }
        if who.isEmpty { who = "?" }
        let ruleText = rule.map { "#\(pos ?? 0) \($0.title)" } ?? "규칙 ?"
        let exitInfo = s?.exits.first { $0.iface == e.iface }
        let result: String
        let tint: String
        if e.act == "pass" {
            let label = exitInfo?.label ?? e.iface
            result = "→ \(label)(\(e.iface))"
            tint = exitInfo?.name == "wifi" ? "36" : exitInfo?.name == "wired" ? "33" : exitInfo?.name == "vpn" ? "35" : "37"
        } else {
            if let a = e.allow, a != e.iface { result = "✕ 막힘 (\(e.iface)로 나가려 함 · 이 규칙은 \(a)만)" }
            else { result = "✕ 막힘 (쓸 수 있는 출구 없음)" }
            tint = "31"
        }
        func pad(_ s: String, _ n: Int) -> String {
            // 한글은 두 칸으로 센다
            let w = s.reduce(0) { $0 + ($1.unicodeScalars.first.map { $0.value >= 0x1100 ? 2 : 1 } ?? 1) }
            return w >= n ? s : s + String(repeating: " ", count: n - w)
        }
        let body = "\(time)  \(pad(who, 12)) \(pad(host + " " + e.proto, 28)) \(pad(ruleText, 16)) "
        return color ? body + "\u{1B}[\(tint)m\(result)\u{1B}[0m" : body + result
    }

    static func printHealth() -> Int32 {
        guard let s = readStatus() else { return fail("엔진 상태가 없어요") }
        let db = (FileManager.default.contents(atPath: Paths.health)).flatMap { try? JSONDecoder().decode(HealthDB.self, from: $0) } ?? HealthDB()
        let ov = (FileManager.default.contents(atPath: Paths.healthOverride)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        let nowT = Int(Date().timeIntervalSince1970)
        print("출구 상태 점검 (10초마다, 연달아 2번 실패하면 응답 없음 · 2번 성공하면 다시 씀)")
        for e in s.exits where e.up {
            let h = db.exits[e.iface]
            let state = e.healthy == false ? "◐ 응답 없음" : (h == nil ? "· 아직 점검 전" : "● 정상")
            let detail = h.map { "\($0.detail) · \(timeText($0.at))" } ?? ""
            print("  \(e.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(e.iface.padding(toLength: 7, withPad: " ", startingAt: 0)) \(state)  \(detail)")
        }
        let tests = ov.filter { $0.value > nowT }
        if !tests.isEmpty { print("  시험 중: " + tests.map { "\($0.key) (\($0.value - nowT)초 남음)" }.joined(separator: ", ")) }
        let checked = s.rules.filter { $0.check != nil }
        if !checked.isEmpty {
            print("\n규칙 점검 대상")
            for r in checked {
                let parts = db.rules.filter { $0.key.hasPrefix(r.id + "|") }.sorted { $0.key < $1.key }
                    .map { "\($0.key.split(separator: "|")[1]) \($0.value.ok ? "닿음" : "안 닿음")" }
                print("  \(r.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(r.check!)  \(parts.isEmpty ? "(아직 점검 전)" : parts.joined(separator: " · "))")
            }
        }
        return 0
    }

    static func printSummary(_ s: EngineStatus) {
        printExits(s)
        print("기본 경로    \(s.defaultIfText)")
        let rule = s.paused ? "일시정지 (등록한 대상도 평소 경로로 나감)" : (s.pfEnabled ? "켜짐" : "pf 꺼짐 — `wifi-exit apply`")
        print("규칙        \(rule) · 마지막 적용 \(timeText(s.lastApply)) · 도메인 해석 \(timeText(s.lastResolve))")
        if s.ageSeconds > STALE_AFTER {
            print("            ! 엔진이 \(s.ageSeconds)초째 상태를 갱신하지 않았어요. 데몬이 멈췄을 수 있어요 (`wifi-exit install`).")
        }
    }

    static func printRule(_ r: RuleStatus, in s: EngineStatus) {
        let st = s.state(of: r)
        let targets = r.targets.map(\.target).joined(separator: ", ")
        var line = "  \(st.cliMark) \(targets.padding(toLength: max(22, targets.count), withPad: " ", startingAt: 0))  \(s.stateText(of: r))"
        if !r.name.isEmpty { line += "  · \(r.name)" }
        print(line)
        print("      \(r.exitsText) · 없으면 \(Exits.elseLabel(r.elseAction))\(r.when.map { " · 조건 \($0)" } ?? "")\(r.check.map { " · 점검 \($0)" } ?? "") · id \(r.id)")
        if let d = r.conditionDetail { print("      ↳ \(d)") }
        for t in r.targets where t.kind == .domain {
            print("      → \(t.addresses.isEmpty ? "(아직 못 풂)" : t.addresses.map(\.ip).joined(separator: ", "))")
        }
        for a in r.addresses {
            if let o = a.owner { print("      · \(a.ip) 는 앞 규칙(\(s.rules.first { $0.id == o }?.title ?? o))이 맡음") }
            else if let n = a.note { print("      · \(a.ip): \(n)") }
            else if st == .leak && !a.blocked { print("      ! \(a.ip) 차단 규칙 없음 (지금 경로 \(a.interface.isEmpty ? "?" : a.interface))") }
        }
    }

    static func loadConfigFile() -> EngineConfig? {
        guard let d = FileManager.default.contents(atPath: Paths.config) else { return nil }
        return try? JSONDecoder().decode(EngineConfig.self, from: d)
    }

    /// status.json 의 출구로 지금 사실을 만든다 (vpnover 는 엔진이 알려 준 값을 쓴다).
    static func facts(_ s: EngineStatus, _ c: EngineConfig) -> Facts {
        Facts(exits: s.exits, profiles: c.profiles, defaultIf: s.defaultIf, vpnOver: s.vpnOver ?? "", date: Date())
    }

    static func listProfiles() -> Int32 {
        guard let c = loadConfigFile() else { return fail("설정을 읽지 못했어요 (\(Paths.config))") }
        if c.profiles.isEmpty { print("저장한 프로필이 없어요. `wifi-exit profile add <이름> [wifi|wired]` 로 지금 망을 저장하세요."); return 0 }
        let f = readStatus().map { facts($0, c) }
        for (name, p) in c.profiles.sorted(by: { $0.key < $1.key }) {
            let here = f?.profileMatches(name) == true
            print("\(here ? "●" : "○") \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(Exits.label(p.link)) 게이트웨이 \(p.gateway)\(p.gatewayMac.isEmpty ? "" : " (\(p.gatewayMac))")\(here ? "  ← 지금 여기" : "")")
        }
        return 0
    }

    static func explain(_ raw: String) -> Int32 {
        guard let s = readStatus() else { return fail("엔진 상태가 없어요") }
        let key = Target.parse(raw)?.0 ?? raw.lowercased()
        let hits = s.rules.filter { r in r.id == key || r.targets.contains { $0.target == key || $0.addresses.contains { $0.ip == key || targetCovered(key, by: $0.ip) } } }
        if hits.isEmpty { print("\(raw): 어느 규칙에도 없어요 → 평소 경로(\(s.defaultIfText))로 나가요"); return 0 }
        print("\(raw) 를 다루는 규칙 (위에서부터 처음 맞는 규칙 하나가 맡음)\n")
        var decided = false
        for r in hits {
            let pos = (s.rules.firstIndex { $0.id == r.id } ?? 0) + 1
            print("  #\(pos) \(r.title)  [\(s.stateText(of: r))]")
            print("      출구 \(r.exitsText) · 없으면 \(Exits.elseLabel(r.elseAction))")
            if let w = r.when { print("      조건 \(w)") }
            if let d = r.conditionDetail { print("           \(d)") }
            print("      → \(r.reason)")
            let owned = r.addresses.filter { $0.ip == key || r.targets.contains { $0.target == key } }
            if let shadow = owned.first(where: { $0.owner != nil }), let o = shadow.owner {
                print("      · 이 주소는 앞 규칙(\(s.rules.first { $0.id == o }?.title ?? o))이 이미 맡았어요")
            } else if !decided, ["route", "block", "system"].contains(r.decision) {
                decided = true
                print("      ★ 이 규칙이 적용돼요")
            }
            print("")
        }
        if !decided { print("맞는 규칙이 없어 평소 경로(\(s.defaultIfText))로 나가요") }
        return 0
    }

    static func simulate(_ args: [String]) -> Int32 {
        guard let s = readStatus(), let c = loadConfigFile() else { return fail("엔진 상태나 설정을 읽지 못했어요") }
        var f = facts(s, c)
        var exits = s.exits
        var i = 0
        func setLink(_ name: String, _ v: String) -> Bool {
            guard v == "on" || v == "off" else { return false }
            if let k = exits.firstIndex(where: { $0.name == name }) { exits[k].up = v == "on" }
            else if v == "on" { exits.append(ExitInfo(name: name, iface: "(\(name))", ip: "0.0.0.1", gateway: "0.0.0.1", dns: [], portal: "", up: true)) }
            return true
        }
        while i < args.count {
            let a = args[i], v = i + 1 < args.count ? args[i + 1] : ""
            switch a {
            case "--wifi", "--wired", "--tether":
                guard setLink(String(a.dropFirst(2)), v) else { return usageError("\(a) on|off") }
            case "--vpn":
                exits.removeAll { $0.name == "vpn" }
                if v != "none" {
                    guard v == "any" || Exits.isValid("vpn:" + v) else { return usageError("--vpn none|any|<별칭>") }
                    exits.append(ExitInfo(name: "vpn", iface: "utun(가정)", ip: "0.0.0.1", gateway: "", dns: [], portal: v == "any" ? "" : v, up: true))
                }
            case "--down":
                var hit = false
                for k in exits.indices where exits[k].name == v || exits[k].iface == v || (v == "vpn" && exits[k].name == "vpn") {
                    exits[k].healthy = false; hit = true
                }
                guard hit else { return usageError("--down <wifi|wired|tether|vpn|인터페이스> (지금 연결된 출구)") }
            case "--profile":
                f.forcedProfiles = v == "none" ? [] : [v.precomposedStringWithCanonicalMapping]
            case "--time", "--day":
                var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: f.date)
                if a == "--time" {
                    let p = v.split(separator: ":").compactMap { Int($0) }
                    guard p.count == 2 else { return usageError("--time HH:MM") }
                    comps.hour = p[0]; comps.minute = p[1]
                    f.date = Calendar.current.date(from: comps) ?? f.date
                } else {
                    guard let wd = Condition.days.firstIndex(of: v.lowercased()) else { return usageError("--day mon…sun") }
                    let cur = Calendar.current.component(.weekday, from: f.date) - 1
                    f.date = f.date.addingTimeInterval(Double((wd - cur + 7) % 7) * 86400)
                }
            default:
                return usageError("알 수 없는 옵션: \(a)")
            }
            i += 2
        }
        f.exits = exits
        // 기본 경로·VPN 하부 링크도 가정에 맞춰 다시 짐작한다
        let vpnUp = exits.contains { $0.name == "vpn" && $0.up }
        let phys = ["wired", "wifi", "tether"].first { n in exits.contains { $0.name == n && $0.up } }
        f.defaultIf = vpnUp ? (exits.first { $0.name == "vpn" }?.iface ?? "") : (phys.flatMap { n in exits.first { $0.name == n }?.iface } ?? "")
        if vpnUp, !exits.contains(where: { $0.name == f.vpnOver && $0.up }) { f.vpnOver = phys ?? "" }
        if !vpnUp { f.vpnOver = "" }

        let up = f.up.map { e in e.name == "vpn" ? "VPN:\(e.portal.isEmpty ? "any" : e.portal)" : Exits.label(e.name) }
        print("가정: 출구 \(up.isEmpty ? "없음" : up.joined(separator: ", ")) · 기본 경로 \(f.defaultLink.isEmpty ? "없음" : f.defaultLink)\(f.vpnOver.isEmpty ? "" : " · VPN 하부 \(f.vpnOver)")\(f.forcedProfiles.map { " · 프로필 \($0.isEmpty ? "없음" : $0.joined(separator: ","))" } ?? "")")
        let df = DateFormatter(); df.dateFormat = "EEE HH:mm"; df.locale = Locale(identifier: "ko_KR")
        print("      시각 \(df.string(from: f.date))  (실제로는 아무것도 바꾸지 않아요)\n")
        var claimed = Set<String>()
        for (n, r) in c.rules.enumerated() {
            let o = c.paused ? Outcome.off : decide(r, facts: f)
            let mark: String
            switch o {
            case .route(let name, _): mark = "→ \(Exits.label(name))"
            case .block: mark = "⊘ 차단"
            case .system: mark = "· 평소 경로"
            case .next: mark = "↓ 다음 규칙"
            case .skip: mark = "↓ 조건 안 맞음"
            case .off: mark = "- 꺼짐"
            }
            let targets = r.targets.joined(separator: ", ")
            let shadow = r.targets.filter { claimed.contains($0) }
            if case .route = o { claimed.formUnion(r.targets) } else if case .block = o { claimed.formUnion(r.targets) } else if case .system = o { claimed.formUnion(r.targets) }
            print("  #\(n + 1) \(mark.padding(toLength: 14, withPad: " ", startingAt: 0)) \(targets)\(r.name.isEmpty ? "" : "  · \(r.name)")")
            print("       \(reasonText(r, o, facts: f, paused: c.paused))\(shadow.isEmpty ? "" : " (앞 규칙이 이미 맡음: \(shadow.joined(separator: ", ")))")")
        }
        return 0
    }

    static func login(_ arg: String?) -> Int32 {
        switch arg {
        case nil:
            print(LoginItem.text == "enabled" ? "켜짐" : "꺼짐 (\(LoginItem.text))"); return 0
        case "on", "off":
            do { try LoginItem.set(arg == "on") } catch { return fail("로그인 항목 변경 실패: \(error.localizedDescription)") }
            print(LoginItem.text == "enabled" ? "켜짐" : "꺼짐"); return 0
        default:
            return usageError("login [on|off]")
        }
    }

    // MARK: 도구

    static func take(_ args: inout [String], _ flag: String) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }
        args.remove(at: i); return true
    }
    static func printJSON(_ obj: Any) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    }
    static func fail(_ msg: String) -> Int32 {
        // 엔진이 이미 "wifi-exit: " 를 붙여 내보낸 메시지는 한 번만 붙인다.
        let m = msg.split(separator: "\n").map { $0.hasPrefix("wifi-exit: ") ? String($0) : "wifi-exit: \($0)" }.joined(separator: "\n")
        FileHandle.standardError.write("\(m)\n".data(using: .utf8)!); return 1
    }
    static func usageError(_ msg: String) -> Int32 {
        FileHandle.standardError.write("wifi-exit: \(msg)\n".data(using: .utf8)!); return 2
    }
}

// MARK: - 화면

struct WifiExitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Wi-Fi Exit 규칙", id: "rules") {
            RulesWindow().environmentObject(model)
                .onOpenURL { _ in
                    model.reloadStatus()          // CLI 가 남긴 선택을 바로 반영
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 900, height: 620)
        .handlesExternalEvents(matching: ["rules"])

        Window("라우팅 보기", id: "routes") {
            RoutesWindow().environmentObject(model)
                .onOpenURL { _ in NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1080, height: 700)
        .handlesExternalEvents(matching: ["routes"])

        // 개발용: 메뉴바 팝업 내용을 보통 창으로 (wifi-exit://popup-preview) — 화면 확인용
        Window("팝업 미리보기", id: "popup-preview") {
            ContentView().environmentObject(model)
                .background(.regularMaterial)
                .onOpenURL { _ in NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["popup-preview"])
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var newTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let msg = m.message {
                Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            let ws = m.warnings
            if !ws.isEmpty {
                VStack(spacing: 6) { ForEach(ws) { w in warningBand(w) } }
            }
            if let s = m.status {
                tiles(s)
                ruleList(s)
                addRow
            }
            menuRows
        }
        .padding(12)
        .frame(width: 340)
        .task { await m.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await m.refresh() }
        }
    }

    // MARK: 머리: 상태 기호 + 요약 + 전체 켜기

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(level: m.statusLevel, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if m.busy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { !(m.status?.paused ?? false) }, set: { on in Task { await m.setPaused(!on) } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!m.engineReady || m.busy)
                .help("Wi-Fi Exit 켜기 (끄면 일시정지: 등록한 대상도 평소 경로로)")
        }
        .padding(.horizontal, 2)
    }

    private var title: String {
        let n = m.warnings.count
        if n > 0 { return "확인할 것 \(n)개" }
        guard let s = m.status else { return "Wi-Fi Exit" }
        return s.activeCount == 0 ? "켜진 규칙 없음" : "규칙 \(s.activeCount)개 적용 중"
    }
    private var subtitle: String {
        guard let s = m.status else { return "엔진 상태를 읽는 중" }
        return "기본 경로 \(s.defaultIfText) · \(timeText(s.lastApply)) 적용"
    }

    private func warningBand(_ w: AppWarning) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(w.title).font(.system(size: 12.5, weight: .semibold))
                Text(w.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let a = w.action, let l = w.actionLabel {
                Button(l) { run(a) }.controlSize(.small).disabled(m.busy)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill((w.level == .error ? Color.red : Color.orange).opacity(0.14)))
    }

    private func run(_ a: AppWarning.Action) {
        switch a {
        case .installEngine: Task { await m.installEngine() }
        case .apply: Task { await m.apply() }
        case .resume: Task { await m.setPaused(false) }
        case .openRules: openRules(nil)
        }
    }

    // MARK: 출구 타일

    private struct Tile: Identifiable { let id: String; let kind: String; let label: String; let detail: String; let up: Bool; let warn: Bool }

    private func tileList(_ s: EngineStatus) -> [Tile] {
        var out = s.exits.map { e in
            Tile(id: e.iface, kind: e.name, label: e.label, detail: !e.up ? "연결 안 됨" : e.healthy == false ? "응답 없음" : e.iface,
                 up: e.up, warn: e.up && e.healthy == false)
        }
        // 설정에는 있는데 지금 없는 Wi-Fi·유선: 흐리게, 까닭과 함께
        let ports = ExitWhy.ports()
        for kind in ["wifi", "wired"] where !s.exits.contains(where: { $0.name == kind }) && !ExitWhy.ports(for: kind, in: ports).isEmpty {
            out.append(Tile(id: "absent-\(kind)", kind: kind, label: Exits.label(kind),
                            detail: ExitWhy.reason(kind, exits: s.exits, ports: ports) ?? "지금 없음", up: false, warn: false))
        }
        return out
    }

    private func tiles(_ s: EngineStatus) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(tileList(s)) { t in
                VStack(alignment: .leading, spacing: 3) {
                    ExitBadge(name: t.kind, off: !t.up, size: 20)
                    Text(t.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(t.detail).font(.system(size: 10.5, design: t.up && !t.warn ? .monospaced : .default))
                        .foregroundStyle(t.warn ? Color.orange : Color.secondary).lineLimit(1).truncationMode(.tail)
                        .help(t.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055)))
                .opacity(t.up ? 1 : 0.6)
            }
        }
    }

    // MARK: 규칙

    private func ruleList(_ s: EngineStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("규칙").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("위에서부터").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            if s.rules.isEmpty {
                Text("등록된 규칙이 없어요").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(s.rules) { r in PopupRuleRow(rule: r, state: s.state(of: r), onOpen: { openRules(r.id) }) }
                    }
                }
                // MenuBarExtra 창 안의 ScrollView 는 이상 높이가 없어 줄어든다. 높이를 직접 준다 (8줄 넘으면 스크롤).
                .frame(height: CGFloat(min(s.rules.count, 8)) * 44)
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").foregroundStyle(.secondary)
            TextField("", text: $newTarget, prompt: Text("대상 추가 (IP, 대역, 도메인) — Return"))
                .textFieldStyle(.plain).onSubmit(add)
                .disabled(!m.engineReady || m.busy)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
    }

    private func add() {
        let t = newTarget
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newTarget = ""
        Task { await m.add(t, note: "") }
    }

    // MARK: 메뉴 줄

    private var menuRows: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 4)
            MenuRow(title: "규칙 편집…", shortcut: "⌘,") { openRules(nil) }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "라우팅 보기…", shortcut: "⌘R") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "routes")
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider().padding(.vertical, 4)
            Menu {
                Section {
                    Button("지금 다시 적용") { Task { await m.apply() } }
                    Button("도메인 다시 풀기") { Task { await m.resolve() } }
                    Button("지금 망을 프로필로 저장…") { Task { await m.saveProfile() } }
                    Button("로그 보기") { m.openLog() }
                }
                Section {
                    Toggle("로그인 시 실행", isOn: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) }))
                }
                Section {
                    Button(m.engineOutdated ? "엔진 갱신" : "엔진 다시 설치") { Task { await m.installEngine() } }
                }
                Section {
                    Button("설정 모두 지우기…", role: .destructive) { Task { await m.uninstall() } }
                }
            } label: {
                HStack {
                    Text("더 보기")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(m.busy)
            MenuRow(title: "Wi-Fi Exit 종료", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func openRules(_ id: String?) {
        m.windowSelection = id.map { "rule:" + $0 } ?? m.windowSelection ?? m.config?.rules.first.map { "rule:" + $0.id }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "rules")
    }
}

/// 팝업의 규칙 한 줄: 지금 나가는 출구 기호 + 이름 + 어디로 보내는 중 + 스위치. 줄을 누르면 편집 창.
struct PopupRuleRow: View {
    @EnvironmentObject var m: AppModel
    let rule: RuleStatus
    let state: RuleState
    let onOpen: () -> Void
    @State private var hover = false

    private var shadowed: String? { m.config?.rules.first { $0.id == rule.id }.flatMap { m.shadowedBy($0) } }

    var body: some View {
        HStack(spacing: 10) {
            ExitBadge(name: rule.nowExit ?? rule.exits.first.map(Exits.kind) ?? "block",
                      off: !rule.enabled || rule.nowExit == nil, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Group {
                    if !rule.enabled { Text("꺼짐").foregroundStyle(.secondary) }
                    else if m.status?.paused == true { Text("일시정지 중 · 평소 경로로 나감").foregroundStyle(.secondary) }
                    else if state == .leak { Text("차단이 빠짐 · 다시 적용 필요").foregroundStyle(.red) }
                    else if let by = shadowed { Text("⚠︎ 앞 규칙 \"\(by)\"에 가려져 적용 안 됨").foregroundStyle(.orange) }
                    else { Text(rule.nowText + (rule.targets.first.map { " · " + $0.target } ?? "")).foregroundStyle(.secondary) }
                }
                .font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .help(rule.reason)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in Task { await m.setEnabled(rule.id, on) } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(!m.engineReady || m.busy)
        }
        .padding(.horizontal, 6).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
    }
}

/// 메뉴 항목처럼 보이는 줄 (마우스를 올리면 강조색)
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary) }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ExitChip: View {
    let name: String
    let label: String
    var detail: String? = nil
    var active = true
    var rank: Int? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let rank { Text("\(rank)").font(.system(size: 9, weight: .bold, design: .monospaced)).opacity(0.7) }
            Text(label).font(.system(size: 10.5, weight: .medium))
            if let detail { Text(detail).font(.system(size: 9.5, design: .monospaced)).opacity(0.7) }
        }
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .foregroundStyle(active ? Color.exit(name) : Color.secondary)
        .background(Capsule().fill((active ? Color.exit(name) : Color.secondary).opacity(active ? 0.16 : 0.08)))
        .overlay(Capsule().strokeBorder(active ? .clear : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [2])))
    }
}

struct RuleRowView: View {
    @EnvironmentObject var m: AppModel
    let rule: RuleStatus
    let index: Int
    let count: Int
    let state: RuleState
    let stateText: String
    @State private var hover = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in Task { await m.setEnabled(rule.id, on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!m.engineReady || m.busy)
                Image(systemName: state.symbol).foregroundStyle(state.color).frame(width: 16)
                    .help(rule.reason)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(rule.targets.map(\.target).joined(separator: ", "))
                            .font(.system(.callout, design: .monospaced).bold()).lineLimit(1)
                        if !rule.name.isEmpty {
                            Text(rule.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    HStack(spacing: 3) {
                        if rule.exits.isEmpty { ExitChip(name: "block", label: "그냥 막기", active: false) }
                        ForEach(Array(rule.exits.enumerated()), id: \.element) { i, e in
                            ExitChip(name: e, label: Exits.label(e), active: rule.chosenExit == e, rank: rule.exits.count > 1 ? i + 1 : nil)
                        }
                        Text("· 없으면 \(Exits.elseLabel(rule.elseAction))").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if let d = rule.conditionDetail {
                        Text("조건 \(d)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(rule.decision == "skip" ? Color.orange : Color.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(detail).font(.caption2).foregroundStyle(state == .leak ? Color.red : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if hover {
                    Button {
                        m.windowSelection = "rule:" + rule.id
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "rules")
                    } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("편집 창에서 고치기")
                    Button { Task { await m.remove(rule.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("목록에서 지우기")
                        .disabled(!m.engineReady || m.busy)
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .onHover { hover = $0 }
    }

    private var detail: String {
        var parts = [stateText]
        let ips = rule.targets.filter { $0.kind == .domain }.flatMap(\.addresses).map(\.ip)
        if !ips.isEmpty { parts.append(ips.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
