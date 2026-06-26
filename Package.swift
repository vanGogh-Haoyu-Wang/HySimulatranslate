// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLibDir = "\(packageRoot)/Libraries/sherpa-onnx/lib"

let package = Package(
    name: "HySimulatranslate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        .executableTarget(
            name: "HySimulatranslate",
            dependencies: [
                "CSherpaOnnx",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/HySimulatranslate",
            linkerSettings: [
                .unsafeFlags(["-L", sherpaLibDir]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sherpaLibDir]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("sherpa-onnx-c-api"),
                .linkedLibrary("onnxruntime"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "HySimulatranslateTests",
            dependencies: ["HySimulatranslate"],
            path: "Tests/HySimulatranslateTests"
        ),
    ]
)
