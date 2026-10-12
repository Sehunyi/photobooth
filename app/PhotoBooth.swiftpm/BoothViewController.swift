import UIKit
import WebKit
import AVFoundation

/// 포토부스 화면(웹)을 띄우고, 웹이 못 하는 일(프린터로 바로 인쇄, 공유)을 아이패드 기능으로 처리함.
final class BoothViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIPrintInteractionControllerDelegate, UIPrinterPickerControllerDelegate, UIDocumentInteractionControllerDelegate {

    private var webView: WKWebView!
    private var server: LocalServer?
    private let port: UInt16 = 8723
    /// 휴대폰 QR 받기용 서버 (같은 와이파이)
    private let sharePort: UInt16 = 8724
    private lazy var shareServer = ShareServer(port: sharePort)
    /// 셀피 바로 인쇄 (Canon PRINT 앱과 같은 방식)
    private let selphy = SelphyDirect()
    /// 앱 안의 화면을 못 찾을 때만 쓰는 인터넷 주소
    private let remoteURL = URL(string: "https://sehunyi.github.io/photobooth/")!
    /// 인쇄할 용지 크기(포인트). 기본: 엽서 100 x 148 mm
    private var paperSize = CGSize(width: 100.0 / 25.4 * 72.0, height: 148.0 / 25.4 * 72.0)

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.42, green: 0.24, blue: 0.66, alpha: 1.0)

        // 무음 모드여도 효과음·안내 목소리가 나오게
        // (오디오 설정은 시간이 걸릴 수 있어 화면이 멈추지 않게 백그라운드에서 — Xcode 'Hang Risk' 경고 해결)
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        // 화면이 꺼지지 않게
        UIApplication.shared.isIdleTimerDisabled = true
        // 앱으로 돌아오면 QR 받기 서버가 꺼졌을 수 있어 다시 켬 (켜져 있으면 그대로)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shareServer.resume()
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "booth")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)

        if let root = BoothViewController.findWebRoot() {
            let srv = LocalServer(root: root, port: port)
            server = srv
            srv.start { [weak self] ok in
                guard let self = self else { return }
                if ok, let url = URL(string: "http://127.0.0.1:\(self.port)/index.html") {
                    self.webView.load(URLRequest(url: url))
                } else {
                    self.webView.load(URLRequest(url: self.remoteURL))
                }
            }
        } else {
            webView.load(URLRequest(url: remoteURL))
        }
    }

    /// 앱 묶음 안에서 Web 폴더(index.html이 있는 곳)를 찾음
    static func findWebRoot() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "Web", withExtension: nil) {
            candidates.append(u)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Web"))
        for b in Bundle.allBundles {
            if let u = b.url(forResource: "Web", withExtension: nil) {
                candidates.append(u)
            }
        }
        for c in candidates {
            if fm.fileExists(atPath: c.appendingPathComponent("index.html").path) {
                return c
            }
        }
        if let en = fm.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                if u.lastPathComponent == "index.html" {
                    let dir = u.deletingLastPathComponent()
                    if fm.fileExists(atPath: dir.appendingPathComponent("mp").path) {
                        return dir
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 카메라 권한: 포토부스 화면이 카메라를 쓰면 바로 허용

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    /// 앱 안 화면을 못 열면 인터넷 주소로 한 번 대신 열기
    private var triedRemote = false
    private func loadRemote() {
        if triedRemote { return }
        triedRemote = true
        webView.load(URLRequest(url: remoteURL))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadRemote()
    }

    /// 화면 처리 과정이 메모리 부족 등으로 멈추면 자동으로 다시 불러옴
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - 웹 화면 → 아이패드 기능 호출

    /// 웹 화면이 보낸 요청 처리. 결과는 window.__boothReply(id, 결과)로 돌려줌
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return
        }
        let callId = (body["_id"] as? NSNumber)?.intValue ?? 0
        let replyHandler: (Any?, String?) -> Void = { [weak self] result, error in
            self?.reply(callId, result: result, error: error)
        }
        switch cmd {
        case "useRemote":
            loadRemote()
            replyHandler(["ok": true] as [String: Any], nil)

        case "info":
            replyHandler(["native": true, "printer": savedPrinterName ?? ""] as [String: Any], nil)

        case "pickPrinter":
            pickPrinter { name in
                replyHandler(["name": name ?? ""] as [String: Any], nil)
            }

        case "print":
            guard let b64 = body["jpeg"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler(["ok": false, "error": "bad-image"] as [String: Any], nil)
                return
            }
            var copies = 1
            if let n = body["copies"] as? NSNumber {
                copies = max(1, min(6, n.intValue))
            }
            let paper = body["paper"] as? String ?? "postcard"
            printPhoto(data, copies: copies, paper: paper) { ok, err in
                replyHandler(["ok": ok, "error": err ?? ""] as [String: Any], nil)
            }

        case "printSheet":
            guard let b64 = body["jpeg"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler(["ok": false, "error": "bad-image"] as [String: Any], nil)
                return
            }
            let paper = body["paper"] as? String ?? "postcard"
            presentPrintSheet(data, paper: paper) { ok, err in
                replyHandler(["ok": ok, "error": err ?? ""] as [String: Any], nil)
            }

        case "openIn":
            guard let b64 = body["jpeg"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler(["ok": false, "error": "bad-image"] as [String: Any], nil)
                return
            }
            openInOtherApp(data) { ok, app, err in
                replyHandler(["ok": ok, "app": app ?? "", "error": err ?? ""] as [String: Any], nil)
            }

        case "contact":
            guard let url = savedPrinterURL else {
                replyHandler(["ok": false, "error": "no-printer"] as [String: Any], nil)
                return
            }
            let flag = AnswerFlag()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if flag.answered { return }
                flag.answered = true
                replyHandler(["ok": false, "error": "timeout"] as [String: Any], nil)
            }
            UIPrinter(url: url).contactPrinter { available in
                DispatchQueue.main.async {
                    if flag.answered { return }
                    flag.answered = true
                    replyHandler(["ok": available, "error": available ? "" : "unavailable"] as [String: Any], nil)
                }
            }

        case "selphyFind":
            // 같은 Wi-Fi에서 셀피 찾기 (Canon PRINT 앱처럼)
            let prefer = body["ip"] as? String
            selphy.find(preferIP: prefer) { list, me in
                DispatchQueue.main.async {
                    replyHandler(["ok": true, "printers": list, "me": me] as [String: Any], nil)
                }
            }

        case "selphyPrint":
            // 셀피에 사진을 직접 보내 인쇄 (AirPrint를 거치지 않음)
            guard let b64 = body["jpeg"] as? String, let data = Data(base64Encoded: b64), let ip = body["ip"] as? String, !ip.isEmpty else {
                replyHandler(["ok": false, "error": "bad-request"] as [String: Any], nil)
                return
            }
            let copies = max(1, min(6, (body["copies"] as? NSNumber)?.intValue ?? 1))
            let w = (body["w"] as? NSNumber)?.intValue ?? 0
            let h = (body["h"] as? NSNumber)?.intValue ?? 0
            let borderless = (body["borderless"] as? Bool) ?? true
            selphy.printJPEG(data, ip: ip, width: w, height: h, copies: copies, borderless: borderless, progress: { [weak self] step in
                DispatchQueue.main.async {
                    self?.webView.evaluateJavaScript("window.__selphyProgress && window.__selphyProgress(\"\(step)\");", completionHandler: nil)
                }
            }, done: { ok, err, trace in
                DispatchQueue.main.async {
                    replyHandler(["ok": ok, "error": err ?? "", "trace": trace] as [String: Any], nil)
                }
            })

        case "selphyCancel":
            // 인쇄 취소: 아직 셀피가 다 받지 않은 장과 남은 장을 보내지 않음
            let wasBusy = selphy.cancel()
            replyHandler(["ok": true, "busy": wasBusy] as [String: Any], nil)

        case "lanShare":
            // 완성 사진을 같은 와이파이의 휴대폰이 QR로 받아 갈 수 있게 올려 두고, 주소와 QR 그림을 돌려줌
            guard let b64 = body["jpeg"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler(["ok": false, "error": "bad-image"] as [String: Any], nil)
                return
            }
            guard let ip = ShareServer.lanAddress() else {
                replyHandler(["ok": false, "error": "no-wifi"] as [String: Any], nil)
                return
            }
            var video: Data? = nil
            if let v = body["video"] as? String {
                video = Data(base64Encoded: v)
            }
            let videoType = body["videoType"] as? String ?? ""
            let ext = videoType.contains("webm") ? "webm" : "mp4"
            let title = body["title"] as? String ?? ""
            let token = body["token"] as? String
            var gif: Data? = nil
            if let g = body["gif"] as? String {
                gif = Data(base64Encoded: g)
            }
            let portNumber = sharePort
            shareServer.start()
            shareServer.add(photo: data, video: video, videoExt: ext, gif: gif, title: title, token: token) { tok in
                // QR 그림은 다른 일꾼 줄에서 만들고, 대답은 화면 줄(main)에서
                DispatchQueue.global(qos: .userInitiated).async {
                    var result: [String: Any] = ["ok": false, "error": "server-down"]
                    if let tok = tok {
                        let url = "http://\(ip):\(portNumber)/p/\(tok)"
                        let qr = ShareServer.qrPNG(url)?.base64EncodedString() ?? ""
                        result = ["ok": !qr.isEmpty, "url": url, "token": tok, "qr": qr, "error": qr.isEmpty ? "qr-failed" : ""]
                    }
                    DispatchQueue.main.async {
                        replyHandler(result, nil)
                    }
                }
            }

        case "webShare":
            // 인터넷 임시 링크: 사진(과 GIF)을 올리고, 받는 페이지 주소 + QR 그림을 돌려줌 (같은 와이파이가 아니어도 됨)
            let hours = WebShare.tier((body["hours"] as? NSNumber)?.intValue ?? 72)
            let knownExpiry = (body["x"] as? NSNumber)?.intValue ?? 0
            let base = body["base"] as? String ?? "https://sehunyi.github.io/photobooth/get.html"
            let title = body["title"] as? String ?? ""
            let jpeg = (body["jpeg"] as? String).flatMap { Data(base64Encoded: $0) }
            let gif = (body["gif"] as? String).flatMap { Data(base64Encoded: $0) }
            let knownPhoto = body["p"] as? String
            if jpeg == nil && (knownPhoto ?? "").isEmpty {
                replyHandler(["ok": false, "error": "bad-image"] as [String: Any], nil)
                return
            }
            let stamp = ShareServer.fileStamp()
            let finish: (String, String?, String?) -> Void = { photoName, gifName, gifErr in
                DispatchQueue.global(qos: .userInitiated).async {
                    // 이미 올린 사진에 GIF만 더하는 경우: 사진이 지워지는 시각을 그대로 씀
                    let expires = knownExpiry > 0 ? knownExpiry : Int(Date().timeIntervalSince1970) + hours * 3600
                    var url = base + "#p=" + WebShare.encode(photoName)
                    if let g = gifName { url += "&g=" + WebShare.encode(g) }
                    url += "&x=\(expires)"
                    if !title.isEmpty { url += "&t=" + WebShare.encode(String(title.prefix(14))) }
                    let qr = ShareServer.qrPNG(url)?.base64EncodedString() ?? ""
                    let result: [String: Any] = ["ok": !qr.isEmpty, "url": url, "qr": qr, "p": photoName, "x": expires, "hours": hours, "g": gifName ?? "", "gifError": gifErr ?? "", "error": qr.isEmpty ? "qr-failed" : ""]
                    DispatchQueue.main.async { replyHandler(result, nil) }
                }
            }
            let afterPhoto: (String) -> Void = { photoName in
                guard let gif = gif, !gif.isEmpty else {
                    finish(photoName, nil, nil)
                    return
                }
                WebShare.upload(gif, filename: "photobooth_\(stamp).gif", mime: "image/gif", hours: hours) { gifName, err in
                    finish(photoName, gifName, err)
                }
            }
            if let jpeg = jpeg {
                WebShare.upload(jpeg, filename: "photobooth_\(stamp).jpg", mime: "image/jpeg", hours: hours) { name, err in
                    guard let name = name else {
                        DispatchQueue.main.async { replyHandler(["ok": false, "error": err ?? "upload"] as [String: Any], nil) }
                        return
                    }
                    afterPhoto(name)
                }
            } else {
                afterPhoto(knownPhoto ?? "")
            }

        case "qr":
            // 글자 → QR 그림 (와이파이 연결 QR 등)
            let text = body["text"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let qr = text.isEmpty ? "" : (ShareServer.qrPNG(text)?.base64EncodedString() ?? "")
                DispatchQueue.main.async { replyHandler(["ok": !qr.isEmpty, "qr": qr] as [String: Any], nil) }
            }

        case "share":
            let files = body["files"] as? [[String: Any]] ?? []
            share(files) {
                replyHandler(["ok": true] as [String: Any], nil)
            }

        default:
            replyHandler(nil, "unknown command")
        }
    }

    private func reply(_ id: Int, result: Any?, error: String?) {
        var payload: [String: Any] = [:]
        if let result = result { payload["result"] = result }
        if let error = error { payload["error"] = error }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        let js = "window.__boothReply && window.__boothReply(\(id), \(text));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 프린터 저장 (한 번 고르면 계속 기억)

    private var savedPrinterURL: URL? {
        get { return UserDefaults.standard.url(forKey: "printerURL") }
        set { UserDefaults.standard.set(newValue, forKey: "printerURL") }
    }

    private var savedPrinterName: String? {
        get { return UserDefaults.standard.string(forKey: "printerName") }
        set { UserDefaults.standard.set(newValue, forKey: "printerName") }
    }

    private func pickPrinter(_ done: @escaping (String?) -> Void) {
        var initial: UIPrinter? = nil
        if let url = savedPrinterURL {
            initial = UIPrinter(url: url)
        }
        let picker = UIPrinterPickerController(initiallySelectedPrinter: initial)
        picker.delegate = self
        let rect = CGRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
        let shown = picker.present(from: rect, in: view, animated: true) { [weak self] controller, userDidSelect, _ in
            if userDidSelect, let printer = controller.selectedPrinter {
                self?.savedPrinterURL = printer.url
                self?.savedPrinterName = printer.displayName
                done(printer.displayName)
            } else {
                done(nil)
            }
        }
        // 프린터 고르는 창을 못 띄우면 바로 알려 줌 (화면이 멈추지 않게)
        if !shown {
            done(nil)
        }
    }

    // MARK: - 바로 인쇄 (인쇄 창 없이 저장된 SELPHY로 전송)

    private func printPhoto(_ data: Data, copies: Int, paper: String, done: @escaping (Bool, String?) -> Void) {
        guard let url = savedPrinterURL else {
            done(false, "no-printer")
            return
        }
        setPaper(paper)
        let printer = UIPrinter(url: url)
        // 먼저 프린터가 켜져 있고 연결되는지 확인 → 안 되면 용지 낭비 없이 바로 알려 줌
        // 프린터가 대답을 안 하면 8초 뒤 '연결 안 됨'으로 처리 (한 번만 응답)
        let flag = AnswerFlag()
        let finish: (Bool, String?) -> Void = { ok, err in
            if flag.answered { return }
            flag.answered = true
            done(ok, err)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !flag.answered && !self.printing {
                finish(false, "unavailable")
            }
        }
        printer.contactPrinter { [weak self] available in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if flag.answered { return }
                if !available {
                    finish(false, "unavailable")
                    return
                }
                self.printing = true
                let controller = UIPrintInteractionController.shared
                let info = UIPrintInfo(dictionary: nil)
                info.outputType = .photo
                info.jobName = "네컷 포토부스"
                info.orientation = .portrait
                info.duplex = .none
                controller.printInfo = info
                controller.delegate = self
                controller.showsNumberOfCopies = false
                if copies <= 1 {
                    controller.printingItems = nil
                    controller.printingItem = data
                } else {
                    controller.printingItem = nil
                    controller.printingItems = Array(repeating: data as Any, count: copies)
                }
                let started = controller.print(to: printer) { _, completed, error in
                    self.printing = false
                    if let error = error {
                        finish(false, error.localizedDescription)
                    } else {
                        finish(completed, completed ? nil : "cancelled")
                    }
                }
                if !started {
                    self.printing = false
                    finish(false, "unavailable")
                }
            }
        }
    }

    private func setPaper(_ paper: String) {
        switch paper {
        case "lsize":
            paperSize = CGSize(width: 89.0 / 25.4 * 72.0, height: 119.0 / 25.4 * 72.0)
        case "card":
            paperSize = CGSize(width: 54.0 / 25.4 * 72.0, height: 86.0 / 25.4 * 72.0)
        default:
            paperSize = CGSize(width: 100.0 / 25.4 * 72.0, height: 148.0 / 25.4 * 72.0)
        }
    }

    // MARK: - 인쇄 창 (가장 안정적: 사진 앱과 같은 방법)
    // iOS 16 이후 '창 없이 바로 인쇄'는 두 번째 인쇄부터 백지가 나오는 문제가 알려져 있어,
    // 기본은 iOS 인쇄 창을 띄우되 저장된 SELPHY를 미리 골라 둠 → '프린트'만 누르면 됨

    private var sheetBusy = false

    private func presentPrintSheet(_ data: Data, paper: String, done: @escaping (Bool, String?) -> Void) {
        if sheetBusy {
            done(false, "busy")
            return
        }
        guard let image = UIImage(data: data) else {
            done(false, "bad-image")
            return
        }
        setPaper(paper)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .photo
        info.jobName = "네컷 포토부스"
        info.orientation = .portrait
        info.duplex = .none
        if let url = savedPrinterURL {
            info.printerID = url.absoluteString
        }
        controller.printInfo = info
        controller.delegate = self
        controller.showsNumberOfCopies = true
        controller.printingItems = nil
        controller.printingItem = image
        sheetBusy = true
        let rect = CGRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
        let shown = controller.present(from: rect, in: view, animated: true) { [weak self] ctl, completed, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sheetBusy = false
                // 창에서 고른 프린터를 기억 → 다음부터 미리 골라져 있음
                if completed, let pid = ctl.printInfo?.printerID, let u = URL(string: pid) {
                    self.savedPrinterURL = u
                }
                if let error = error {
                    done(false, error.localizedDescription)
                } else {
                    done(completed, completed ? nil : "cancelled")
                }
            }
        }
        if !shown {
            sheetBusy = false
            done(false, "no-sheet")
        }
    }

    // MARK: - 다른 앱(Canon PRINT)으로 사진 넘기기
    // 셀피 '다이렉트 연결'처럼 AirPrint가 안 되는 상황에서도 캐논 앱은 인쇄가 됨

    private var docController: UIDocumentInteractionController?
    private var openInDone: ((Bool, String?, String?) -> Void)?
    private var openInApp: String?
    private var leftApp = false
    private var resignObserver: NSObjectProtocol?

    private func openInOtherApp(_ data: Data, done: @escaping (Bool, String?, String?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photobooth_print.jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            done(false, nil, "write-failed")
            return
        }
        let dc = UIDocumentInteractionController(url: url)
        dc.uti = "public.jpeg"
        dc.name = "네컷 사진"
        dc.delegate = self
        docController = dc
        openInDone = done
        openInApp = nil
        leftApp = false
        if let o = resignObserver {
            NotificationCenter.default.removeObserver(o)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leftApp = true
        }
        let rect = CGRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
        if !dc.presentOpenInMenu(from: rect, in: view, animated: true) {
            finishOpenIn(false, "no-app")
        }
    }

    private func finishOpenIn(_ ok: Bool, _ err: String?) {
        guard let done = openInDone else { return }
        openInDone = nil
        if let o = resignObserver {
            NotificationCenter.default.removeObserver(o)
            resignObserver = nil
        }
        done(ok, openInApp, err)
        docController = nil
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?) {
        openInApp = application ?? "app"
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        openInApp = application ?? openInApp ?? "app"
        finishOpenIn(true, nil)
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        // 앱을 골랐으면 곧 캐논 앱으로 넘어감 → 잠깐 기다렸다가 판단
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            if self.openInApp != nil || self.leftApp {
                self.finishOpenIn(true, nil)
            } else {
                self.finishOpenIn(false, "cancelled")
            }
        }
    }

    /// 인쇄 데이터를 보내는 중인지 (보내는 중에는 8초 제한을 적용하지 않음)
    private var printing = false

    /// 용지를 직접 지정 (엽서 100x148mm 등) — iOS가 엉뚱한 용지를 고르지 않게
    func printInteractionController(_ printInteractionController: UIPrintInteractionController, choosePaper paperList: [UIPrintPaper]) -> UIPrintPaper {
        return UIPrintPaper.bestPaper(forPageSize: paperSize, withPapersFrom: paperList)
    }

    // MARK: - 사진 저장·보내기 (공유 창)

    private func share(_ files: [[String: Any]], done: @escaping () -> Void) {
        let dir = FileManager.default.temporaryDirectory
        var urls: [URL] = []
        for f in files {
            guard let name = f["name"] as? String,
                  let b64 = f["b64"] as? String,
                  let data = Data(base64Encoded: b64) else { continue }
            let u = dir.appendingPathComponent(name)
            try? data.write(to: u)
            urls.append(u)
        }
        if urls.isEmpty {
            done()
            return
        }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        vc.completionWithItemsHandler = { _, _, _, _ in
            done()
        }
        present(vc, animated: true, completion: nil)
    }
}

/// 한 번만 대답하기 위한 표시
final class AnswerFlag {
    var answered = false
}
