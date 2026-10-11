import Foundation
import Darwin
import ImageIO

/// SELPHY 바로 인쇄 — Canon PRINT 앱과 같은 방식(캐논 SELPHY 전용 통신 'CPNP', 포트 8609)으로
/// 아이폰·아이패드 기본 인쇄(AirPrint)를 거치지 않고 셀피에 사진(JPEG)을 직접 보냄.
///
/// 순서: ① 같은 Wi-Fi 안에서 셀피 찾기(UDP) ② 인쇄 시작 요청 → 셀피가 TCP 포트를 알려 줌
///       ③ TCP로 연결 → 셀피가 "설정 줘" / "몇 번째 바이트부터 몇 바이트 줘" 하고 요청하면 사진 조각을 보냄 ④ 끝
/// (프로토콜 참고: Wilmer van der Gaast의 SELPHY CP900 클라이언트 selphy.go 분석 내용)
final class SelphyDirect {
    static let port: UInt16 = 8609
    private let queue = DispatchQueue(label: "photobooth.selphy")
    private let findQueue = DispatchQueue(label: "photobooth.selphy.find")
    private let lock = NSLock()
    private var busy = false

    // MARK: - 패킷

    static func packet(_ cmd: UInt16, seq: UInt16, job: UInt16, payload: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 0x43; p[1] = 0x50; p[2] = 0x4E; p[3] = 0x50          // "CPNP"
        p[4] = UInt8(cmd >> 8); p[5] = UInt8(cmd & 0xFF)
        p[8] = UInt8(seq >> 8); p[9] = UInt8(seq & 0xFF)
        p[10] = UInt8(job >> 8); p[11] = UInt8(job & 0xFF)
        let n = UInt32(payload.count)
        p[12] = UInt8((n >> 24) & 0xFF); p[13] = UInt8((n >> 16) & 0xFF); p[14] = UInt8((n >> 8) & 0xFF); p[15] = UInt8(n & 0xFF)
        return p + payload
    }

    static func be16(_ b: [UInt8], _ i: Int) -> Int {
        if b.count < i + 2 { return 0 }
        return Int(b[i]) << 8 | Int(b[i + 1])
    }

