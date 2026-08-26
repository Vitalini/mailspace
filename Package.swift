// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MailSpace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MailSpace",
            path: "Sources/MailSpace"
        ),
        .testTarget(
            name: "MailSpaceTests",
            dependencies: ["MailSpace"],
            path: "Tests/MailSpaceTests"
        )
    ]
)
