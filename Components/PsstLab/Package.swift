// swift-tools-version: 6.0
// PSST (L1): psst lab — Meshtastic (LoRa) client layer, psst end-to-end encryption of LoRa messages and the LoRa UI.
//
// Modules
//   MeshtasticProtobufs  Swift code generated from the official Meshtastic protobufs v2.8.3 (GPL-3.0, see proto/LICENSE)
//   PsstMesh             transport-independent Meshtastic Client API (ToRadio/FromRadio), node DB, messages, delivery
//                        state, psst E2E crypto (X25519 + HKDF-SHA256 + ChaCha20-Poly1305), chunking, replay window
//   PsstMeshBLE          CoreBluetooth transport (Meshtastic BLE service ToRadio / FromRadio / FromNum)
//   PsstMeshSerial       serial (USB) stream transport, macOS only — used by the psst-mesh CLI for real-device tests
//   PsstLabUI            SwiftUI screens („LoRa“) used by the psst lab iOS app
//   psst-mesh            command-line tool (macOS): same PsstMesh layer over a serial port
import PackageDescription

let package = Package(
    name: "PsstLab",
    platforms: [.iOS("18.5"), .macOS(.v14)],
    products: [
        .library(name: "PsstMesh", targets: ["PsstMesh"]),
        .library(name: "PsstMeshBLE", targets: ["PsstMeshBLE"]),
        .library(name: "PsstLabUI", targets: ["PsstLabUI"]),
        .executable(name: "psst-mesh", targets: ["psst-mesh"])
    ],
    dependencies: [
        // Exact: generated code in Sources/MeshtasticProtobufs was produced by protoc-gen-swift 1.33.3 (Scripts/generate-protos.sh).
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.33.3")
    ],
    targets: [
        .target(name: "MeshtasticProtobufs",
                dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "PsstMesh", dependencies: ["MeshtasticProtobufs"]),
        .target(name: "PsstMeshBLE", dependencies: ["PsstMesh"]),
        .target(name: "PsstMeshSerial", dependencies: ["PsstMesh"]),
        .target(name: "PsstLabUI", dependencies: ["PsstMesh", "PsstMeshBLE"]),
        .executableTarget(name: "psst-mesh", dependencies: ["PsstMesh", "PsstMeshSerial", "MeshtasticProtobufs"]),
        .testTarget(name: "PsstMeshTests", dependencies: ["PsstMesh", "PsstMeshBLE", "PsstLabUI", "MeshtasticProtobufs"])
    ]
)
