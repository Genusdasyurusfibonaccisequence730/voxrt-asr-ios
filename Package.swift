// swift-tools-version: 5.9
//
// VoxrtAsr — streaming speech recognition (FastConformer Hybrid
// Medium, 32M params) running on the VoxRT custom inference runtime
// (https://voxrt.com). Mirrors the Android `voxrt-asr-android`
// JitPack artefact.
//
// This file is generated per-release from the VoxRT monorepo. Do not
// edit by hand — changes here are clobbered on the next cut.

import PackageDescription

let package = Package(
    name: "VoxrtAsr",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "VoxrtAsr",
            targets: ["VoxrtAsr"]
        ),
    ],
    targets: [
        .target(
            name: "VoxrtAsr",
            dependencies: ["VoxrtAsrNative"],
            path: "Sources/VoxrtAsr"
        ),
        .binaryTarget(
            name: "VoxrtAsrNative",
            url: "https://github.com/VoxRT/voxrt-asr-ios/releases/download/v0.1.1/VoxrtAsrNative.xcframework.zip",
            checksum: "1d062778a212bace2046802561b778b7f6068e4c5541b18a0126d7e18875d561"
        ),
    ]
)
