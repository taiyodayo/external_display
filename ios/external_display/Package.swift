// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "external_display",
    platforms: [
        // Scene-lifecycle external display (UIWindowScene /
        // .windowExternalDisplayNonInteractive) is iOS 16+.
        .iOS("16.0")
    ],
    products: [
        .library(name: "external-display", targets: ["external_display"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "external_display",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
