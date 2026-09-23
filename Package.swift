// swift-tools-version: 6.2
// Hangar — an Ecto-inspired query layer for Postgres, built directly on
// PostgresNIO. See hangar-design.md (repo root) and README.md.
import PackageDescription
import Foundation
import CompilerPluginSupport

let package = Package(
    name: "hangar",
    platforms: [
        // Matches the Alula family floor (Mutex/Synchronization on Darwin).
        // Linux with a Swift 6.2 toolchain is unaffected by this stanza.
        .macOS(.v15)
    ],
    products: [
        .library(name: "Hangar", targets: ["Hangar"]),
        // A separate product: generating models from a live database is a
        // build-time chore, and nothing depending on Hangar at runtime should
        // carry it.
        .library(name: "HangarIntrospection", targets: ["HangarIntrospection"]),
        // Test helpers. Its own product so an application links it from a test
        // target only — nothing in a release build should carry a sandbox that
        // exists to roll transactions back.
        .library(name: "HangarTesting", targets: ["HangarTesting"])
    ],
    dependencies: [
        // The design's dependency list (header): PostgresNIO, swift-log,
        // swift-metrics, swift-syntax. Nothing from Alula.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Phase 5 gave the metrics facade its call sites (query duration
        // timers in Repo.execute), so the no-facade-deps-without-callers
        // policy is satisfied now.
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        // Changeset/ValidatedChanges/TableModel — the Alula-independent
        // validation + dirty-tracking layer. Extracted from
        // alula-data-core precisely so Hangar could consume it.
        // Pinned to 0.1.x explicitly: SwiftPM's `from:` means "up to next
        // major" even for a 0.x version, so `from: "0.1.0"` silently picked
        // up 0.2.0 the moment it was published — a breaking release
        // (`ValidatedChanges.init` gained a required `tableName`) that broke
        // every fresh CI checkout because this repo has no committed
        // Package.resolved to hold a version back. Bump this deliberately,
        // together with the source changes 0.2.0's new API needs.
        .package(url: "https://github.com/Alula-Framework/swift-changeset.git", .upToNextMinor(from: "0.2.0")),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        // Test-only: property-based testing with shrinking, for the renderer
        // invariants that hold across every predicate shape rather than the
        // handful anyone writes by hand. Pinned to the minor for the same
        // reason swift-changeset is — no committed Package.resolved.
        .package(
            url: "https://github.com/x-sheep/swift-property-based.git",
            .upToNextMinor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "HangarTesting",
            dependencies: [
                "Hangar",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "HangarIntrospection",
            dependencies: [
                "Hangar",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Hangar",
            dependencies: [
                "HangarMacrosImpl",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Changesets", package: "swift-changeset"),
            ],
            swiftSettings: [
                // Strict concurrency is the default under tools 6.x; kept
                // explicit as documentation of intent.
                .swiftLanguageMode(.v6)
            ]
        ),
        .macro(
            name: "HangarMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "HangarTests",
            dependencies: [
                "HangarIntrospection",
                "HangarTesting",
                "Hangar",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
        // Benchmarks live in an executable, not the test suite: they need a
        // real server, they take seconds not milliseconds, and their output
        // is numbers to read rather than assertions to pass. Run with
        // `swift run -c release hangar-bench` (see BENCHMARKS.md).
        .executableTarget(
            name: "hangar-bench",
            dependencies: [
                "Hangar",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Macro fixture suite (design §4.4: fixtures ARE the spec). XCTest,
        // because assertMacroExpansion ships in SwiftSyntaxMacrosTestSupport
        // as XCTest-based.
        .testTarget(
            name: "HangarMacroTests",
            dependencies: [
                "HangarMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)

// Documentation tooling only, gated so consumers never resolve it.
if ProcessInfo.processInfo.environment["HANGAR_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}
