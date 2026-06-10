// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftEffectInference",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftEffectInference",
            targets: ["SwiftEffectInference"]
        )
    ],
    dependencies: [
        // Per docs/SwiftEffectInference Design v0.2.md §8: swift-syntax is the
        // only required dep. No swift-testing in the library target (that's
        // the swift-property-based-via-Testing.framework trap that bit
        // SwiftInferProperties M1.1). No SPL- or SwiftInfer-specific types.
        // Pinned exact to match SwiftProjectLint (one of the two initial
        // consumers, on Swift 6.2). Bump alongside SPL's pin when SPL moves.
        // URL matches SwiftProjectLint's pin (apple/swift-syntax). swift-syntax
        // moved from apple/ to swiftlang/ but both refer to the same package
        // identity; SPM warns when chains use different URLs.
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "602.0.0")
    ],
    targets: [
        .target(
            name: "SwiftEffectInference",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "SwiftEffectInferenceTests",
            dependencies: [
                "SwiftEffectInference",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        )
    ]
)
