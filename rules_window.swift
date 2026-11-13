// 규칙 편집 창: 왼쪽 규칙 목록(끌어서 순서), 오른쪽 규칙 폼(대상·출구 순위·없을 때·조건 빌더·미리보기), 네트워크 프로필.
// 저장하면 CLI 와 같은 엔진 명령(set/add/move/profile)을 부르므로 설정 파일은 CLI 로 만든 것과 같다.

import AppKit
import SwiftUI

// MARK: - 창

struct RulesWindow: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow

    private var rules: [Rule] { m.config?.rules ?? [] }
    private var profiles: [(String, NetProfile)] { (m.config?.profiles ?? [:]).sorted { $0.key < $1.key } }

    private var detailTitle: String {
        guard let sel = m.windowSelection else { return "규칙" }
        if sel == "new" { return "새 규칙" }
        if sel.hasPrefix("rule:"), let r = rules.first(where: { "rule:" + $0.id == sel }) { return r.title }
        if sel.hasPrefix("profile:") { return String(sel.dropFirst(8)) }
        return "규칙"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $m.windowSelection) {
                Section("규칙 · 위에서부터") {
                    ForEach(rules, id: \.id) { r in
                        RuleListItem(rule: r, status: m.status?.rules.first { $0.id == r.id },
                                     shadowedBy: m.shadowedBy(r), dirty: m.drafts["rule:" + r.id]?.isDirty == true)
                            .tag("rule:" + r.id)
                            .contextMenu {
                                Button(r.enabled ? "끄기" : "켜기") { Task { await m.setEnabled(r.id, !r.enabled) } }
                                Divider()
                                Button("삭제", role: .destructive) { Task { await m.remove(r.id) } }
                            }
                    }
                    .onMove { from, to in
                        guard let i = from.first else { return }
                        let id = rules[i].id
                        let dest = to > i ? to - 1 : to
                        Task { await m.move(id, String(dest + 1)) }
                    }
                }
                Section("네트워크 프로필") {
                    ForEach(profiles, id: \.0) { name, p in
                        HStack(spacing: 8) {
                            ZStack {
                                Circle().fill(m.profileHere(name) ? Color.green : Color.secondary.opacity(0.45))
                                Image(systemName: "location.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            }.frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name)
                                Text(Exits.label(p.link) + " 게이트웨이" + (m.profileHere(name) ? " · 지금 여기" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag("profile:" + name)
                    }
                    if profiles.isEmpty { Text("없음 — + 메뉴로 지금 망 저장").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if let sel = m.windowSelection, sel.hasPrefix("rule:"), let i = rules.firstIndex(where: { "rule:" + $0.id == sel }) {
                    RuleForm(key: sel, original: rules[i], index: i).id(sel)
                } else if m.windowSelection == "new" {
                    RuleForm(key: "new", original: nil, index: rules.count).id("new")
                } else if let sel = m.windowSelection, sel.hasPrefix("profile:"), let p = m.config?.profiles[String(sel.dropFirst(8))] {
                    ProfileDetail(name: String(sel.dropFirst(8)), profile: p)
                } else {
                    ContentUnavailableView("규칙을 고르세요", systemImage: "list.bullet.rectangle",
                                           description: Text("왼쪽에서 규칙을 고르거나 + 로 새 규칙을 만드세요"))
                }
            }
            .navigationTitle(detailTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "app-rules") } label: {
                        Label("앱별 스플리팅", systemImage: "app.connected.to.app.below.fill")
                    }.help("앱별 스플리팅")
                    Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "routes") } label: {
                        Label("라우팅 보기", systemImage: "point.3.connected.trianglepath.dotted")
                    }.help("라우팅 보기")
                    Menu {
                        Button("새 규칙") { m.windowSelection = "new" }
                        Button("지금 망을 프로필로 저장…") { Task { await m.saveProfile() } }
                    } label: { Label("추가", systemImage: "plus") }
                    .help("새 규칙 · 프로필")
                }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .task { await m.refresh() }
    }
}

struct RuleListItem: View {
    let rule: Rule
    let status: RuleStatus?
    var shadowedBy: String? = nil
    var dirty = false

    var body: some View {
        HStack(spacing: 9) {
            ExitBadge(name: status?.nowExit ?? rule.exits.first ?? "block",
                      off: !rule.enabled || status?.nowExit == nil, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rule.title).lineLimit(1).foregroundStyle(rule.enabled ? .primary : .secondary)
                    if dirty { Circle().fill(Color.orange).frame(width: 6, height: 6).help("저장하지 않은 편집이 있어요") }
                }
                if let by = shadowedBy {
                    Text("⚠︎ \"\(by)\"에 가려짐").font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(rule.enabled ? rule.settingsText : "꺼짐").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 규칙 폼

/// 조건을 고치는 방식
enum CondMode: String { case always, builder, text }

/// 저장하지 않은 편집. 화면이 다시 만들어져도, 다른 규칙을 보다 와도 남는다 (AppModel.drafts).
struct RuleDraft: Equatable {
    var base: Rule?                 // 편집을 시작할 때의 원본 (다른 곳에서 바뀌었는지 볼 때 쓴다)
    var name = ""
    var enabled = true
    var targets: [String] = []
    var newTarget = ""
    var exits: [String] = ["wifi"]
    var elseAction = "block"
    var check = ""                  // 상태 점검 대상 host:port (빈 값 = 출구 점검만)
    var mode: CondMode = .always
    var group = CondGroup()
    var text = ""

    init(_ r: Rule?) {
        base = r
        guard let r else { return }
        name = r.name; enabled = r.enabled; targets = r.targets; exits = r.exits; elseAction = r.elseAction
        check = r.check ?? ""
        text = r.when.isAlways ? "" : r.when.text
        if r.when.isAlways { mode = .always }
        else if let b = r.when.builder { group = b; mode = .builder }
        else { mode = .text }
    }

    var condition: Result<Condition, ConditionError> {
        switch mode {
        case .always: return .success(.always)
        case .builder: return .success(group.condition)
        case .text:
            do { return .success(try Condition.parse(text)) } catch let e as ConditionError { return .failure(e) }
            catch { return .failure(ConditionError(description: "\(error)")) }
        }
    }

    func rule(id: String) -> Rule? {
        guard case .success(let c) = condition else { return nil }
        let ck = check.trimmingCharacters(in: .whitespaces)
        let norm = CheckTarget.parse(ck).map { "\($0.host):\($0.port)" }
        return Rule(id: id, name: cleanNote(name), enabled: enabled, targets: targets, when: c, exits: exits, elseAction: elseAction,
                    check: ck.isEmpty ? nil : (norm ?? ck))
    }

    /// 저장할 만한 차이가 있는지 (조건 방식만 바꾼 것도 편집으로 본다)
    var isDirty: Bool {
        guard let b = base else { return !targets.isEmpty || !name.isEmpty }
        return rule(id: b.id) != b || mode != RuleDraft(b).mode || !newTarget.isEmpty
    }
}

struct RuleForm: View {
    @EnvironmentObject var m: AppModel
    let key: String                 // "rule:<id>" | "new"
    let original: Rule?
    let index: Int

    // 편집 상태는 모델의 초안에 둔다
    private var d: RuleDraft { m.drafts[key] ?? RuleDraft(original) }
    private func edit(_ f: (inout RuleDraft) -> Void) { var x = d; f(&x); m.drafts[key] = x }
    private func bind<T>(_ kp: WritableKeyPath<RuleDraft, T>) -> Binding<T> {
        Binding(get: { d[keyPath: kp] }, set: { v in edit { $0[keyPath: kp] = v } })
    }

    private var name: String { d.name }
    private var enabled: Bool { d.enabled }
    private var targets: [String] { get { d.targets } nonmutating set { edit { $0.targets = newValue } } }
    private var newTarget: String { get { d.newTarget } nonmutating set { edit { $0.newTarget = newValue } } }
    private var exits: [String] { get { d.exits } nonmutating set { edit { $0.exits = newValue } } }
    private var elseAction: String { d.elseAction }
    private var mode: CondMode { get { d.mode } nonmutating set { edit { $0.mode = newValue } } }
    private var group: CondGroup { get { d.group } nonmutating set { edit { $0.group = newValue } } }
    private var text: String { get { d.text } nonmutating set { edit { $0.text = newValue } } }

    /// 다른 곳(CLI 등)에서 이 규칙이 바뀌었는데 내 편집이 남아 있는지
    private var staleBase: Bool { original != nil && m.drafts[key]?.base != original && m.drafts[key]?.isDirty == true }

    // MARK: 지금 고친 규칙

    private var condition: Result<Condition, ConditionError> { d.condition }

    private var draft: Rule? { d.rule(id: original?.id ?? "new") }

    private var problems: [String] {
        var out: [String] = []
        if targets.isEmpty { out.append("대상을 하나 이상 넣어 주세요") }
        let ck = d.check.trimmingCharacters(in: .whitespaces)
        if !ck.isEmpty && CheckTarget.parse(ck) == nil { out.append("점검 대상은 host:port (예: git.example.corp:443)") }
        if let h = CheckTarget.parse(ck)?.host, d.targets.contains(h) { out.append("점검 대상은 이 규칙의 대상과 다른 곳이어야 해요") }
        switch condition {
        case .failure(let e): out.append("조건: \(e.description)")
        case .success(let c): if let why = c.validate(profiles: Set(m.config?.profiles.keys ?? [:].keys)) { out.append("조건: \(why)") }
        }
        return out
    }

    private var changed: Bool {
        guard let o = original, let r = draft else { return true }
        return o != r
    }

    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if staleBase {
                    Section {
                        HStack {
                            Label("이 규칙이 다른 곳(팝업·CLI)에서 바뀌었어요. 지금 보이는 건 고치던 내용이에요.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("다시 불러오기") { m.drafts[key] = RuleDraft(original) }
                        }
                    }
                }
                Section { header }
                if !notices.isEmpty {
                    Section {
                        ForEach(notices, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    TextField("이름(메모)", text: bind(\.name), prompt: Text("예: 개인 서버"))
                }
                Section("대상") { targetsEditor }
                Section {
                    exitsEditor
                } header: { Text("출구 순위") } footer: {
                    Text("쓸 수 있는 첫 출구로 보내고, 그 출구가 아닌 곳으로는 막아요.").font(.caption).foregroundStyle(.secondary)
                }
                Section("동작") { behaviorEditor }
            }
            .formStyle(.grouped)
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .onAppear(perform: syncDraft)
        .onChange(of: original) { syncDraft() }
        .confirmationDialog("이 규칙을 지울까요?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) { if let o = original { Task { await m.remove(o.id); m.windowSelection = nil } } }
        } message: { Text(original?.title ?? "") }
    }

    // MARK: 머리: 지금이라면 어디로

    private var outcome: (Outcome, Facts, EngineConfig)? {
        guard let d = draft, let s = m.status, let c = m.config else { return nil }
        let f = CLI.facts(s, c)
        return (c.paused ? .off : decide(d, facts: f), f, c)
    }

    private func headline(_ o: Outcome) -> String {
        switch o {
        case .route(let n, let e): return "\(Exits.label(n))(\(e.iface))로 보내는 중"
        case .block: return "막는 중"
        case .system: return "평소 경로로 둠"
        case .next: return "다음 규칙으로 넘김"
        case .skip: return "조건이 안 맞아 건너뜀"
        case .off: return d.enabled ? "일시정지 중" : "꺼짐"
        }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            if let (o, f, c) = outcome, let dr = draft {
                switch o {
                case .route(let n, _): ExitBadge(name: n, size: 38)
                case .block: ExitBadge(name: "block", size: 38)
                default: ExitBadge(name: dr.exits.first ?? "wifi", off: true, size: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(o)).font(.title3.bold())
                    Text(reasonText(dr, o, facts: f, paused: c.paused)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ExitBadge(name: d.exits.first ?? "wifi", off: true, size: 38)
                Text(original == nil ? "새 규칙" : "상태를 읽는 중").font(.title3.bold())
            }
            Spacer()
            Toggle("켜기", isOn: bind(\.enabled)).toggleStyle(.switch).labelsHidden().help("이 규칙 켜기")
        }
        .padding(.vertical, 4)
    }

    /// 가려짐·터널 보호 같은 알림 (지금 자리에 둔 목록으로 따진다)
    private var notices: [String] {
        guard let dr = draft, let c = m.config else { return [] }
        var rs = c.rules
        if let i = rs.firstIndex(where: { $0.id == dr.id }) { rs[i] = dr } else { rs.append(dr) }
        let idx = rs.firstIndex { $0.id == dr.id } ?? rs.count - 1
        var out = shadowWarnings(rs, index: idx, addresses: m.resolvedIPs)
        if let st = m.status?.rules.first(where: { $0.id == dr.id }) { out += st.addresses.compactMap(\.note) }
        return out
    }

    /// 초안을 준비한다. 고친 게 없는데 원본이 바뀌었으면 새 원본으로 다시 시작한다.
    private func syncDraft() {
        if let cur = m.drafts[key], cur.isDirty { return }
        m.drafts[key] = RuleDraft(original)
    }

    // MARK: 대상

    private var targetError: String? {
        let t = newTarget.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        return Target.parse(t) == nil ? "IPv4, IPv4/프리픽스(8–32), 도메인만 넣을 수 있어요" : nil
    }

    @ViewBuilder private var targetsEditor: some View {
        ForEach(targets, id: \.self) { t in
            let ips = m.resolvedIPs[t] ?? []
            HStack {
                Text(t).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                if !ips.isEmpty {
                    Text("IP \(ips.count)개").foregroundStyle(.secondary)
                        .help(ips.joined(separator: "\n"))
                }
                Button { targets.removeAll { $0 == t } } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("대상에서 빼기")
            }
        }
        HStack {
            Image(systemName: "plus").foregroundStyle(Color.accentColor)
            TextField("", text: bind(\.newTarget), prompt: Text("IP, 대역, 도메인 추가 — Return"))
                .labelsHidden().textFieldStyle(.plain).onSubmit(addTarget)
            if let e = targetError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func addTarget() {
        guard let (t, _) = Target.parse(newTarget) else { return }
        if !targets.contains(t) { targets.append(t) }
        newTarget = ""
    }

    // MARK: 출구

    private func exitDetail(_ e: String) -> (String, Color) {
        let ms = matchingExits(e, in: m.status?.exits ?? [])
        if let x = ms.first(where: { $0.healthy != false }) { return ("\(x.iface) · 연결됨", .secondary) }
        if let x = ms.first { return ("\(x.iface) · 응답 없음", .orange) }
        return (m.exitAbsentReason(e) ?? "지금 없음", .secondary)
    }

    @ViewBuilder private var exitsEditor: some View {
        if exits.isEmpty {
            Text("출구 없음 — 이 대상은 늘 막아요").foregroundStyle(.secondary)
        }
        ForEach(Array(exits.enumerated()), id: \.element) { i, e in
            let (detail, dc) = exitDetail(e)
            HStack(spacing: 10) {
                Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 12)
                ExitBadge(name: e, off: !m.exitUp(e), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Exits.label(e))
                    Text(detail).font(.caption).foregroundStyle(dc).lineLimit(1)
                }
                Spacer()
                if exits.count > 1 {
                    Button { exits.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0).help("위로")
                    Button { exits.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == exits.count - 1).help("아래로")
                }
                Button { exits.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("출구 빼기")
            }
        }
        Menu {
            ForEach(exitCandidates().filter { !exits.contains($0) }, id: \.self) { e in
                Button(Exits.label(e) + (m.exitUp(e) ? "" : " (\(m.exitAbsentReason(e) ?? "지금 없음"))")) { exits.append(e) }
            }
        } label: { Label("출구 추가", systemImage: "plus") }
        .menuStyle(.borderlessButton).fixedSize().disabled(exits.count >= 6)
    }

    // MARK: 조건

    @ViewBuilder private var behaviorEditor: some View {
        Picker("쓸 수 있는 출구가 없을 때", selection: bind(\.elseAction)) {
            Text("차단 (다른 길로 새지 않음)").tag("block")
            Text("평소 경로").tag("system")
            Text("다음 규칙에 넘김").tag("next")
        }
        Picker(selection: Binding(get: { mode }, set: switchMode)) {
            Text("항상").tag(CondMode.always)
            Text("조건 빌더").tag(CondMode.builder)
            Text("글로 쓰기").tag(CondMode.text)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("조건")
                Text("맞을 때만 적용, 안 맞으면 다음 규칙").font(.caption).foregroundStyle(.secondary)
            }
        }
        switch mode {
        case .always:
            EmptyView()
        case .builder:
            GroupEditor(group: bind(\.group), nested: false)
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: bind(\.text), prompt: Text("예: vpn=pass and (link=wired or profile=사무실)"), axis: .vertical)
                    .labelsHidden().textFieldStyle(.roundedBorder).font(.callout.monospaced()).lineLimit(1...4)
                Text("키: vpn= link= profile= default= vpnover= time=09:00-18:00 day=mon-fri · 연산: = != and or not ( )")
                    .font(.caption).foregroundStyle(.secondary)
                if case .success(let c) = condition, c.builder == nil, !c.isAlways {
                    Text("이 조건은 빌더로 나타낼 수 없어 글로만 고칠 수 있어요.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        if case .failure(let e) = condition { Text(e.description).font(.caption).foregroundStyle(.red) }
        if mode != .always, let (_, f, _) = outcome, let dr = draft {
            Text(f.explain(dr.when)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        TextField(text: bind(\.check), prompt: Text("비우면 출구 자체만 점검")) {
            VStack(alignment: .leading, spacing: 1) {
                Text("상태 점검 대상")
                Text("host:port 에 닿을 때만 그 출구를 써요").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 모드를 바꿀 때 지금 조건을 그대로 옮긴다. 빌더로 못 옮기면 글 모드에 머문다.
    private func switchMode(_ new: CondMode) {
        let current: Condition? = { if case .success(let c) = condition { return c }; return nil }()
        switch new {
        case .always: mode = .always
        case .builder:
            if let c = current, let b = c.builder { group = b; mode = .builder }
            else if current == nil { NSSound.beep() }
            else { NSSound.beep() }
        case .text:
            if let c = current { text = c.isAlways ? "" : c.text }
            mode = .text
        }
    }

    // MARK: 저장

    private var footer: some View {
        HStack {
            if original != nil {
                Button("규칙 삭제…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
            if !problems.isEmpty {
                Text(problems.joined(separator: " · ")).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if m.busy { ProgressView().controlSize(.small) }
            if original != nil {
                Button("되돌리기") { m.drafts[key] = RuleDraft(original) }.disabled(!(m.drafts[key]?.isDirty ?? false))
            }
            Button(original == nil ? "추가" : "저장") {
                guard let d = draft else { return }
                Task { await m.saveRule(d, isNew: original == nil, draftKey: key) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!problems.isEmpty || !changed || m.busy)
        }
    }
}

// MARK: - 조건 빌더

struct GroupEditor: View {
    @EnvironmentObject var m: AppModel
    @Binding var group: CondGroup
    let nested: Bool
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(nested ? "묶음:" : "다음 중")
                Picker("", selection: $group.any) {
                    Text("모두").tag(false)
                    Text("하나라도").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("맞을 때")
                Spacer()
                if let onDelete { Button { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
            }
            ForEach($group.rows) { $row in
                RowEditor(row: $row) { group.rows.removeAll { $0.id == row.id } }
            }
            if !nested {
                ForEach($group.groups) { $g in
                    GroupEditor(group: $g, nested: true) { group.groups.removeAll { $0.id == g.id } }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.35)))
                }
            }
            HStack {
                Button { group.rows.append(CondRow(key: "vpn", value: "none")) } label: { Label("조건", systemImage: "plus") }
                if !nested {
                    Button { group.groups.append(CondGroup(any: !group.any, rows: [CondRow(key: "link", value: "wired")])) } label: {
                        Label("묶음", systemImage: "plus.square.on.square")
                    }
                }
            }
            .controlSize(.small)
            if !nested && group.isEmpty { Text("조건이 없으면 언제나 적용해요.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct RowEditor: View {
    @EnvironmentObject var m: AppModel
    @Binding var row: CondRow
    let onDelete: () -> Void

    static let keyLabels: [(String, String)] = [
        ("vpn", "VPN"), ("link", "연결된 링크"), ("profile", "네트워크 프로필"), ("default", "기본 경로"),
        ("vpnover", "VPN 하부 링크"), ("time", "시간대"), ("day", "요일"),
    ]

    private var choices: [(String, String)]? {
        switch row.key {
        case "vpn":
            let aliases = exitCandidates().filter { $0.hasPrefix("vpn:") && $0 != "vpn:any" }.map { String($0.dropFirst(4)) }
            return [("none", "없음"), ("any", "아무거나")] + aliases.map { ($0, $0) }
        case "link", "vpnover": return [("wifi", "Wi-Fi"), ("wired", "유선"), ("tether", "테더링")]
        case "default": return [("wifi", "Wi-Fi"), ("wired", "유선"), ("tether", "테더링"), ("vpn", "VPN")]
        case "profile": return m.profileNames.map { ($0, $0) }
        case "day": return [("mon-fri", "평일"), ("sat,sun", "주말"), ("mon", "월"), ("tue", "화"), ("wed", "수"), ("thu", "목"), ("fri", "금"), ("sat", "토"), ("sun", "일")]
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { row.key }, set: { k in row.key = k; row.value = defaultValue(k) })) {
                ForEach(Self.keyLabels, id: \.0) { k, l in Text(l).tag(k) }
            }.labelsHidden().frame(width: 140)
            Picker("", selection: $row.negate) {
                Text("=").tag(false)
                Text("≠").tag(true)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if let cs = choices {
                Picker("", selection: $row.value) {
                    if !cs.contains(where: { $0.0 == row.value }) { Text(row.value.isEmpty ? "고르세요" : row.value).tag(row.value) }
                    ForEach(cs, id: \.0) { v, l in Text(l).tag(v) }
                }.labelsHidden().frame(width: 150)
                if row.key == "profile" && cs.isEmpty { Text("저장한 프로필이 없어요").font(.caption).foregroundStyle(.orange) }
            } else {
                TextField(row.key == "time" ? "09:00-18:00" : "값", text: $row.value).textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced()).frame(width: 150)
            }
            Button(action: onDelete) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }

    private func defaultValue(_ k: String) -> String {
        switch k {
        case "vpn": return "none"
        case "link", "vpnover", "default": return "wired"
        case "profile": return m.profileNames.first ?? ""
        case "time": return "09:00-18:00"
        case "day": return "mon-fri"
        default: return ""
        }
    }
}

// MARK: - 프로필

struct ProfileDetail: View {
    @EnvironmentObject var m: AppModel
    let name: String
    let profile: NetProfile

    private var users: [Rule] {
        (m.config?.rules ?? []).filter { $0.when.text.range(of: "profile!?=\(NSRegularExpression.escapedPattern(for: name))(\\b|$|\\))", options: .regularExpression) != nil }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(m.profileHere(name) ? Color.green : Color.secondary.opacity(0.45))
                        Image(systemName: "location.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }.frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.title3.bold())
                        Text(m.profileHere(name) ? "지금 이 망에 있어요" : "지금 이 망이 아니에요").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            Section {
                LabeledContent("링크", value: Exits.label(profile.link))
                LabeledContent("게이트웨이") { Text(profile.gateway).monospaced() }
                LabeledContent("게이트웨이 MAC") { Text(profile.gatewayMac.isEmpty ? "(없음)" : profile.gatewayMac).monospaced() }
            } footer: {
                Text("조건에 profile=\(name) 으로 쓰면, 이 링크가 이 게이트웨이(그리고 MAC)에 붙어 있을 때 참이 돼요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if users.isEmpty {
                    Button("프로필 삭제", role: .destructive) { Task { await m.removeProfile(name) } }
                } else {
                    LabeledContent("쓰는 규칙", value: users.map(\.title).joined(separator: ", "))
                    Text("이 규칙들의 조건에서 빼야 지울 수 있어요.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 줄바꿈되는 가로 배치

struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += z.width + spacing; rowH = max(rowH, z.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + z.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; rowH = max(rowH, z.height)
        }
    }
}
