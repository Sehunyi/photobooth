import UIKit
import WebKit
import AVFoundation

/// 포토부스 화면(웹)을 띄우고, 웹이 못 하는 일(프린터로 바로 인쇄, 공유)을 아이패드 기능으로 처리함.
final class BoothViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIPrintInteractionControllerDelegate, UIPrinterPickerControllerDelegate {

    private var webView: WKWebView!
    private var server: LocalServer?
    private let port: UInt16 = 8723
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // 화면이 꺼지지 않게
        UIApplication.shared.isIdleTimerDisabled = true

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
        switch paper {
        case "lsize":
            paperSize = CGSize(width: 89.0 / 25.4 * 72.0, height: 119.0 / 25.4 * 72.0)
        case "card":
            paperSize = CGSize(width: 54.0 / 25.4 * 72.0, height: 86.0 / 25.4 * 72.0)
        default:
            paperSize = CGSize(width: 100.0 / 25.4 * 72.0, height: 148.0 / 25.4 * 72.0)
        }
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
