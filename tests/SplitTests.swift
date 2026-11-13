import Foundation
import Network
import Darwin

final class MemoryTCP: TCPChannel {
    let payload: Data
    var offset = 0, opens = 0, received = Data(), errors = [String](), maxWrite = 0
    init(_ payload: Data) { self.payload = payload }
    func open(_ completion: @escaping (Error?) -> Void) { opens += 1; completion(nil) }
    func read(_ completion: @escaping (Data?, Error?) -> Void) {
        let end = min(offset + 32768, payload.count)
        let data = payload.subdata(in: offset..<end); offset = end; completion(data, nil)
    }
    func write(_ data: Data, completion: @escaping (Error?) -> Void) { maxWrite = max(maxWrite, data.count); received.append(data); completion(nil) }
    func closeRead(_ error: Error?) { if let error { errors.append(error.localizedDescription) } }
    func closeWrite(_ error: Error?) { if let error { errors.append(error.localizedDescription) } }
}
final class MemoryUDP: UDPChannel {
    var batch: [(Data, Network.NWEndpoint)]?
    var replies: [(Data, Network.NWEndpoint)] = []
    let expected: Int
    let received = DispatchSemaphore(value: 0)
    var errors: [String] = []
    init(_ datagrams: [(Data, Network.NWEndpoint)]) { batch = datagrams; expected = datagrams.count }
    func open(_ completion: @escaping (Error?) -> Void) { completion(nil) }
    func read(_ completion: @escaping ([(Data, Network.NWEndpoint)]?, Error?) -> Void) {
        if let value = batch { batch = nil; completion(value, nil) }
    }
    func write(_ datagrams: [(Data, Network.NWEndpoint)], completion: @escaping (Error?) -> Void) {
        replies += datagrams; completion(nil)
        if replies.count == expected { received.signal() }
    }
    func close(_ error: Error?) { if let error { errors.append(error.localizedDescription) } }
}

