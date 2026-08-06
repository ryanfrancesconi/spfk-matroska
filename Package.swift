// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-matroska",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "SPFKMatroska",
            targets: ["SPFKMatroska", "SPFKMatroskaC"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-mkvparser", from: "1.0.0"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-base", from: "1.2.2"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-video", from: "1.1.0"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "SPFKMatroska",
            dependencies: [
                .targetItem(name: "SPFKMatroskaC", condition: nil),
                .product(name: "SPFKBase", package: "spfk-base"),
                .product(name: "SPFKVideo", package: "spfk-video"),
            ]
        ),
        .target(
            name: "SPFKMatroskaC",
            dependencies: [
                .product(name: "mkvparser", package: "spfk-mkvparser"),
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include_private"),
            ]
        ),
        .testTarget(
            name: "SPFKMatroskaTests",
            dependencies: [
                .targetItem(name: "SPFKMatroska", condition: nil),
                .product(name: "SPFKVideo", package: "spfk-video"),
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
