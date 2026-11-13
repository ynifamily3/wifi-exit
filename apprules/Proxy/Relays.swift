import Foundation
import Network
import Darwin

protocol TCPChannel: AnyObject {
    func open(_ completion: @escaping (Error?) -> Void)
    func read(_ completion: @escaping (Data?, Error?) -> Void)
    func write(_ data: Data, completion: @escaping (Error?) -> Void)
    func closeRead(_ error: Error?)
    func closeWrite(_ error: Error?)
}
protocol UDPChannel: AnyObject {
    func open(_ completion: @escaping (Error?) -> Void)
    func read(_ completion: @escaping ([(Data, Network.NWEndpoint)]?, Error?) -> Void)
    func write(_ datagrams: [(Data, Network.NWEndpoint)], completion: @escaping (Error?) -> Void)
    func close(_ error: Error?)
}
protocol SplitSession: AnyObject { func cancel() }

func relayError(_ text: String) -> NSError { NSError(domain: "WiFiExit.AppRules", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

/// No TLS termination: forward bytes/datagrams unchanged, requiring exactly one interface.
func relayParameters(interface: NWInterface) -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.requiredInterface = interface
    parameters.includePeerToPeer = true
    return parameters
}

final class TCPRelay: SplitSession {
    private let channel: TCPChannel
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var done: (() -> Void)?
    private var ended = false, outboundEOF = false, inboundEOF = false
    private var opened = false

    init(channel: TCPChannel, endpoint: Network.NWEndpoint, interface: NWInterface, queue: DispatchQueue, done: @escaping () -> Void) {
        self.channel = channel; self.queue = queue; self.done = done
        connection = NWConnection(to: endpoint, using: relayParameters(interface: interface))
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.ended else { return }
            switch state {
            case .ready:
                guard !self.opened else { return }; self.opened = true
                self.channel.open { error in self.queue.async {
                    guard !self.ended else { return }
                    if let error { self.finish(error); return }
                    self.outbound(); self.inbound()
                } }
            case .failed(let error): if !self.opened { self.finish(error) }
            case .waiting(let error): self.finish(error) // never retry through another interface
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let self, !self.opened { self.finish(relayError("출구 연결 시간 초과")) }
        }
    }
    func cancel() { finish(relayError("규칙 또는 네트워크 변경")) }
    private func outbound() {
        guard !ended else { return }
        channel.read { [weak self] data, error in guard let self else { return }; self.queue.async {
            guard !self.ended else { return }
            if let error { self.finish(error); return }
            if let data, !data.isEmpty {
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { self.finish(error) } else { self.outbound() }
                })
            } else {
                self.outboundEOF = true
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    // A peer can finish its TCP side before the final send callback runs.
                    // Keep draining buffered inbound bytes instead of cancelling the read side.
                    self.channel.closeRead(error); self.finishIfBothClosed()
                })
            }
        } }
    }
    private func inbound() {
        guard !ended else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            let next = {
                if let error { self.finish(error) }
                else if complete { self.inboundEOF = true; self.channel.closeWrite(nil); self.finishIfBothClosed() }
                else { self.inbound() }
            }
            if let data, !data.isEmpty {
                self.channel.write(data) { error in self.queue.async {
                    guard !self.ended else { return }
                    if let error { self.finish(error) } else { next() }
                } }
            } else { next() }
        }
    }
    private func finishIfBothClosed() { if outboundEOF && inboundEOF { finish(nil) } }
    private func finish(_ error: Error?) {
        guard !ended else { return }; ended = true
        connection.stateUpdateHandler = nil; connection.viabilityUpdateHandler = nil; connection.cancel()
        channel.closeRead(error); channel.closeWrite(error)
        let callback = done; done = nil; callback?()
    }
}

/// BSD datagram sockets preserve zero-length packets as well as large UDP datagrams.
/// Both address families are bound before connect; a route change cannot select another link.
final class BoundDatagram {
    private static let resolvers = DispatchSemaphore(value: 16)
    private let endpoint: Network.NWEndpoint
    private let interface: NWInterface
    private let queue: DispatchQueue
    private let received: (Data, @escaping (Error?) -> Void) -> Void
    private let failed: (Error) -> Void
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var paused = false, ended = false
    private var pending: (Data, (Error?) -> Void)?

