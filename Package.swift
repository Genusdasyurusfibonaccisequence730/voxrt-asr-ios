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
            url: "https://github.com/VoxRT/voxrt-asr-ios/releases/download/v0.1.2/VoxrtAsrNative.xcframework.zip",
            checksum: "a086880913376bc0038480d67057c4ce7b7876ba729299c7d56633af4ca6cc4c"
        ),
    ]
)
