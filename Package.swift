// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HubbleGatewaySDK",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "HubbleGatewaySDK",
            targets: ["HubbleGatewaySDK"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "HubbleGatewaySDK",
            path: "HubbleGatewaySDK.xcframework"
        )
    ]
)
