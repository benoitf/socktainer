// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "socktainer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", from : "0.2.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
    ],
    targets: [
        .executableTarget(
            name: "socktainer",
            dependencies: [
                .product(name: "ContainerClient", package: "container"),
                .product(name: "Vapor", package: "vapor"),
            ]
        )
    ]
)


