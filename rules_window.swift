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

    var body: some View {
        NavigationSplitView {
            List(selection: $m.windowSelection) {
                Section("규칙 · 위에서부터 적용") {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
                        RuleListItem(rule: r, index: i, status: m.status?.rules.first { $0.id == r.id }, statusAll: m.status,
                                     dirty: m.drafts["rule:" + r.id]?.isDirty == true)
                            .tag("rule:" + r.id)
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
                        HStack(spacing: 6) {
                            Image(systemName: m.profileHere(name) ? "location.fill" : "location").foregroundStyle(m.profileHere(name) ? .green : .secondary)
                            Text(name)
                            Spacer()
                            Text(Exits.label(p.link)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag("profile:" + name)
                    }
                    if profiles.isEmpty { Text("없음 — 위 + 메뉴로 지금 망 저장").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .toolbar {
                ToolbarItem {
                    Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "routes") } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }.help("라우팅 보기")
                }
                ToolbarItem {
                    Menu {
                        Button("새 규칙") { m.windowSelection = "new" }
                        Button("지금 망을 프로필로 저장…") { Task { await m.saveProfile() } }
                    } label: { Image(systemName: "plus") }
                }
            }
        } detail: {
            Group {
                if let sel = m.windowSelection, sel.hasPrefix("rule:"), let i = rules.firstIndex(where: { "rule:" + $0.id == sel }) {
                    RuleForm(key: sel, original: rules[i], index: i).id(sel)
                } else if m.windowSelection == "new" {
                    RuleForm(key: "new", original: nil, index: rules.count).id("new")
                } else if let sel = m.windowSelection, sel.hasPrefix("profile:"), let p = m.config?.profiles[String(sel.dropFirst(8))] {
                    ProfileDetail(name: String(sel.dropFirst(8)), profile: p)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("왼쪽에서 규칙을 고르거나 + 로 새 규칙을 만드세요").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Wi-Fi Exit 규칙")
        }
        .frame(minWidth: 780, minHeight: 540)
        .task { await m.refresh() }
    }
}

struct RuleListItem: View {
    let rule: Rule
    let index: Int
    let status: RuleStatus?
    let statusAll: EngineStatus?
    var dirty = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
            if let s = status, let all = statusAll {
                Image(systemName: all.state(of: s).symbol).foregroundStyle(all.state(of: s).color).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(rule.name.isEmpty ? rule.targets.joined(separator: ", ") : rule.name).lineLimit(1)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    if dirty { Circle().fill(Color.orange).frame(width: 6, height: 6).help("저장하지 않은 편집이 있어요") }
                }
                Text((rule.name.isEmpty ? "" : rule.targets.joined(separator: ", ") + " · ") + rule.exitsText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !rule.when.isAlways {
                    Text("조건 " + rule.when.text).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if staleBase {
                        HStack {
                            Label("이 규칙이 다른 곳(CLI 등)에서 바뀌었어요. 지금 보이는 건 내가 고치던 내용이에요.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("새 내용 불러오기") { m.drafts[key] = RuleDraft(original) }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    }
                    header
                    section("대상", "IP, IP/프리픽스, 도메인. 도메인은 고른 출구의 DNS로 5분마다 다시 풀어요.") { targetsEditor }
                    section("출구 순위", "쓸 수 있는 첫 출구로 보내고, 다른 출구로는 막아요. 끌어서 순서를 바꿔요.") { exitsEditor }
                    section("상태 점검 대상 (선택)", "비워 두면 출구 자체가 응답하는지만 봐요. host:port 를 넣으면 그 출구로 여기에 닿을 때만 그 출구를 써요.") {
                        TextField("예: git.example.corp:443", text: bind(\.check))
                            .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(maxWidth: 320)
                    }
                    section("쓸 수 있는 출구가 없을 때", nil) {
                        Picker("", selection: bind(\.elseAction)) {
                            Text("차단 (다른 길로 새지 않음)").tag("block")
                            Text("평소 경로").tag("system")
                            Text("다음 규칙에 넘김").tag("next")
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    section("조건", "맞을 때만 이 규칙을 적용해요. 안 맞으면 건너뛰고 다음 규칙이 맡아요.") { conditionEditor }
                    preview
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .onAppear(perform: syncDraft)
        .onChange(of: original) { syncDraft() }
    }

    /// 초안을 준비한다. 고친 게 없는데 원본이 바뀌었으면 새 원본으로 다시 시작한다.
    private func syncDraft() {
        if let cur = m.drafts[key], cur.isDirty { return }
        m.drafts[key] = RuleDraft(original)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if original != nil { Text("#\(index + 1)").font(.title3.monospaced()).foregroundStyle(.tertiary) } else { Text("새 규칙").font(.title3.bold()) }
            TextField("메모 (예: 개인 서버)", text: bind(\.name)).textFieldStyle(.roundedBorder).font(.title3)
            Toggle("켜기", isOn: bind(\.enabled)).toggleStyle(.switch)
        }
    }

    private func section<C: View>(_ title: String, _ hint: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            content()
        }
    }

    // MARK: 대상

    private var targetError: String? {
        let t = newTarget.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        return Target.parse(t) == nil ? "IPv4, IPv4/프리픽스(8–32), 도메인만 넣을 수 있어요" : nil
    }

    private var targetsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(items: targets) { t in
                HStack(spacing: 4) {
                    Text(t).font(.callout.monospaced())
                    if let ips = m.resolvedIPs[t], !ips.isEmpty {
                        Text(ips.prefix(3).joined(separator: ", ") + (ips.count > 3 ? " …" : "")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Button { targets.removeAll { $0 == t } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            HStack {
                TextField("추가할 대상", text: bind(\.newTarget)).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .frame(maxWidth: 280).onSubmit(addTarget)
                Button("추가", action: addTarget).disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty || targetError != nil)
                if let e = targetError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private func addTarget() {
        guard let (t, _) = Target.parse(newTarget) else { return }
        if !targets.contains(t) { targets.append(t) }
        newTarget = ""
    }

    // MARK: 출구

    private var exitsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if exits.isEmpty {
                Text("출구 없음 — 이 대상은 늘 막아요 (없을 때 설정에 따라)").font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(exits.enumerated()), id: \.element) { i, e in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            ExitChip(name: e, label: Exits.label(e), active: m.exitUp(e), rank: i + 1)
                            let st = m.exitStateText(e)
                            Text(st).font(.caption).foregroundStyle(st == "지금 있음" ? .green : st == "응답 없음" ? .orange : .secondary)
                                .lineLimit(1).truncationMode(.tail).help(st)
                            Spacer()
                            Button { exits.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    .onMove { exits.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .scrollDisabled(true)
                .frame(maxWidth: 460, minHeight: CGFloat(exits.count) * 30 + 8, maxHeight: CGFloat(exits.count) * 30 + 8)
            }
            Menu("출구 추가") {
                ForEach(exitCandidates().filter { !exits.contains($0) }, id: \.self) { e in
                    Button(Exits.label(e) + (m.exitUp(e) ? "" : " (\(m.exitAbsentReason(e) ?? "지금 없음"))")) { exits.append(e) }
                }
            }
            .fixedSize().disabled(exits.count >= 6)
        }
    }

    // MARK: 조건

    private var conditionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { mode }, set: switchMode)) {
                Text("항상").tag(CondMode.always)
                Text("조건 빌더").tag(CondMode.builder)
                Text("글로 쓰기").tag(CondMode.text)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()

            switch mode {
            case .always:
                Text("언제나 적용해요.").font(.callout).foregroundStyle(.secondary)
            case .builder:
                GroupEditor(group: bind(\.group), nested: false)
            case .text:
                TextField("예: vpn=pass and (link=wired or profile=사무실)", text: bind(\.text), axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced()).lineLimit(1...4).frame(maxWidth: 560)
                Text("키: vpn= link= profile= default= vpnover= time=09:00-18:00 day=mon-fri · 연산: = != and or not ( )")
                    .font(.caption).foregroundStyle(.secondary)
                if case .success(let c) = condition, c.builder == nil, !c.isAlways {
                    Text("이 조건은 빌더로 나타낼 수 없어 글로만 고칠 수 있어요.").font(.caption).foregroundStyle(.orange)
                }
            }
            if case .failure(let e) = condition { Text(e.description).font(.caption).foregroundStyle(.red) }
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

    // MARK: 미리보기

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("지금이라면").font(.headline)
            if let d = draft, let s = m.status, let c = m.config {
                let f = CLI.facts(s, c)
                let o = c.paused ? Outcome.off : decide(d, facts: f)
                Label(reasonText(d, o, facts: f, paused: c.paused), systemImage: icon(o))
                    .foregroundStyle(color(o))
                if !d.when.isAlways { Text(f.explain(d.when)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                // 가려짐: 이 규칙을 지금 자리에 둔 목록으로 따진다
                let list: [Rule] = {
                    var rs = c.rules
                    if let i = rs.firstIndex(where: { $0.id == d.id }) { rs[i] = d } else { rs.append(d) }
                    return rs
                }()
                let idx = list.firstIndex { $0.id == d.id } ?? list.count - 1
                ForEach(shadowWarnings(list, index: idx, addresses: m.resolvedIPs), id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if let rs = s.rules.first(where: { $0.id == d.id }) {
                    ForEach(rs.addresses.compactMap(\.note), id: \.self) { n in
                        Label(n, systemImage: "shield.lefthalf.filled").font(.callout).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("조건을 고치면 결과를 보여 드려요.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func icon(_ o: Outcome) -> String {
        switch o {
        case .route: return "arrow.right.circle.fill"
        case .block: return "nosign"
        case .system: return "arrow.uturn.right.circle"
        case .next, .skip: return "arrow.down.circle"
        case .off: return "circle"
        }
    }
    private func color(_ o: Outcome) -> Color {
        switch o {
        case .route(let n, _): return Color.exit(n.hasPrefix("vpn") ? "vpn" : n)
        case .block: return .red
        default: return .secondary
        }
    }

    // MARK: 저장

    private var footer: some View {
        HStack {
            if let o = original {
                Button("규칙 지우기", role: .destructive) {
                    Task { await m.remove(o.id); m.windowSelection = nil }
                }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: m.profileHere(name) ? "location.fill" : "location").foregroundStyle(m.profileHere(name) ? .green : .secondary)
                Text(name).font(.title2.bold())
                if m.profileHere(name) { Text("지금 여기").font(.caption.bold()).foregroundStyle(.green) }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("링크").foregroundStyle(.secondary); Text(Exits.label(profile.link)) }
                GridRow { Text("게이트웨이").foregroundStyle(.secondary); Text(profile.gateway).monospaced() }
                GridRow { Text("게이트웨이 MAC").foregroundStyle(.secondary); Text(profile.gatewayMac.isEmpty ? "(없음)" : profile.gatewayMac).monospaced() }
            }
            Text("조건에 profile=\(name) 으로 쓰면, 이 링크가 이 게이트웨이(그리고 MAC)에 붙어 있을 때 참이 돼요.")
                .font(.callout).foregroundStyle(.secondary)
            if users.isEmpty {
                Button("프로필 지우기", role: .destructive) { Task { await m.removeProfile(name) } }
            } else {
                Text("쓰는 규칙: " + users.map(\.title).joined(separator: ", ")).font(.callout)
                Text("이 규칙들의 조건에서 빼야 지울 수 있어요.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
