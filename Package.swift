// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViamBatchProvisioner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProvisionerPXE", targets: ["ProvisionerPXE"]),
        .executable(name: "provisioner-pxe", targets: ["provisioner-pxe"]),
        .library(name: "ProvisionerAPI", targets: ["ProvisionerAPI"]),
        .library(name: "ProvisionerKit", targets: ["ProvisionerKit"]),
        .library(name: "ViamAPI", targets: ["ViamAPI"]),
        .executable(name: "provisioner-probe", targets: ["provisioner-probe"]),
        .executable(name: "provisioner-pair", targets: ["provisioner-pair"]),
        .executable(name: "ViamProvisioner", targets: ["ViamProvisioner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "ProvisionerPXE",
            dependencies: [
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
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
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "ProvisionerAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .target(
            name: "ProvisionerKit",
            dependencies: [
                "ProvisionerAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .executableTarget(
            name: "provisioner-probe",
            dependencies: ["ProvisionerKit", "ViamAPI"]
        ),
        .target(
            name: "ViamAPI",
            dependencies: [
                "ProvisionerKit",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ViamAPITests",
            dependencies: [
                "ViamAPI",
                "ProvisionerKit",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "ProvisionerPairHost",
            dependencies: [
                "ProvisionerKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "ViamProvisioner",
            dependencies: ["ProvisionerKit", "ViamAPI"]
        ),
        .executableTarget(
            name: "provisioner-pair",
            dependencies: ["ProvisionerPairHost", "ProvisionerKit"]
        ),
        .testTarget(
            name: "ProvisionerPairHostTests",
            dependencies: ["ProvisionerPairHost", "ProvisionerKit"]
        ),
        .testTarget(
            name: "ProvisionerKitTests",
            dependencies: [
                "ProvisionerAPI",
                "ProvisionerKit",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
