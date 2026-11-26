import Foundation
import Network

/// The NavigationLab pages over HTTP on this Mac, for Safari: a file:// page that AppleScript opens in Safari waits
/// behind a "Confirm the file to load" sheet, one for each tab. It answers GET requests for the pages in
/// tests/NavigationLab, on 127.0.0.1 when it can listen there only, until `stop`.
final class LabServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    /// Starts serving; nil when it isn't listening within 5 s.
    init?() {
        let root = Integration.page("lab").deletingLastPathComponent()
        let loopback = NWParameters.tcp
        loopback.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let choices: [NWParameters] = [loopback, NWParameters.tcp]
        var started: (listener: NWListener, port: UInt16)?
        for parameters in choices where started == nil {
            started = LabServer.start(parameters, root)
        }

        guard let started else { return nil }
        listener = started.listener
        port = started.port
    }

    /// The page's address.
    func url(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(name).html") ?? Integration.page(name)
    }

    func stop() {
        listener.cancel()
    }

    private static func start(_ parameters: NWParameters, _ root: URL) -> (listener: NWListener, port: UInt16)? {
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let queue = DispatchQueue(label: "voice-assistant.lab-server")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            LabServer.receive(connection, root, Data())
        }

        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            return nil
        }

        return (listener, port)
    }

    /// Reads the request up to the end of its head, then answers it.
    private static func receive(_ connection: NWConnection, _ root: URL, _ request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var received = request
            if let data {
                received.append(data)
            }

            let headEnd = Data([13, 10, 13, 10])
            let whole: Bool = received.range(of: headEnd) != nil
            if whole || isComplete || error != nil || received.count >= 65_536 {
                LabServer.respond(connection, root, received)
            } else {
                LabServer.receive(connection, root, received)
            }
        }
    }

    /// A page of the lab's folder for "GET /name.html", else 404; then the connection closes.
    private static func respond(_ connection: NWConnection, _ root: URL, _ request: Data) {
        let line: Data = request.split(separator: 13, maxSplits: 1).first ?? Data()
        let words: [Substring] = String(decoding: line, as: UTF8.self).split(separator: " ")
        var status = "404 Not Found"
        var type = "text/plain; charset=utf-8"
        var body = Data("Not found".utf8)
        if words.count >= 2, words[0] == "GET" {
            let path: Substring = words[1].split(separator: "?").first ?? ""
            let name = String(path.drop { $0 == "/" })
            if !name.isEmpty, !name.contains("/"), let page = try? Data(contentsOf: root.appendingPathComponent(name)) {
                status = "200 OK"
                type = "text/html; charset=utf-8"
                body = page
            }
        }

        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        var response = Data(head.utf8)
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
