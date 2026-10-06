// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "minutes",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
        .executable(name: "minutes-cli", targets: ["minutes-cli"]),
        .executable(name: "MinutesApp", targets: ["MinutesApp"]),
    ],
    dependencies: [
        // ローカル話者分離（Phase 0 で評価。採否は Phase 0 の結果で決める）
        // NemoTextProcessing トレイトは ASR 用なので無効化し、バイナリ xcframework の取得を避ける
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7", traits: []),
        // SQLite（Store、マイグレーション、FTS5）
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // 自動更新（アプリだけが使う。署名と組み込みは scripts/build-app.sh）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "MinutesCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MinutesCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "minutes-cli",
            dependencies: ["MinutesCore"],
            path: "Sources/minutes-cli",
            exclude: ["Info.plist", "minutes-cli.entitlements"],
            linkerSettings: [
                // TCC（マイク / システム音声録音）の UsageDescription を CLI バイナリに埋め込む（SPEC §4.1）
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/minutes-cli/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "MinutesApp",
            dependencies: [
                "MinutesCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MinutesApp",
            exclude: ["Info.plist", "Minutes.entitlements"],
            resources: [.copy("Resources")],
            linkerSettings: [
                // 単体実行時（swift run）でも TCC の UsageDescription を持たせる。配布は scripts/build-app.sh の .app バンドル。
                .unsafeFlags([
                    // .app の Contents/Frameworks に入れる Sparkle.framework を探す（scripts/build-app.sh）
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/MinutesApp/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore"],
            path: "Tests/MinutesCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
