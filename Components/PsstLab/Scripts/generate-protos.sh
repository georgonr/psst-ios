#!/usr/bin/env bash
# PSST (L1): regenerates Sources/MeshtasticProtobufs from proto/ (official meshtastic/protobufs, tag v2.8.3, GPL-3.0).
# Needs protoc (brew install protobuf) and protoc-gen-swift 1.33.3 — the same version as the SwiftProtobuf dependency:
#   git clone --branch 1.33.3 https://github.com/apple/swift-protobuf && cd swift-protobuf && git submodule update --init --depth 1
#   swift build -c release --product protoc-gen-swift
# deviceonly*.proto are left out (firmware-internal, need nanopb.proto); *.options are nanopb-only.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN="${PROTOC_GEN_SWIFT:-$(command -v protoc-gen-swift)}"
rm -f Sources/MeshtasticProtobufs/*.pb.swift
protoc --plugin=protoc-gen-swift="$PLUGIN" --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath \
  --swift_out=Sources/MeshtasticProtobufs -I proto proto/meshtastic/*.proto
echo "generated $(ls Sources/MeshtasticProtobufs | wc -l | tr -d ' ') files"