@main
struct SplitTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { fatalError(message) }
    }
    static func main() throws {
        var rule = SplitRule(name: "Browser", signingID: "org.example.browser", teamID: "ABCDEFGHIJ")
        let wifi = SplitExit(selector: "wifi", iface: "en1", ip: "192.168.1.2")
        let wired = SplitExit(selector: "wired", iface: "en0", ip: "10.0.0.2")
        var config = SplitConfig(rules: [rule])
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID, exits: [wifi]) == .route(rule: rule.id, iface: "en1"), "exact app")
        check(SplitPolicy.decide(config, signingID: rule.signingID + ".helper", teamID: rule.teamID, exits: [wifi]) == .route(rule: rule.id, iface: "en1"), "same-team helper")
        check(SplitPolicy.decide(config, signingID: rule.signingID + "evil", teamID: rule.teamID, exits: [wifi]) == .system, "helper boundary")
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: "XXXXXXXXXX", exits: [wifi]) == .system, "other publisher")
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: nil, exits: [wifi]) == .block(rule: rule.id), "unknown identity fails closed")
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID, exits: [wired]) == .block(rule: rule.id), "missing exit fails closed")
        rule.exits = ["wifi", "wired"]; config.rules = [rule]
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID, exits: [wired]) == .route(rule: rule.id, iface: "en0"), "secondary exit")
        rule.exits = ["vpn:pass"]; config.rules = [rule]
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID,
            exits: [SplitExit(selector: "vpn:cloud", iface: "utun2", ip: "10.1.1.1")]) == .block(rule: rule.id), "VPN alias isolation")
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID,
            exits: [SplitExit(selector: "vpn:passvpn.example.com", iface: "utun3", ip: "10.1.1.2")]) == .route(rule: rule.id, iface: "utun3"), "legacy VPN portal alias")
        rule.fallback = "system"; config.rules = [rule]
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID, exits: []) == .system, "explicit system fallback")
        rule.enabled = false; config.rules = [rule]
        check(SplitPolicy.decide(config, signingID: rule.signingID, teamID: rule.teamID, exits: []) == .system, "disabled rule")
        let roundtrip = try JSONDecoder().decode(SplitConfig.self, from: JSONEncoder().encode(config))
        check(roundtrip == config, "config roundtrip")
        var snapshot = config; snapshot.revision = 10
        var cached = snapshot; cached.revision = 11; cached.rules = []
        check(snapshot.restoring(cached) == cached, "restore newer live rules after provider restart")
        var other = cached; other.configurationID = UUID().uuidString; other.revision = 100
        check(snapshot.restoring(other) == snapshot, "never restore another configuration's rules")
        cached.revision = 9
        check(snapshot.restoring(cached) == snapshot, "ignore stale cached rules")
        cached.version = 2; cached.revision = 20
        check(snapshot.restoring(cached) == snapshot, "reject invalid cached rules")
        let old = #"{"version":2,"rules":[{"id":"rest","name":"","enabled":true,"targets":["remaining"],"when":"always","exits":["wifi"],"else":"block"}]}"#
        let migrated = try JSONDecoder().decode(EngineConfig.self, from: Data(old.utf8))
        check(migrated.rules.isEmpty, "remove remaining settings")
        check(SplitPolicy.requiresEngineMigration(config: Data(old.utf8), status: nil), "require migration for removed catch-all configuration")
        check(SplitPolicy.requiresEngineMigration(config: nil, status: Data(#"{"rules":[{"targets":[{"target":"remaining","kind":"remaining"}]}]}"#.utf8)), "require migration for leftover catch-all state")
        check(!SplitPolicy.requiresEngineMigration(config: Data(#"{"version":2,"rules":[]}"#.utf8), status: nil), "compatible older host engine must not block app routing")
        check(Target.parse("remaining") == nil, "remaining CLI target removed")
        let status = EngineStatus(generatedAt: 1, paused: false, wifi: LinkInfo(iface: "", ip: "", gateway: "", dns: [], signature: "", up: false), defaultIf: "en0", pfEnabled: true,
            lastResolve: 1, lastApply: 1, rules: [RuleStatus(id: "host", name: "", enabled: true, exits: ["wired"], elseAction: "block", chosenExit: "wired", chosenIface: "en0", decision: "route", reason: "", targets: [TargetStatus(target: "example.org", kind: .domain, addresses: [AddressStatus(ip: "8.8.8.8", interface: "en0", pinned: true, blocked: true)])])], exits: [], errors: [])
        check(SplitPolicy.ownedByHost("8.8.8.8", status: status), "host rule priority")
        check(SplitPolicy.ownedByHost("example.org", status: status), "hostname priority")
        check(!SplitPolicy.ownedByHost("9.9.9.9", status: status), "unrelated host")
        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            let identity = try SplitIdentity.selectedApp(URL(fileURLWithPath: path))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["-dv", "--verbose=4", path]
            let pipe = Pipe(); process.standardError = pipe
            try process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
            let team = text.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst(15)) } ?? ""
            check(!team.isEmpty && identity.teamID == team, "actual signed app publisher identity")
        }
        check(SplitIdentity.sourceTeam(nil) == nil, "missing audit token is unknown identity")
        try relays()
        print("PASS: \(checks) app-policy checks and real TCP/UDP relay tests")
    }
    static func relays() throws {
        let queue = DispatchQueue(label: "split-tests.network")
        var servers: [NWConnection] = []
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { listening.signal() } }
        listener.newConnectionHandler = { connection in
            servers.append(connection)
            var bytes = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
                    if let data { bytes.append(data) }
                    if error != nil { connection.cancel(); return }
                    if done { connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) }
                    else { receive() }
                }
            }
            connection.start(queue: queue); receive()
        }
        listener.start(queue: queue)
        check(listening.wait(timeout: .now() + 5) == .success, "TCP listener ready")
        let endpoint = Network.NWEndpoint.hostPort(host: "127.0.0.1", port: listener.port!)
        let warmup = NWConnection(to: endpoint, using: .tcp)
        let pathReady = DispatchSemaphore(value: 0)
        var loopback: NWInterface?
        warmup.stateUpdateHandler = { state in
            if case .ready = state { loopback = warmup.currentPath?.availableInterfaces.first { $0.type == .loopback }; pathReady.signal() }
        }
        warmup.start(queue: queue)
        check(pathReady.wait(timeout: .now() + 5) == .success && loopback != nil, "obtain real loopback interface")
        warmup.cancel()
        check(relayParameters(interface: loopback!).requiredInterface?.index == loopback!.index, "TCP interface required")
        let payload = Data((0..<1_048_576).map { UInt8($0 % 251) })
        let channel = MemoryTCP(payload)
        let completed = DispatchSemaphore(value: 0)
        let relay = TCPRelay(channel: channel, endpoint: endpoint, interface: loopback!, queue: queue) { completed.signal() }
        queue.async { relay.start() }
        check(completed.wait(timeout: .now() + 15) == .success, "TCP completion after half-close")
        queue.sync {
            check(channel.received == payload, "TCP byte preservation across half-close")
            check(channel.opens == 1 && channel.errors.isEmpty, "TCP opens once without errors")
            check(channel.maxWrite <= 65536, "TCP receive backpressure")
        }
        let ipv6TCP = MemoryTCP(Data(repeating: 17, count: 1024))
        let ipv6Done = DispatchSemaphore(value: 0)
        let ipv6Relay = TCPRelay(channel: ipv6TCP, endpoint: .hostPort(host: "::1", port: listener.port!), interface: loopback!, queue: queue) { ipv6Done.signal() }
        queue.async { ipv6Relay.start() }
        check(ipv6Done.wait(timeout: .now() + 5) == .success, "IPv6 TCP completes")
        queue.sync { check(ipv6TCP.received == ipv6TCP.payload && ipv6TCP.errors.isEmpty, "IPv6 TCP data preserved on required interface") }
        func udpEcho(family: Int32 = AF_INET) -> (Int32, UInt16, DispatchSourceRead) {
            let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
            var buffer: Int32 = 131072
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_storage()
            if family == AF_INET {
                withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); $0.pointee.sin_family = sa_family_t(AF_INET)
                    $0.pointee.sin_addr.s_addr = inet_addr("127.0.0.1")
                } }
            } else {
                withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); $0.pointee.sin6_family = sa_family_t(AF_INET6)
                    _ = inet_pton(AF_INET6, "::1", &$0.pointee.sin6_addr)
                } }
            }
            var size = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }
            check(result == 0, "UDP echo bind")
            withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &size) } }
            let port: UInt16 = withUnsafePointer(to: &address) { pointer in
                family == AF_INET ? pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port.bigEndian }
                    : pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port.bigEndian }
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler {
                var bytes = [UInt8](repeating: 0, count: 65536)
                var source = sockaddr_storage(); var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
                withUnsafeMutablePointer(to: &source) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { source in
                    let count = recvfrom(fd, &bytes, bytes.count, 0, source, &size)
                    if count >= 0 { _ = sendto(fd, bytes, count, 0, source, size) }
                } }
            }
            reader.setCancelHandler { Darwin.close(fd) }; reader.resume()
            return (fd, port, reader)
        }
        let udp1 = udpEcho(), udp2 = udpEcho(), udp6 = udpEcho(family: AF_INET6)
        let first = Network.NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: udp1.1)!)
        let second = Network.NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: udp2.1)!)
        let ipv6 = Network.NWEndpoint.hostPort(host: "::1", port: NWEndpoint.Port(rawValue: udp6.1)!)
        let batch = [(Data("IPv6".utf8), ipv6), (Data("one".utf8), first), (Data(), first), (Data(repeating: 42, count: 64000), second)]
        let datagrams = MemoryUDP(batch)
        let udp = UDPRelay(channel: datagrams, interface: loopback!, queue: queue, done: {})
        queue.async { udp.start() }
        let receivedAll = datagrams.received.wait(timeout: .now() + 10) == .success
        check(receivedAll, "UDP receive all datagrams")
        queue.sync {
            for (data, endpoint) in batch {
                check(datagrams.replies.contains { $0.0 == data && $0.1 == endpoint }, "UDP payload and source endpoint preserved")
            }
            check(datagrams.errors.isEmpty, "UDP relay no errors")
            udp.cancel()
        }
        listener.cancel(); udp1.2.cancel(); udp2.2.cancel(); udp6.2.cancel(); queue.sync { servers.forEach { $0.cancel() } }
    }
}
