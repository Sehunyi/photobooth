import Foundation
import Network
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 같은 와이파이에 연결된 휴대폰이 QR 코드를 찍으면 완성 사진을 받아 갈 수 있게 해 주는 작은 서버.
/// - 인터넷이 없어도 됨 (아이패드와 휴대폰이 같은 공유기에만 연결되어 있으면 됨)
/// - 사진은 앱의 임시 폴더에 최근 80장까지만 두고, 앱을 다시 켜면 모두 지움
/// - 주소에 들어가는 무작위 글자(토큰)를 아는 사람만 그 사진을 받을 수 있음
final class ShareServer {
    let port: UInt16
    private var listener: NWListener?
    private var listenerReady = false
    private var retryScheduled = false
    private let queue = DispatchQueue(label: "photobooth.share")
    private let dir: URL
    private var tokens: [String] = []
    private var titles: [String: String] = [:]
    private var videoExts: [String: String] = [:]
    private let maxItems = 80

    init(port: UInt16) {
        self.port = port
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 서버 켜기 (꺼져 있으면 다시 켬)

    private var wanted = false

    func start() {
        queue.async {
            self.wanted = true
            self.startOnQueue()
        }
    }

    /// 앱으로 돌아왔을 때: 한 번이라도 켰던 서버만 다시 켬
    func resume() {
        queue.async {
            if self.wanted { self.startOnQueue() }
        }
    }

    private func startOnQueue() {
        if listener != nil { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.listenerReady = true
                case .waiting(_), .cancelled:
                    self.listenerReady = false
                case .failed(_):
                    // 앱이 잠깐 백그라운드에 갔다 오면 끊길 수 있음 → 3초 뒤 다시 켬
                    self.listenerReady = false
                    newListener.cancel()
                    if self.listener === newListener { self.listener = nil }
                    self.scheduleRetry()
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
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        if retryScheduled { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            self.startOnQueue()
        }
    }

    // MARK: - 사진 넣기

    /// 사진(과 움직이는 사진)을 저장하고 토큰을 돌려줌. token을 주면 같은 주소의 내용을 바꿈 (움직이는 사진 추가 등)
    func add(photo: Data, video: Data?, videoExt: String, title: String, token: String?, done: @escaping (String?) -> Void) {
        queue.async {
            self.addOnQueue(photo: photo, video: video, videoExt: videoExt, title: title, token: token, waited: 0, done: done)
        }
    }

    private func addOnQueue(photo: Data, video: Data?, videoExt: String, title: String, token: String?, waited: Int, done: @escaping (String?) -> Void) {
        // 서버가 막 켜지는 중이면 잠깐(최대 3초) 기다림. 끝내 안 켜지면(포트 문제 등) 안 되는 QR을 보여 주지 않게 실패로 알림
        if !self.listenerReady {
            if waited >= 10 {
                done(nil)
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.addOnQueue(photo: photo, video: video, videoExt: videoExt, title: title, token: token, waited: waited + 1, done: done)
            }
            return
        }
        var tok = token ?? ""
        if !ShareServer.validToken(tok) || !self.tokens.contains(tok) {
            tok = ShareServer.makeToken()
        }
        do {
            try photo.write(to: self.dir.appendingPathComponent(tok + ".jpg"), options: .atomic)
            if let video = video, !video.isEmpty {
                try video.write(to: self.dir.appendingPathComponent(tok + "." + videoExt), options: .atomic)
                self.videoExts[tok] = videoExt
            }
        } catch {
            done(nil)
            return
        }
        self.titles[tok] = title
        if !self.tokens.contains(tok) {
            self.tokens.append(tok)
        }
        while self.tokens.count > self.maxItems {
            let old = self.tokens.removeFirst()
            try? FileManager.default.removeItem(at: self.dir.appendingPathComponent(old + ".jpg"))
            if let ext = self.videoExts[old] {
                try? FileManager.default.removeItem(at: self.dir.appendingPathComponent(old + "." + ext))
            }
            self.titles[old] = nil
            self.videoExts[old] = nil
        }
        done(tok)
    }

    static func makeToken() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    static func validToken(_ t: String) -> Bool {
        if t.count < 6 || t.count > 16 { return false }
        return t.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
    }

    // MARK: - 아이패드의 와이파이 주소 / QR 그림

    /// 아이패드의 와이파이(같은 공유기) 주소. 와이파이에 연결되어 있지 않으면 nil
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String? = nil
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(bitPattern: ifa.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if name == "en0" { return ip }
                if fallback == nil && (name.hasPrefix("en") || name.hasPrefix("bridge")) { fallback = ip }
            }
        }
        return fallback
    }

