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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0")
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
            dependencies: ["SwiftEffectInference"]
        )
    ]
)
