// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitView",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GitView", targets: ["GitViewApp"])
    ],
    targets: [
        .target(
            name: "Shared",
            path: "GitView/Shared"
        ),
        .executableTarget(
            name: "GitViewApp",
            dependencies: ["Shared"],
            path: "GitView/GitViewApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "GitViewTests",
            dependencies: ["Shared"],
            path: "GitView/Tests/GitViewTests"
        )
    ]
)