    init(endpoint: Network.NWEndpoint, interface: NWInterface, queue: DispatchQueue,
         received: @escaping (Data, @escaping (Error?) -> Void) -> Void, failed: @escaping (Error) -> Void) {
        self.endpoint = endpoint; self.interface = interface; self.queue = queue
        self.received = received; self.failed = failed
    }
    func start() {
        guard Self.resolvers.wait(timeout: .now()) == .success else { failed(relayError("주소 조회 한도 초과")); return }
        let endpoint = self.endpoint, index = interface.index
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.connect(endpoint, index: UInt32(index))
            Self.resolvers.signal()
            guard let self else { if case .success(let fd) = result { Darwin.close(fd) }; return }
            self.queue.async { [self] in
                if self.ended { if case .success(let fd) = result { Darwin.close(fd) }; return }
                switch result {
                case .failure(let error): self.failed(error)
                case .success(let fd):
                    self.fd = fd
                    let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                    reader.setEventHandler { [weak self] in self?.read() }
                    reader.setCancelHandler { Darwin.close(fd) }; reader.resume(); self.reader = reader
                    if let (data, completion) = self.pending { self.pending = nil; self.send(data, completion: completion) }
                }
            }
        }
    }
    private static func connect(_ endpoint: Network.NWEndpoint, index: UInt32) -> Result<Int32, Error> {
        guard case .hostPort(let host, let port) = endpoint else { return .failure(relayError("지원하지 않는 UDP 목적지")) }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var first: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo("\(host)", "\(port.rawValue)", &hints, &first)
        guard code == 0, let first else { return .failure(relayError("UDP 목적지 주소 조회 실패")) }; defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastError: Int32 = EHOSTUNREACH
        while let address = current {
            defer { current = address.pointee.ai_next }
            let family = address.pointee.ai_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { lastError = errno; continue }
            var buffer: Int32 = 131072
            guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                lastError = errno; Darwin.close(fd); continue
            }
            var index = index
            let bound = family == AF_INET
                ? setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                : setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            if bound == 0, Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                _ = fcntl(fd, F_SETFL, O_NONBLOCK); return .success(fd)
            }
            lastError = errno; Darwin.close(fd)
        }
        return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(lastError)))
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !ended else { completion(relayError("UDP 연결 종료됨")); return }
        guard fd >= 0 else { pending = (data, completion); return }
        let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
        if sent == data.count { completion(nil); return }
        if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            pending = (data, completion)
            guard writer == nil else { return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.writer?.cancel(); self.writer = nil
                if let (data, completion) = self.pending { self.pending = nil; self.send(data, completion: completion) }
            }
            source.resume(); writer = source; return
        }
        completion(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
    }
    private func read() {
        guard !ended, !paused else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK { failed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
            return
        }
        reader?.suspend(); paused = true
        received(Data(bytes.prefix(count))) { [weak self] error in
            guard let self else { return }; self.queue.async {
                guard !self.ended else { return }
                if let error { self.failed(error) } else { self.paused = false; self.reader?.resume() }
            }
        }
    }
    func cancel() {
        guard !ended else { return }; ended = true
        writer?.cancel(); writer = nil; pending = nil
        if paused { reader?.resume(); paused = false }
        reader?.cancel(); reader = nil
    }
}

final class UDPRelay: SplitSession {
    private let channel: UDPChannel
    private let interface: NWInterface
    private let queue: DispatchQueue
    private var done: (() -> Void)?
    private var peers: [Network.NWEndpoint: BoundDatagram] = [:]
    private var ended = false
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?

    init(channel: UDPChannel, interface: NWInterface, queue: DispatchQueue, done: @escaping () -> Void) {
        self.channel = channel; self.interface = interface; self.queue = queue; self.done = done
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }; if Date().timeIntervalSince(self.lastActivity) > 120 { self.finish(nil) }
        }
        timer.resume(); self.timer = timer
        channel.open { [weak self] error in guard let self else { return }; self.queue.async {
            if let error { self.finish(error) } else { self.read() }
        } }
    }
    func cancel() { finish(relayError("규칙 또는 네트워크 변경")) }
    private func read() {
        guard !ended else { return }
        channel.read { [weak self] batch, error in guard let self else { return }; self.queue.async {
            guard !self.ended else { return }
            if let error { self.finish(error); return }
            guard let batch, !batch.isEmpty else { self.finish(nil); return }
            guard batch.count <= 256, batch.reduce(0, { $0 + $1.0.count }) <= 1_048_576,
                  batch.allSatisfy({ $0.0.count <= 65507 }) else { self.finish(relayError("UDP 버퍼 한도 초과")); return }
            self.lastActivity = Date(); self.send(batch, index: 0)
        } }
    }
    private func send(_ batch: [(Data, Network.NWEndpoint)], index: Int) {
        guard !ended else { return }
        guard index < batch.count else { read(); return }
        let (data, endpoint) = batch[index]
        let connection: BoundDatagram
        if let existing = peers[endpoint] { connection = existing }
        else {
            guard peers.count < 32 else { finish(relayError("UDP 목적지 한도 초과")); return }
            connection = BoundDatagram(endpoint: endpoint, interface: interface, queue: queue, received: { [weak self] data, resume in
                guard let self, !self.ended else { resume(relayError("UDP 연결 종료됨")); return }
                self.lastActivity = Date(); self.channel.write([(data, endpoint)], completion: resume)
            }, failed: { [weak self] error in self?.finish(error) })
            peers[endpoint] = connection; connection.start()
        }
        connection.send(data) { [weak self] error in
            guard let self, !self.ended else { return }
            if let error { self.finish(error) } else { self.send(batch, index: index + 1) }
        }
    }
    private func finish(_ error: Error?) {
        guard !ended else { return }; ended = true
        timer?.cancel(); timer = nil
        for connection in peers.values { connection.cancel() }
        peers.removeAll(); channel.close(error)
        let callback = done; done = nil; callback?()
    }
}
