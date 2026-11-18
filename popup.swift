// 메뉴바 아이콘과 팝업. 모양은 VPN Bar 와 같은 말(글래스 팝업, 동심 모서리, 조용한 글자)을 쓰고,
// 짜임새는 Little Snitch 의 Control Center 를 참고했다: 맨 위 주 스위치 타일(전체 켜기, 지금 망, 앱별 스플리팅),
// 출구마다 그리로 나가는 규칙을 묶은 카드, 빨간 수를 단 "막는 중" 카드, 쉬는 규칙, 아래 줄의 창 단추.

import AppKit
import Combine
import SwiftUI

/// 메뉴바 아이콘 + 팝업. NSPopover 는 내용 크기를 따라가므로 상태가 바뀌어 줄이 늘고 줄어도 깔끔하다.
/// (MenuBarExtra 창은 크기·활성화·애니메이션을 다룰 수 없었다.)
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: ContentView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSApp.appearance   // dev.sh --dark | --light 가 정했으면 그 모양, 아니면 시스템을 따른다
        popover.delegate = self

        if let b = item.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.setAccessibilityLabel("Wi-Fi Exit")
        }
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &bag)
        updateButton()
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { popover.animates = true; popover.performClose(sender); return }
        guard let b = item.button else { return }
        popover.animates = true
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        focusPopover()
    }

    /// 여닫을 때만 움직인다. 떠 있는 동안 animates 가 켜져 있으면 내용 크기 변화도 움직이는데,
    /// macOS 27 은 그것을 튀는 스프링으로 그려 경고 띠가 생기고 사라질 때 팝업이 출렁였다.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover.animates = true
        return true
    }

    /// 팝업이 활성 앱의 키 창이어야 SwiftUI 가 마우스 올림을 받고 첫 클릭을 삼키지 않는다. macOS 14 부터
    /// 활성화는 나중에 끝나는 요청이고, 팝업이 다 뜨기 전에 키 창으로 만들면 남지 않으므로 뜬 뒤에 다시 청한다.
    func popoverDidShow(_ notification: Notification) {
        popover.animates = false
        focusPopover()
    }

    private func focusPopover() {
        NSApp.activate()
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeKey()
        // 키 창이 되면 AppKit 이 첫 입력 칸(대상 추가)에 커서를 놓는다. 열자마자 커서가 깜박이지 않게 비운다.
        window.makeFirstResponder(nil)
    }

    private func updateButton() {
        guard let b = item.button else { return }
        let img = NSImage(systemSymbolName: model.menuSymbol, accessibilityDescription: "Wi-Fi Exit")
        img?.isTemplate = true
        b.image = img
        b.toolTip = "Wi-Fi Exit"
    }
}

/// 팝업 가장자리 → 카드(edge), 카드 사이(gap), 카드 가장자리 → 줄 강조(card), 줄 강조 → 글자(text).
enum PopupInset {
    static let edge: CGFloat = 8
    static let gap: CGFloat = 8
    static let card: CGFloat = 4
    static let text: CGFloat = 8
    /// 출구 기호 칸. 규칙 줄은 이만큼 들여 써서 출구 이름과 같은 선에 선다.
    static let icon: CGFloat = 22
}

/// 카드는 팝업 가장자리에서 edge 만큼, 줄 강조는 카드 가장자리에서 card 만큼 들어와 있으므로
/// 반지름도 그만큼씩 줄여 동심으로 둔다. NSPopover 의 모서리는 macOS 26 이후 20pt 로 쟀다.
enum PopupCorner {
    static var panel: CGFloat {
        if #available(macOS 26, *) { return 20 }
        return 13
    }
    static var card: CGFloat { max(6, panel - PopupInset.edge) }
    static var row: CGFloat { max(4, card - PopupInset.card) }
    static var inner: CGFloat { card }
}

/// 팝업 위의 옅은 판 하나. 글래스 팝업 위에서 내용을 묶는다 (Little Snitch 의 Control Center 처럼).
struct PopupCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(PopupInset.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PopupCorner.card, style: .continuous)
                .fill(tint.map { $0.opacity(0.12) } ?? Color.cardFill))
    }
}

/// 맨 위 타일과 아래 단추의 공통 모양: 카드처럼 옅게, 올리면 조금 진하게, 누르면 더 진하게.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }

    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: PopupCorner.card, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.14) : hover && isEnabled ? Color.primary.opacity(0.09) : Color.cardFill))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hover = $0 }
        }
    }
}

/// 타일 기호 판의 칠: 무채색(정상·켜짐), 호박색(주의), 산호색(오류), 옅은 회색(꺼짐). 모두 단색.
enum TileTone {
    case brand, warn, error, off

