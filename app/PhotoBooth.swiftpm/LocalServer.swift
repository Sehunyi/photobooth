import Foundation
import Network

/// 앱 안에 들어 있는 포토부스 화면(Web 폴더)을 아이패드 안에서만 보여 주는 작은 서버.
/// http://127.0.0.1(아이패드 자기 자신) 는 '안전한 주소'로 취급되어 카메라를 쓸 수 있고, 인터넷이 없어도 동작함.
final class LocalServer {
    let root: URL
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "photobooth.localserver")

    init(root: URL, port: UInt16) {
        self.root = root.standardizedFileURL
        self.port = port
    }

    func start(ready: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            ready(false)
            return
        }
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.report(true, ready)
                case .failed(_):
                    self.report(false, ready)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            newListener.start(queue: queue)
            listener = newListener
        } catch {
            ready(false)
        }
    }

    private var reported = false

    /// 준비됨/실패를 한 번만 알림 (서버 전용 줄에서만 불림)
    private func report(_ ok: Bool, _ ready: @escaping (Bool) -> Void) {
        if reported { return }
        reported = true
        DispatchQueue.main.async { ready(ok) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data {
                buf.append(data)
            }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: buf.subdata(in: 0..<range.lowerBound))
            } else if isComplete || error != nil || buf.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        let text = String(decoding: header, as: UTF8.self)
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path
        if path == "/" || path.isEmpty {
            path = "/index.html"
        }
        let fileURL = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL

        var status = "200 OK"
        var body = Data()
        var type = "application/octet-stream"
        if fileURL.path.hasPrefix(root.path), let data = try? Data(contentsOf: fileURL) {
            body = data
            type = LocalServer.mimeType(fileURL.pathExtension)
        } else {
            status = "404 Not Found"
            body = Data("not found".utf8)
            type = "text/plain"
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