    static func be32(_ b: [UInt8], _ i: Int) -> Int {
        if b.count < i + 4 { return 0 }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    static func le32(_ b: [UInt8], _ i: Int) -> Int {
        if b.count < i + 4 { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    static func putLE32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF); b[i + 2] = UInt8((v >> 16) & 0xFF); b[i + 3] = UInt8((v >> 24) & 0xFF)
    }

    static func putUTF16BE(_ b: inout [UInt8], _ start: Int, _ maxBytes: Int, _ s: String) {
        var i = 0
        for u in s.utf16 {
            if i + 2 > maxBytes { break }
            b[start + i] = UInt8(u >> 8); b[start + i + 1] = UInt8(u & 0xFF)
            i += 2
        }
    }

    // MARK: - UDP

    static func udpSocket(timeoutMs: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return nil }
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    @discardableResult
    static func sendUDP(_ fd: Int32, _ bytes: [UInt8], ip: String) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(SelphyDirect.port).bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 { return false }
        let sent = bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            return withUnsafePointer(to: &addr) { ap -> Int in
                return ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                    return sendto(fd, buf.baseAddress, buf.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == bytes.count
    }

    static func recvUDP(_ fd: Int32) -> (bytes: [UInt8], ip: String)? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Int in
            return withUnsafeMutablePointer(to: &addr) { ap -> Int in
                return ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                    return recvfrom(fd, b.baseAddress, b.count, 0, sp, &len)
                }
            }
        }
        if n <= 0 { return nil }
        var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = addr.sin_addr
        _ = inet_ntop(AF_INET, &a, &ipbuf, socklen_t(INET_ADDRSTRLEN))
        let ip = ipbuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (Array(buf[0..<n]), ip)
    }

    static func isCPNP(_ b: [UInt8]) -> Bool {
        return b.count >= 16 && b[0] == 0x43 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x50
    }

    /// 아이패드의 Wi-Fi 주소와 같은 네트워크의 모든 주소 (최대 1022개)
    static func subnetHosts() -> (me: String, hosts: [String]) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ("", []) }
        defer { freeifaddrs(ifaddr) }
        var best: (name: String, ip: UInt32, mask: UInt32)? = nil
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = ifa.ifa_netmask else { continue }
            let flags = Int32(bitPattern: ifa.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            let name = String(cString: ifa.ifa_name)
            if !(name.hasPrefix("en") || name.hasPrefix("bridge")) { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if best == nil || name == "en0" { best = (name, ip, mask) }
            if name == "en0" { break }
        }
        guard let b = best else { return ("", []) }
        let toStr = { (v: UInt32) -> String in "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)" }
        var mask = b.mask
        if mask < 0xFFFFFC00 { mask = 0xFFFFFF00 }   // 너무 큰 네트워크면 내 주소 근처 256개만
        let net = b.ip & mask, bcast = net | ~mask
        var hosts: [String] = []
        if bcast > net + 1 {
            var h = net + 1
            while h < bcast {
                if h != b.ip { hosts.append(toStr(h)) }
                h += 1
            }
        }
        return (toStr(b.ip), hosts)
    }

    // MARK: - 셀피 찾기

    /// 같은 네트워크에서 셀피 찾기. 결과: [["ip":..., "mac":..., "name":...]]
    func find(preferIP: String?, done: @escaping ([[String: Any]], String) -> Void) {
        findQueue.async {
            let net = SelphyDirect.subnetHosts()
            done(SelphyDirect.findSync(preferIP: preferIP, hosts: net.hosts), net.me)
        }
    }

    static func findSync(preferIP: String?, hosts: [String]) -> [[String: Any]] {
        guard let fd = udpSocket(timeoutMs: 250) else { return [] }
        defer { close(fd) }
        var targets: [String] = []
        if let p = preferIP, !p.isEmpty { targets.append(p) }
        targets += hosts.filter { $0 != preferIP }
        let disc = packet(0x0101, seq: 1, job: 0, payload: [])
        var found: [String: [String: Any]] = [:]
        // 두 번 보냄 (Wi-Fi에서 처음 몇 개가 빠지는 경우가 있음)
        for round in 0..<2 {
            for (k, ip) in targets.enumerated() {
                sendUDP(fd, disc, ip: ip)
                if k % 32 == 31 { usleep(4000) }
            }
            let end = Date().addingTimeInterval(round == 0 ? 1.6 : 1.0)
            while Date() < end {
                guard let r = recvUDP(fd) else { continue }
                let b = r.bytes
                if !isCPNP(b) || be16(b, 4) != 0x8101 { continue }
                let body = Array(b[16...])
                var mac = ""
                if body.count > 6 {
                    let ml = Int(body[4])
                    if ml > 0 && body.count >= 6 + ml { mac = body[6..<(6 + ml)].map { String(format: "%02x", $0) }.joined(separator: ":") }
                }
                found[r.ip] = ["ip": r.ip, "mac": mac, "name": ""]
            }
            if !found.isEmpty { break }
        }
        // 이름(기종) 물어보기
        let idp = packet(0x0130, seq: 2, job: 0, payload: [0, 0, 0, 0])
        for ip in found.keys { sendUDP(fd, idp, ip: ip) }
        let end = Date().addingTimeInterval(1.2)
        var named = 0
        while Date() < end && named < found.count {
            guard let r = recvUDP(fd) else { continue }
            let b = r.bytes
            if !isCPNP(b) || be16(b, 4) != 0x8130 || b.count < 18 { continue }
            let props = String(decoding: b[18...], as: UTF8.self)
            var name = ""
            for part in props.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map { String($0) }
                if kv.count == 2 && (kv[0] == "DES" || (kv[0] == "MDL" && name.isEmpty)) { name = kv[1] }
            }
            if var f = found[r.ip], ((f["name"] as? String) ?? "").isEmpty {
                f["name"] = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
                found[r.ip] = f
                named += 1
            }
        }
        var list = Array(found.values)
        list.sort { (a, b) -> Bool in
            let pa = (a["ip"] as? String) == preferIP, pb = (b["ip"] as? String) == preferIP
            if pa != pb { return pa }
            return ((a["ip"] as? String) ?? "") < ((b["ip"] as? String) ?? "")
        }
        return list
    }

    // MARK: - 인쇄

    /// 사진(JPEG) 인쇄. progress: "send:퍼센트" / "sent" / "wait" / "copy:n"
    func printJPEG(_ jpeg: Data, ip: String, width: Int, height: Int, copies: Int, borderless: Bool,
                   progress: @escaping (String) -> Void, done: @escaping (Bool, String?, [String]) -> Void) {
        // 앞 사진을 보내는 중이면 바로 알려 줌 (두 번 눌러도 두 번 인쇄되지 않게)
        lock.lock()
        if busy {
            lock.unlock()
            done(false, "busy-app", [])
            return
        }
        busy = true
        lock.unlock()
        // 사진 크기를 안 보냈으면 JPEG에서 읽음
        var w = width, h = height
        if w <= 0 || h <= 0, let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? Int) ?? w
            h = (props[kCGImagePropertyPixelHeight] as? Int) ?? h
        }
        let fw = w, fh = h
        queue.async {
            var trace: [String] = []
            var ok = true
            var err: String? = nil
            for c in 0..<max(1, copies) {
                if copies > 1 { progress("copy:\(c + 1)") }
                let r = SelphyDirect.runJob(Array(jpeg), ip: ip, width: fw, height: fh, borderless: borderless, progress: progress, trace: &trace)
                if let e = r {
                    ok = false
                    err = e
                    break
                }
            }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            done(ok, err, Array(trace.suffix(30)))
        }
    }

    /// 한 장 인쇄. 실패하면 오류 이름을 돌려줌 (성공이면 nil)
    static func runJob(_ file: [UInt8], ip: String, width: Int, height: Int, borderless: Bool,
                       progress: (String) -> Void, trace: inout [String]) -> String? {
        guard let ufd = udpSocket(timeoutMs: 800) else { return "socket" }
        defer { close(ufd) }
        var seq: UInt16 = 10

        // UDP로 묻고 대답 받기 (3번까지 다시 보냄)
        func udpAsk(_ cmd: UInt16, _ payload: [UInt8]) -> (head: [UInt8], body: [UInt8])? {
            seq &+= 1
            let p = packet(cmd, seq: seq, job: 0, payload: payload)
            for _ in 0..<3 {
                sendUDP(ufd, p, ip: ip)
                let end = Date().addingTimeInterval(1.0)
                while Date() < end {
                    guard let r = recvUDP(ufd) else { continue }
                    let b = r.bytes
                    if isCPNP(b) && be16(b, 4) == Int(cmd | 0x8000) && be16(b, 8) == Int(seq) {
                        return (Array(b[0..<16]), Array(b[16...]))
                    }
                }
            }
            return nil
        }

        if udpAsk(0x0130, [0, 0, 0, 0]) == nil {
            trace.append("no reply from \(ip)")
            return "no-reply"
        }
        _ = udpAsk(0x0120, [])

        // 인쇄 시작 요청 → TCP 포트 받기 (셀피가 바쁘면 잠시 기다렸다 다시)
        var start = [UInt8](repeating: 0, count: 0x188)
        putUTF16BE(&start, 0x008, 0x40, "PhotoBooth")
        putUTF16BE(&start, 0x048, 0x40, "iPad")
        putUTF16BE(&start, 0x088, 0x100, "photobooth.jpg")
        var tcpPort = 0
        var job: UInt16 = 0
        // 앞 장을 인쇄하는 동안(약 1분)은 셀피가 새 인쇄를 안 받으므로 최대 2분까지 기다림
        let startDeadline = Date().addingTimeInterval(120)
        var attempt = 0
        while Date() < startDeadline {
            attempt += 1
            if let r = udpAsk(0x0110, start) {
                job = UInt16(be16(r.head, 10))
                tcpPort = be16(r.body, 4)
                if tcpPort > 0 { break }
                trace.append("start: port 0 (busy?) try \(attempt)")
            } else {
                trace.append("start: no reply try \(attempt)")
            }
            progress("wait")
            usleep(1_500_000)
        }
        if tcpPort == 0 { return "busy" }
        trace.append("tcp port \(tcpPort) job \(job)")

        // TCP 연결
        let tfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if tfd < 0 { return "socket" }
        defer { close(tfd) }
        var one: Int32 = 1
        setsockopt(tfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(tfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(tfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(tcpPort)).bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 { return "bad-ip" }
        // 연결이 오래 걸리면(최대 8초) 포기 — 기본 connect는 75초까지 멈출 수 있어서
        let fl = fcntl(tfd, F_GETFL, 0)
        _ = fcntl(tfd, F_SETFL, fl | O_NONBLOCK)
        var cr = withUnsafePointer(to: &addr) { ap -> Int32 in
            return ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int32 in
                return connect(tfd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if cr != 0 && errno == EINPROGRESS {
            var pfd = pollfd(fd: tfd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 8000) > 0 {
                var soerr: Int32 = 0
                var sl = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(tfd, SOL_SOCKET, SO_ERROR, &soerr, &sl)
                cr = soerr == 0 ? 0 : -1
            } else {
                cr = -1
            }
        }
        _ = fcntl(tfd, F_SETFL, fl)
        if cr != 0 {
            trace.append("tcp connect failed errno \(errno)")
            return "tcp-connect"
        }

        func writeAll(_ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Int in
                    return write(tfd, b.baseAddress! + off, bytes.count - off)
                }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }

        func readExact(_ count: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: count)
            var off = 0
            while off < count {
                let n = out.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Int in
                    return read(tfd, b.baseAddress! + off, count - off)
                }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return nil }
                off += n
            }
            return out
        }

        // TCP로 묻고 대답 받기
        func tcpAsk(_ cmd: UInt16, _ payload: [UInt8]) -> [UInt8]? {
            seq &+= 1
            if !writeAll(packet(cmd, seq: seq, job: job, payload: payload)) { return nil }
            for _ in 0..<4 {
                guard let head = readExact(16), isCPNP(head) else { return nil }
                let len = be32(head, 12)
                if len < 0 || len > 1_000_000 { return nil }
                let body = len > 0 ? (readExact(len) ?? []) : []
                if len > 0 && body.isEmpty { return nil }
                if be16(head, 8) == Int(seq) { return body }
            }
            return nil
        }

        var last: [UInt8] = []
        var sentBytes = 0
        var sentReported = false
        var sameCount = 0
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            guard let st = tcpAsk(0x0120, []) else {
                trace.append("status: connection lost")
                return sentReported ? "lost-after-send" : "tcp-lost"
            }
            if st.count < 0x13 {
                trace.append("status: short \(st.count)")
                usleep(300_000)
                continue
            }
            let state = Int(st[0x12])
            if st == last {
                sameCount += 1
                usleep(200_000)
                if sameCount > 1500 { return "stuck-\(state)" }
                continue
            }
            sameCount = 0
            last = st
            switch state {
            case 0x00:
                if sentBytes > 0 && !sentReported { sentReported = true; progress("sent") }
                usleep(500_000)
            case 0x01:
                trace.append("flags")
                var f = [UInt8](repeating: 0, count: 0x40)
                putLE32(&f, 0x04, 0x40)
                putLE32(&f, 0x0C, 1)
                putLE32(&f, 0x12, borderless ? 2 : 3)
                if tcpAsk(0x0121, f) == nil { return "tcp-lost" }
            case 0x02:
                let offset = le32(st, 0x18), length = le32(st, 0x1C)
                if length <= 0 || length > 8_000_000 || offset < 0 { trace.append("bad request \(offset)+\(length)"); return "bad-request" }
                var head = [UInt8](repeating: 0, count: 0x68)
                head[0x02] = 1
                putLE32(&head, 0x04, length + 0x68)
                head[0x0C] = 1
                putLE32(&head, 0x14, file.count)
                putLE32(&head, 0x18, width)
                putLE32(&head, 0x1C, height)
                putLE32(&head, 0x60, offset)
                putLE32(&head, 0x64, length)
                var chunk = head
                if offset < file.count {
                    let endIdx = min(file.count, offset + length)
                    chunk += file[offset..<endIdx]
                }
                if chunk.count < head.count + length { chunk += [UInt8](repeating: 0, count: head.count + length - chunk.count) }
                var pos = 0
                while pos < chunk.count {
                    let n = min(4096, chunk.count - pos)
                    if tcpAsk(0x0121, Array(chunk[pos..<(pos + n)])) == nil { return "tcp-lost" }
                    pos += n
                }
                sentBytes = max(sentBytes, min(file.count, offset + length))
                progress("send:\(min(100, sentBytes * 100 / max(1, file.count)))")
            case 0x03:
                trace.append("done")
                var f = [UInt8](repeating: 0, count: 0x40)
                putLE32(&f, 0x04, 0x40)
                f[2] = 0x03
                _ = tcpAsk(0x0121, f)
                if !sentReported { progress("sent") }
                return nil
            default:
                trace.append("state \(state)")
                usleep(500_000)
            }
        }
        return "timeout"
    }
}
