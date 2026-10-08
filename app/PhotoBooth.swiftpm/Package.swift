// swift-tools-version: 5.9

// 네컷 포토부스 아이패드 앱
// - Swift Playgrounds(아이패드) 또는 Xcode(맥)에서 이 폴더(.swiftpm)를 열어 실행합니다.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "PhotoBooth",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "PhotoBooth",
            targets: ["AppModule"],
            bundleIdentifier: "com.strangeenglish.photobooth",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.purple),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .camera(purposeString: "포토부스 사진을 찍기 위해 카메라를 사용합니다.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            resources: [
                .copy("Web")
            ]
        )
    ]
)
