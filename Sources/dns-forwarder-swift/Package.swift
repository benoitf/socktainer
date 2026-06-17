// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "dns-forwarder",
  targets: [
    .executableTarget(name: "dns-forwarder", path: "Sources")
  ]
)