    @ViewBuilder var fill: some View {
        switch self {
        case .brand: Color.solidFill
        case .warn: Color.brandAmber
        case .error: Color.brandCoral
        case .off: Color.secondary.opacity(0.18)
        }
    }
    /// 호박색 위에는 흰 기호가 묻히므로 아이콘처럼 남색 기호
    var glyph: Color {
        switch self {
        case .brand: return .onSolidFill
        case .error: return .white
        case .warn: return .brandInk
        case .off: return .secondary
        }
    }
    /// 타일 아래 줄 글자 색
    var text: Color {
        switch self {
        case .brand: return .statusOK
        case .warn: return .statusWarn
        case .error: return .statusError
        case .off: return .secondary
        }
    }
}

private struct TileIcon: View {
    let symbol: String
    let tone: TileTone
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tone.glyph)
            .frame(width: size, height: size)
            .background(tone.fill.clipShape(RoundedRectangle(cornerRadius: PopupCorner.row, style: .continuous)))
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var newTarget = ""

    /// 일시정지는 맨 위 타일이 말하므로 경고 카드에 다시 넣지 않는다.
    private var issues: [AppWarning] { m.warnings.filter { $0.id != "paused" } }

    var body: some View {
        VStack(alignment: .leading, spacing: PopupInset.gap) {
            tiles
            if let msg = m.message { errorCard(msg) }
            if !issues.isEmpty { issueCard }
            if let s = m.status {
                ruleCards(s)
                addField
            }
            bottomBar
        }
        .padding(PopupInset.edge)
        .frame(width: 344)
        .task { await m.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await m.refresh() }
        }
    }

    // MARK: 맨 위 타일 — Little Snitch 의 주 스위치 줄: 전체 켜고 끄기, 지금 망(프로필), 앱별 스플리팅

    private var tiles: some View {
        HStack(spacing: PopupInset.gap) {
            hostTile
            profileTile
            splitTile.frame(width: 52)
        }
        .frame(height: 52)
    }

    /// 호스트 규칙 전체 스위치. 누르면 일시정지하고, 다시 누르면 켠다. 색은 상태를 따른다.
    private var hostTile: some View {
        let paused = m.status?.paused == true
        return Button {
            Task { await m.setPaused(!paused) }
        } label: {
            HStack(spacing: 8) {
                TileIcon(symbol: hostSymbol, tone: hostTone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hostTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(statusWord).font(.system(size: 11)).foregroundStyle(hostTone.text).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(!m.engineReady || m.busy)
        .help(paused ? "눌러서 다시 켜기" : "눌러서 모두 일시정지")
        .accessibilityLabel(paused ? "호스트 규칙 다시 켜기" : "호스트 규칙 일시정지")
    }

    private var hostTitle: String {
        guard let s = m.status else { return "호스트 규칙" }
        return s.activeCount == 0 ? "규칙 없음" : "규칙 \(s.activeCount)개"
    }

    private var hostSymbol: String {
        switch m.overall {
        case .needsEngine: return "wrench.and.screwdriver.fill"
        case .stale, .leak: return "exclamationmark.triangle.fill"
        case .paused: return "pause.fill"
        default: return issues.isEmpty ? "checkmark" : "exclamationmark"
        }
    }

    private var hostTone: TileTone {
        switch m.statusLevel {
        case .off: return .off
        case .error: return .error
        case .warn: return .warn
        case .ok: return m.overall == .idle || m.overall == .needsEngine ? .off : .brand
        }
    }

    private var statusWord: String {
        switch m.overall {
        case .needsEngine: return "엔진 없음"
        case .stale: return "엔진 멈춤"
        case .paused: return "일시정지"
        case .leak: return "차단 빠짐"
        default:
            let n = issues.count
            if n > 0 { return "확인 \(n)" }
            return m.overall == .idle ? "대기" : "정상"
        }
    }

    /// 지금 망: 저장한 네트워크 프로필 중 지금 게이트웨이와 맞는 것. 누르면 프로필 메뉴.
    private var profileTile: some View {
        let here = m.profileNames.first { m.profileHere($0) }
        return Menu {
            if m.profileNames.isEmpty { Text("프로필 없음") }
            ForEach(m.profileNames, id: \.self) { name in
                Button { openWindow(select: "profile:" + name) } label: {
                    if name == here { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("지금 망을 프로필로 저장…") { Task { await m.saveProfile() } }
        } label: {
            HStack(spacing: 8) {
                TileIcon(symbol: "mappin.and.ellipse", tone: .off)
                VStack(alignment: .leading, spacing: 1) {
                    Text("지금 망").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(here ?? "미등록").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(here == nil ? .secondary : .primary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(TileButtonStyle())
        .disabled(m.status == nil)
        .help("게이트웨이 주소와 MAC으로 가린 망")
    }

    /// 앱별 스플리팅: 켜져 있으면 색. 누르면 그 창.
    private var splitTile: some View {
        Button { AppWindows.open("app-rules") } label: {
            VStack(spacing: 3) {
                TileIcon(symbol: "arrow.triangle.branch", tone: m.splitEnabled ? .brand : .off, size: 26)
                Text("앱별").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TileButtonStyle())
        .help(m.splitEnabled ? "앱별 스플리팅 켜짐" : "앱별 스플리팅 꺼짐")
        .accessibilityLabel("앱별 스플리팅")
    }

    // MARK: 확인할 것

    private var issueCard: some View {
        let error = issues.contains { $0.level == .error }
        return PopupCard(tint: error ? .statusError : .statusWarn) {
            ForEach(issues) { w in
                HStack(spacing: 8) {
                    Image(systemName: w.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(w.level == .error ? Color.statusError : Color.statusWarn)
                        .frame(width: PopupInset.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.title).font(.system(size: 12, weight: .semibold))
                        if !w.detail.isEmpty {
                            Text(w.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if let a = w.action, let l = w.actionLabel {
                        Button(l) { run(a) }.controlSize(.small).disabled(m.busy)
                    }
                }
                .padding(.horizontal, PopupInset.text).padding(.vertical, 6)
            }
        }
    }

    private func errorCard(_ e: String) -> some View {
        PopupCard(tint: .statusError) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.statusError)
                    .frame(width: PopupInset.icon)
                Text(e).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { m.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("닫기")
            }
            .padding(.horizontal, PopupInset.text).padding(.vertical, 6)
        }
    }

    private func run(_ a: AppWarning.Action) {
        switch a {
        case .installEngine: Task { await m.installEngine() }
        case .apply: Task { await m.apply() }
        case .resume: Task { await m.setPaused(false) }
        case .openRules: openWindow(select: nil)
        }
    }

    // MARK: 규칙 카드 — 출구마다 그리로 나가는 규칙, 막는 규칙, 쉬는 규칙

    private struct ExitGroup: Identifiable {
        let id: String; let kind: String; let label: String; let detail: String; let help: String; let up: Bool; let warn: Bool
        var rules: [RuleStatus] = []
    }

    private func exitGroups(_ s: EngineStatus) -> [ExitGroup] {
        var out = s.exits.map { e -> ExitGroup in
            let unhealthy = e.up && e.healthy == false
            let detail = !e.up ? "연결 안 됨" : unhealthy ? "응답 없음" : [e.iface, e.ip].filter { !$0.isEmpty }.joined(separator: " · ")
            let help = [e.gateway.isEmpty ? e.iface : "\(e.iface) → \(e.gateway)", e.dns.isEmpty ? "" : "DNS \(e.dns.prefix(2).joined(separator: ", "))",
                        e.healthDetail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            let rules = s.paused ? [] : s.rules.filter { $0.enabled && $0.decision == "route" && $0.chosenIface == e.iface }
            return ExitGroup(id: e.iface, kind: e.name, label: e.label, detail: detail, help: help, up: e.up, warn: unhealthy, rules: rules)
        }
        // 설정에는 있는데 지금 없는 Wi-Fi·유선: 흐리게, 까닭과 함께
        let ports = ExitWhy.ports()
        for kind in ["wifi", "wired"] where !s.exits.contains(where: { $0.name == kind }) && !ExitWhy.ports(for: kind, in: ports).isEmpty {
            let why = ExitWhy.reason(kind, exits: s.exits, ports: ports) ?? "지금 없음"
            out.append(ExitGroup(id: "absent-\(kind)", kind: kind, label: Exits.label(kind), detail: why, help: why, up: false, warn: false))
        }
        return out
    }

    private func blockedRules(_ s: EngineStatus) -> [RuleStatus] {
        s.paused ? [] : s.rules.filter { $0.enabled && $0.decision == "block" }
    }

    /// 지금 아무 출구도 정하지 않은 규칙: 꺼짐, 조건 안 맞음, 다음 규칙·평소 경로로 넘김, 일시정지
    private func restingRules(_ s: EngineStatus) -> [RuleStatus] {
        let shown = Set(exitGroups(s).flatMap(\.rules).map(\.id) + blockedRules(s).map(\.id))
        return s.rules.filter { !shown.contains($0.id) }
    }

    @ViewBuilder private func ruleCards(_ s: EngineStatus) -> some View {
        let cards = VStack(spacing: PopupInset.gap) {
            exitCard(s)
            let blocked = blockedRules(s)
            if !blocked.isEmpty { blockCard(blocked, s) }
            let resting = restingRules(s)
            if !resting.isEmpty { restCard(resting, paused: s.paused) }
        }
        // NSPopover 는 내용 높이를 따라가므로 규칙이 많을 때만 높이를 정해 스크롤한다.
        if s.rules.count + s.exits.count > 14 {
            ScrollView { cards }.frame(height: 480)
        } else {
            cards
        }
    }

    private func exitCard(_ s: EngineStatus) -> some View {
        PopupCard {
            ForEach(exitGroups(s)) { g in
                HStack(spacing: 8) {
                    // 출구는 색 없는 기호로 가른다. 색은 상태(응답 없음 = 주황)에만 쓴다.
                    Image(systemName: Exits.symbol(g.kind))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(!g.up ? Color.secondary.opacity(0.5) : g.warn ? Color.statusWarn : Color.secondary)
                        .frame(width: PopupInset.icon)
                    Text(g.label).font(.system(size: 13, weight: .medium)).foregroundStyle(g.up ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(g.detail).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(g.warn ? Color.statusWarn : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, PopupInset.text).frame(minHeight: 30)
                .contentShape(Rectangle())
                .help(g.help)
                ForEach(g.rules) { r in
                    RuleLine(rule: r, detail: routedDetail(r, s), detailColor: routedColor(r, s), onOpen: { openWindow(select: "rule:" + r.id) })
                }
            }
        }
    }

    private func routedDetail(_ r: RuleStatus, _ s: EngineStatus) -> String {
        if s.state(of: r) == .leak { return "차단 빠짐" }
        if let by = shadowedBy(r) { return "\(by)에 가려짐" }
        return targetsText(r)
    }

    private func routedColor(_ r: RuleStatus, _ s: EngineStatus) -> Color {
        if s.state(of: r) == .leak { return .statusError }
        return shadowedBy(r) == nil ? .secondary : .statusWarn
    }

    private func shadowedBy(_ r: RuleStatus) -> String? {
        m.config?.rules.first { $0.id == r.id }.flatMap { m.shadowedBy($0) }
    }

    /// "git.example.com" / "203.0.113.0/24 외 2개". 이름 없는 규칙은 제목이 곧 첫 대상이라 나머지만.
    private func targetsText(_ r: RuleStatus) -> String {
        let ts = r.targets.map(\.target)
        guard let first = ts.first else { return "" }
        if first == r.title { return ts.count > 1 ? "외 \(ts.count - 1)개" : r.exitsText }
        return ts.count > 1 ? "\(first) 외 \(ts.count - 1)개" : first
    }

    /// Little Snitch 의 "Recently Denied" 처럼 빨간 수 표시를 단 카드
    private func blockCard(_ rules: [RuleStatus], _ s: EngineStatus) -> some View {
        PopupCard {
            HStack(spacing: 8) {
                Text("\(rules.count)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .frame(minWidth: PopupInset.icon, minHeight: 18).background(Capsule().fill(Color.brandCoral))
                Text("막는 중").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, PopupInset.text).frame(minHeight: 30)
            ForEach(rules) { r in
                RuleLine(rule: r, detail: r.exits.isEmpty ? "늘 막기" : r.exitsText + " 없음",
                         onOpen: { openWindow(select: "rule:" + r.id) })
            }
        }
    }

    private func restCard(_ rules: [RuleStatus], paused: Bool) -> some View {
        PopupCard {
            HStack(spacing: 8) {
                Image(systemName: paused ? "pause.circle" : "minus.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: PopupInset.icon)
                Text(paused ? "일시정지" : "쉬는 규칙").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, PopupInset.text).frame(minHeight: 30)
            ForEach(rules) { r in
                RuleLine(rule: r, detail: restDetail(r, paused: paused), dimmed: true, onOpen: { openWindow(select: "rule:" + r.id) })
            }
        }
    }

    private func restDetail(_ r: RuleStatus, paused: Bool) -> String {
        if !r.enabled { return "꺼짐" }
        if paused { return targetsText(r) }
        switch r.decision {
        case "skip": return r.when.flatMap { try? Condition.parse($0) }.map(\.short) ?? "조건 안 맞음"
        case "next": return "다음 규칙으로"
        case "system": return "평소 경로로"
        default: return r.nowText
        }
    }

    // MARK: 대상 추가

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: PopupInset.icon, height: PopupInset.icon)
            TextField("", text: $newTarget, prompt: Text("IP·도메인 추가"))
                .textFieldStyle(.plain).font(.system(size: 13)).onSubmit(add)
                .disabled(!m.engineReady || m.busy)
                .help("Wi-Fi로, 없으면 차단")
        }
        .padding(.horizontal, PopupInset.card + PopupInset.text).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: PopupCorner.card, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func add() {
        let t = newTarget
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        newTarget = ""
        Task { await m.add(t, note: "") }
    }

    // MARK: 아래 줄 — 판 이름과 창 단추 (Little Snitch 의 아래 줄처럼)

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Wi-Fi Exit \($0)" } ?? "Wi-Fi Exit"
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            if let s = m.status {
                Text(appliedText(s.lastApply)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    .help("\(version) · 기본 경로 \(s.defaultIfText)")
            } else {
                Text(version).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            BarButton(symbol: "list.bullet.rectangle", help: "규칙 편집 (⌘,)") { openWindow(select: nil) }
                .keyboardShortcut(",", modifiers: .command)
            BarButton(symbol: "point.3.connected.trianglepath.dotted", help: "라우팅 보기 (⌘R)") { AppWindows.open("routes") }
                .keyboardShortcut("r", modifiers: .command)
            Menu {
                Section {
                    Button("지금 다시 적용") { Task { await m.apply() } }
                    Button("도메인 다시 풀기") { Task { await m.resolve() } }
                    Button("로그 보기") { m.openLog() }
                }
                Section {
                    Toggle("로그인 시 실행", isOn: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) }))
                    Button(m.engineOutdated ? "엔진 갱신" : "엔진 다시 설치") { Task { await m.installEngine() } }
                }
                Section {
                    Button("설정 모두 지우기…", role: .destructive) { Task { await m.uninstall() } }
                }
                Section {
                    Button("Wi-Fi Exit 종료") { NSApp.terminate(nil) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(BarButtonStyle())
            .help("더 보기").disabled(m.busy)
            // ⌘Q 는 메뉴 안의 항목이라 메뉴가 닫혀 있으면 받지 않는다. 보이지 않는 단추로 받는다.
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.leading, PopupInset.card + PopupInset.text).padding(.trailing, 2)
    }

    /// "13:05 적용" (오늘), "11/17 적용"
    private func appliedText(_ epoch: Int) -> String {
        guard epoch > 0 else { return "적용 전" }
        let d = Date(timeIntervalSince1970: TimeInterval(epoch))
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d"
        return f.string(from: d) + " 적용"
    }

    private func openWindow(select: String?) {
        if let select { m.windowSelection = select }
        else { m.windowSelection = m.windowSelection ?? m.config?.rules.first.map { "rule:" + $0.id } }
        AppWindows.open("rules")
    }
}

/// 아래 줄의 기호 단추
private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
        }
        .buttonStyle(BarButtonStyle()).help(help).accessibilityLabel(help)
    }
}

private struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(hover ? .primary : .secondary)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.08 : 0)))
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

/// 카드 안의 규칙 한 줄: 출구 이름과 같은 선에서 시작하는 제목 + 대상.
/// Little Snitch 의 Control Center 처럼 줄에는 스위치를 두지 않고, 누르면 그 규칙의 메뉴(편집·끄기/켜기·복사)를 연다.
struct RuleLine: View {
    @EnvironmentObject var m: AppModel
    let rule: RuleStatus
    let detail: String
    var detailColor: Color = .secondary
    var dimmed = false
    let onOpen: () -> Void

    var body: some View {
        Menu {
            Button("편집…", action: onOpen)
            Button(rule.enabled ? "이 규칙 끄기" : "이 규칙 켜기") { Task { await m.setEnabled(rule.id, !rule.enabled) } }
                .disabled(!m.engineReady || m.busy)
            Divider()
            Button(rule.targets.count > 1 ? "대상 \(rule.targets.count)개 복사" : "대상 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rule.targets.map(\.target).joined(separator: "\n"), forType: .string)
            }
            Button("라우팅 보기 열기") { AppWindows.open("routes") }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.title).font(.system(size: 13)).foregroundStyle(dimmed ? .secondary : .primary).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(detailColor).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, PopupInset.text + PopupInset.icon + 8).padding(.trailing, PopupInset.text)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(RuleRowStyle())
        .help(rule.reason)
        .accessibilityLabel("\(rule.title), \(detail)")
    }
}

/// 규칙 줄의 강조: 올리면 옅게, 누르면 조금 더. 모서리는 카드와 동심.
private struct RuleRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: PopupCorner.row, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0)))
                .onHover { hover = $0 }
        }
    }
}
