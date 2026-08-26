// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aibar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aibar", targets: ["aibarCLI"]),
        .library(name: "AibarCore", targets: ["AibarCore"]),
    ],
    targets: [
        // 零第三方依赖：SQLite 直接用系统 libsqlite3。
        // 对一个会读取用户凭据的开源工具来说，没有供应链面本身就是一个功能。
        .target(name: "AibarCore"),
        .executableTarget(name: "aibarCLI", dependencies: ["AibarCore"]),
        .testTarget(name: "AibarCoreTests", dependencies: ["AibarCore"]),
    ]
)