    static func qrPNG(_ text: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).pngData()
    }

    // MARK: - 휴대폰 요청 처리 (서버 전용 줄에서만 돌아감)

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let gotRequest = AnswerBox()
        receive(connection, buffer: Data(), gotRequest: gotRequest)
        // 요청을 보내지 않고 붙잡고만 있는 연결은 20초 뒤 끊음 (보내는 중인 연결은 그대로)
        queue.asyncAfter(deadline: .now() + 20.0) {
            if !gotRequest.value { connection.cancel() }
        }
    }

    private final class AnswerBox {
        var value = false
    }

    private func receive(_ connection: NWConnection, buffer: Data, gotRequest: AnswerBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data {
                buf.append(data)
            }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                gotRequest.value = true
                self.respond(connection, header: buf.subdata(in: 0..<range.lowerBound))
            } else if isComplete || error != nil || buf.count > 64_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buf, gotRequest: gotRequest)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        let text = String(decoding: header, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        var rangeHeader: String? = nil
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }
        let seg = path.split(separator: "/").map { String($0) }
        // /p/<토큰>  ·  /p/<토큰>/photo.jpg  ·  /p/<토큰>/live.mp4
        if seg.count >= 2, seg[0] == "p", ShareServer.validToken(seg[1]), tokens.contains(seg[1]) {
            let tok = seg[1]
            if seg.count == 2 {
                send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(page(tok).utf8), head: method == "HEAD")
                return
            }
            if seg.count == 3 && seg[2] == "photo.jpg" {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(tok + ".jpg")) {
                    send(connection, status: "200 OK", type: "image/jpeg", body: data, head: method == "HEAD", extra: "Content-Disposition: inline; filename=\"photobooth.jpg\"\r\n")
                    return
                }
            }
            if seg.count == 3, seg[2].hasPrefix("live."), let ext = videoExts[tok], seg[2] == "live." + ext {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(tok + "." + ext)) {
                    sendRanged(connection, type: ext == "webm" ? "video/webm" : "video/mp4", data: data, range: rangeHeader, head: method == "HEAD")
                    return
                }
            }
        }
        send(connection, status: "404 Not Found", type: "text/html; charset=utf-8", body: Data(missingPage().utf8), head: method == "HEAD")
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, head: Bool, extra: String = "") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        if !head {
            out.append(body)
        }
        connection.send(content: out, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    /// 휴대폰 Safari는 동영상을 조각(Range)으로 받아야 재생됨
    private func sendRanged(_ connection: NWConnection, type: String, data: Data, range: String?, head: Bool) {
        let total = data.count
        guard let range = range, range.hasPrefix("bytes="), total > 0 else {
            send(connection, status: "200 OK", type: type, body: data, head: head, extra: "Accept-Ranges: bytes\r\n")
            return
        }
        let spec = range.dropFirst(6).split(separator: ",").first.map { String($0) } ?? ""
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
        var start = 0
        var end = total - 1
        if ends.count == 2 {
            if ends[0].isEmpty, let suffix = Int(ends[1]) {
                start = max(0, total - suffix)
            } else {
                start = Int(ends[0]) ?? 0
                if let e = Int(ends[1]) { end = min(e, total - 1) }
            }
        }
        if start > end || start >= total {
            send(connection, status: "416 Range Not Satisfiable", type: "text/plain", body: Data(), head: head, extra: "Content-Range: bytes */\(total)\r\n")
            return
        }
        let part = data.subdata(in: start..<(end + 1))
        send(connection, status: "206 Partial Content", type: type, body: part, head: head, extra: "Accept-Ranges: bytes\r\nContent-Range: bytes \(start)-\(end)/\(total)\r\n")
    }

    // MARK: - 휴대폰에 보이는 화면

    private func escape(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private let style = """
    <style>
    body{margin:0;font-family:-apple-system,"Apple SD Gothic Neo",sans-serif;background:linear-gradient(160deg,#fff0f7,#f3ecff 55%,#fff8dc);color:#3a2a55;text-align:center;padding:22px 16px 40px}
    h1{font-size:24px;margin:6px 0 4px}p{margin:8px 0;line-height:1.5}
    .photo{display:block;max-width:100%;max-height:70vh;margin:16px auto;border-radius:10px;box-shadow:0 10px 30px rgba(110,60,170,.25);-webkit-touch-callout:default}
    .btn{display:block;max-width:360px;margin:12px auto;padding:16px;border-radius:999px;background:#6b3da8;color:#fff;font-size:19px;font-weight:700;text-decoration:none}
    .btn.sub{background:#ffd133;color:#3a2a00}
    .tip{font-size:15px;color:#6a5a85}.small{font-size:13px;color:#8a7aa5;margin-top:22px}
    video{max-width:100%;max-height:60vh;border-radius:10px;margin-top:20px}
    </style>
    """

    private func page(_ tok: String) -> String {
        let title = escape(titles[tok] ?? "")
        var videoPart = ""
        if let ext = videoExts[tok] {
            videoPart = """
            <video src="/p/\(tok)/live.\(ext)" playsinline muted loop autoplay controls></video>
            <a class="btn sub" href="/p/\(tok)/live.\(ext)" download="photobooth_live.\(ext)">움직이는 사진 저장</a>
            """
        }
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>네컷 사진</title>\(style)</head><body>
        <h1>📸 사진이 도착했어요!</h1>\(title.isEmpty ? "" : "<p>\(title)</p>")
        <img class="photo" src="/p/\(tok)/photo.jpg" alt="네컷 사진">
        <a class="btn" href="/p/\(tok)/photo.jpg" download="photobooth.jpg">사진 저장하기</a>
        <p class="tip">아이폰: 사진을 <b>길게 눌러</b> ‘사진 앱에 저장’<br>안드로이드: 사진을 길게 눌러 ‘이미지 다운로드’</p>
        \(videoPart)
        <p class="small">이 페이지는 행사 중에만 열려요. 지금 꼭 저장해 주세요.</p>
        </body></html>
        """
    }

    private func missingPage() -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>사진 없음</title>\(style)</head><body>
        <h1>사진을 찾을 수 없어요</h1><p>행사가 끝났거나 오래되어 지워졌어요.<br>포토부스 선생님께 말씀해 주세요.</p>
        </body></html>
        """
    }
}
