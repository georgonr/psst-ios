// PSST (L1): Meshtastic serial (USB) transport — streaming protocol with the 4-byte header, 115200 8N1.
// Used by the psst-mesh tool on the Mac to test the same PsstMesh layer the iOS app uses with a real radio.
#if os(macOS)
import Darwin
import Foundation
import PsstMesh

@MainActor
public final class SerialTransport: MeshTransport {
    public var onFromRadio: ((Data) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?
    public var onDebugLine: ((String) -> Void)?

    public let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var deframer = StreamDeframer()

    public init(path: String) { self.path = path }

    public func start() {
        onStateChange?(.connecting)
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { onStateChange?(.disconnected("open \(path): \(String(cString: strerror(errno)))")); return }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        tcsetattr(fd, TCSANOW, &t)
        // do not toggle DTR/RTS further: on ESP32 boards (Heltec) they are wired to EN/IO0 and could reset the radio
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        s.resume()
        source = s
        write(StreamFraming.wakeSequence)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.onStateChange?(.connected)
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                stop()
                onStateChange?(.disconnected("sériový port zatvorený"))
            }
            return
        }
        for frame in deframer.feed(Data(buf[0..<n])) { onFromRadio?(frame) }
        for line in deframer.takeDebugLines() { onDebugLine?(line) }
    }

    public func send(_ toRadio: Data) { write(StreamFraming.frame(toRadio)) }

    private func write(_ d: Data) {
        guard fd >= 0 else { return }
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let w = Darwin.write(fd, p.baseAddress! + off, d.count - off)
                if w < 0 {
                    if errno == EAGAIN { usleep(2000); continue }
                    break
                }
                off += w
            }
        }
    }

    public func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }
}
#endif
