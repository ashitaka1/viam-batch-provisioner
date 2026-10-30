// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViamBatchProvisioner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProvisionerPXE", targets: ["ProvisionerPXE"]),
        .executable(name: "provisioner-pxe", targets: ["provisioner-pxe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ProvisionerPXE",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "provisioner-pxe",
            dependencies: ["ProvisionerPXE"]
        ),
        .testTarget(
            name: "ProvisionerPXETests",
            dependencies: [
                "ProvisionerPXE",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
