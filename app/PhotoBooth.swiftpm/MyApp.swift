import SwiftUI

@main
struct PhotoBoothApp: App {
    var body: some Scene {
        WindowGroup {
            BoothView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// 화면 전체를 포토부스(웹 화면 + 아이패드 기능)로 채움
struct BoothView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BoothViewController {
        return BoothViewController()
    }

    func updateUIViewController(_ uiViewController: BoothViewController, context: Context) {
    }
}
