// swift-tools-version: 5.9
// The one place the sample names the SDK. Xcode has no UI for Swift package registries, so an
// app project reaches a registry package through a small local package like this one: it
// depends on the registry identity `yonc.sdk` and re-exports the `Yonc` product; the app target
// depends on this package by path (see ../project.yml). Configure the registry once per machine:
//
//   swift package-registry set --global --scope yonc https://ymm.jfrog.io/artifactory/api/swift/ios-yonc-swift
//   swift package-registry login https://ymm.jfrog.io/artifactory/api/swift/ios-yonc-swift --username <user> --password <token>
//
// The binary XCFrameworks the package references are downloaded by SwiftPM from the same
// artifact server (checksum-verified); the login above covers them too.
import PackageDescription

let package = Package(
    name: "YoncDependencies",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "YoncDependencies", targets: ["YoncDependencies"])
    ],
    dependencies: [
        // Exact: for a 0.x version `from:` means "up to 1.0", so a fresh resolve would pick up any
        // later, possibly breaking 0.x release. Raise it deliberately.
        .package(id: "yonc.sdk", exact: "0.6.1")
    ],
    targets: [
        .target(
            name: "YoncDependencies",
            dependencies: [
                .product(name: "Yonc", package: "yonc.sdk")
            ]
        )
    ]
)
