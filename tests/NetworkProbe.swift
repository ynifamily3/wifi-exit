import Foundation
import Network
private final class ProbeState {
    private let lock = NSLock()
    private var done = false
    func finish(_ code: Int32, _ text: String) {
        lock.lock(); if done { lock.unlock(); return }; done = true; lock.unlock()
        print(text); fflush(stdout); exit(code)
    }
}
@main struct Probe {
    static func main() {
        let udp = CommandLine.arguments.dropFirst().first == "udp"
        let queue = DispatchQueue(label: "probe")
        let connection = NWConnection(host: "1.1.1.1", port: udp ? 53 : 80, using: udp ? .udp : .tcp)
        let outcome = ProbeState()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let data: Data
                if udp {
                    var bytes: [UInt8] = [0x12,0x34,1,0,0,1,0,0,0,0,0,0]
                    for label in ["example", "com"] { bytes += [UInt8(label.count)] + Array(label.utf8) }
                    bytes += [0,0,1,0,1]; data = Data(bytes)
                } else { data = Data("GET / HTTP/1.1\r\nHost: one.one.one.one\r\nConnection: close\r\n\r\n".utf8) }
                connection.send(content: data, completion: .contentProcessed { error in if let error { outcome.finish(2, "SEND_FAILED: \(error)") } })
                if udp {
                    connection.receiveMessage { data, _, _, error in
                        if let data, data.count >= 12, data[0] == 0x12, data[1] == 0x34 { outcome.finish(0, "UDP_REPLY: \(data.count) bytes") }
                        else { outcome.finish(2, "UDP_FAILED: \(String(describing: error))") }
                    }
                } else {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        if let data, String(decoding: data, as: UTF8.self).hasPrefix("HTTP/") { outcome.finish(0, "TCP_HTTP_REPLY") }
                        else { outcome.finish(2, "TCP_FAILED: \(String(describing: error))") }
                    }
                }
            case .failed(let error): outcome.finish(2, "CONNECT_FAILED: \(error)")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { outcome.finish(3, "TIMEOUT") }
        dispatchMain()
    }
}
