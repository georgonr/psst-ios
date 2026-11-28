// PSST (L1): Meshtastic streaming protocol (serial / TCP) — https://meshtastic.org/docs/development/device/client-api/
// Every protobuf is preceded by a 4-byte header: START1 0x94, START2 0xC3, length MSB, length LSB.
// Anything between frames is device debug output (log text). A length > 512 is treated as corrupt: resync on START1.
import Foundation

public enum StreamFraming {
    public static let start1: UInt8 = 0x94
    public static let start2: UInt8 = 0xC3
    public static let maxPacket = 512

    /// Header + protobuf bytes, ready to write to the serial port.
    public static func frame(_ payload: Data) -> Data {
        precondition(payload.count <= maxPacket, "ToRadio larger than 512 bytes")
        var out = Data([start1, start2, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        out.append(payload)
        return out
    }

    /// Bytes the official clients send first so a sleeping device wakes up and resyncs its parser (32 × START2).
    public static var wakeSequence: Data { Data(repeating: start2, count: 32) }
}

/// Incremental parser: feed arbitrary chunks of the byte stream, get complete FromRadio protobufs and the debug text.
public struct StreamDeframer {
    private var buffer = Data()
    public private(set) var debugText = Data()

    public init() {}

    /// Returns complete payloads found so far (in order). Partial data is kept for the next call.
    public mutating func feed(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            guard let start = buffer.firstIndex(of: StreamFraming.start1) else {
                debugText.append(buffer)
                buffer.removeAll()
                break
            }
            if start > buffer.startIndex {
                debugText.append(buffer[buffer.startIndex..<start])
                buffer.removeSubrange(buffer.startIndex..<start)
            }
            // buffer now starts with START1
            guard buffer.count >= 2 else { break }
            let b = buffer.startIndex
            if buffer[b + 1] != StreamFraming.start2 {
                // not a header — the 0x94 was text; skip it and look for the next START1
                debugText.append(buffer[b])
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 4 else { break }
            let length = Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
            if length > StreamFraming.maxPacket {
                buffer.removeFirst() // corrupt: resync on the next START1
                continue
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[(b + 4)..<(b + 4 + length)]))
            buffer.removeSubrange(b..<(b + 4 + length))
        }
        return frames
    }

    /// Takes the accumulated device debug text (complete lines) — for logging only.
    public mutating func takeDebugLines() -> [String] {
        guard let lastNewline = debugText.lastIndex(of: 0x0A) else { return [] }
        let chunk = debugText[debugText.startIndex...lastNewline]
        debugText.removeSubrange(debugText.startIndex...lastNewline)
        return String(decoding: chunk, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}
