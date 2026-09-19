// swift-tools-version: 6.2
import PackageDescription

// Not part of the workspace build. `CI/check-invalid-queries-fail.sh` compiles
// this and asserts it FAILS — see that script for why.
let package = Package(
    name: "InvalidQueries",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "InvalidQueries",
            dependencies: [.product(name: "Hangar", package: "hangar")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
