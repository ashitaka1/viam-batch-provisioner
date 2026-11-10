// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViamBatchProvisioner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProvisionerPXE", targets: ["ProvisionerPXE"]),
        .executable(name: "provisioner-pxe", targets: ["provisioner-pxe"]),
        .library(name: "ProvisionerNetbootXPC", targets: ["ProvisionerNetbootXPC"]),
        .executable(name: "ProvisionerNetboot", targets: ["ProvisionerNetboot"]),
        .executable(name: "provisioner-netbootctl", targets: ["provisioner-netbootctl"]),
        .library(name: "ProvisionerAPI", targets: ["ProvisionerAPI"]),
        .library(name: "ProvisionerKit", targets: ["ProvisionerKit"]),
        .library(name: "ViamAPI", targets: ["ViamAPI"]),
        .executable(name: "provisioner-probe", targets: ["provisioner-probe"]),
        .executable(name: "provisioner-handoff", targets: ["provisioner-handoff"]),
        .executable(name: "ViamProvisioner", targets: ["ViamProvisioner"]),
        .library(name: "ProvisionerServer", targets: ["ProvisionerServer"]),
        .executable(name: "provisioner-server", targets: ["provisioner-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
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
        .target(name: "ProvisionerNetbootXPC"),
        .target(
            name: "ProvisionerNetbootCore",
            dependencies: ["ProvisionerNetbootXPC", "ProvisionerPXE"]
        ),
        .executableTarget(
            name: "ProvisionerNetboot",
            dependencies: ["ProvisionerNetbootCore", "ProvisionerNetbootXPC"]
        ),
        .executableTarget(
            name: "provisioner-netbootctl",
            dependencies: ["ProvisionerNetbootXPC"]
        ),
        .testTarget(
            name: "ProvisionerNetbootTests",
            dependencies: [
                "ProvisionerNetbootCore",
                "ProvisionerNetbootXPC",
                "ProvisionerPXE",
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
            name: "ProvisionerKeyHandoffHost",
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
            name: "provisioner-handoff",
            dependencies: ["ProvisionerKeyHandoffHost", "ProvisionerKit"]
        ),
        .testTarget(
            name: "ProvisionerKeyHandoffHostTests",
            dependencies: ["ProvisionerKeyHandoffHost", "ProvisionerKit"]
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
        .target(
            name: "ProvisionerServer",
            dependencies: [
                "ProvisionerAPI",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .target(name: "ProvisionerNetbootXPC", condition: .when(platforms: [.macOS])),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .executableTarget(
            name: "provisioner-server",
            dependencies: ["ProvisionerServer"]
        ),
        .testTarget(
            name: "ProvisionerServerTests",
            dependencies: [
                "ProvisionerServer",
                "ProvisionerAPI",
                "ProvisionerKit",
                .target(name: "ProvisionerNetbootXPC", condition: .when(platforms: [.macOS])),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "ServiceLifecycleTestKit", package: "swift-service-lifecycle"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
    ]
)
