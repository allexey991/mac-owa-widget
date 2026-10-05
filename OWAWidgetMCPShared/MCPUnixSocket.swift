import CryptoKit
import Darwin
import Foundation

/// POSIX plumbing for the MCP Unix socket, shared by the app's listener and the bridge so a fix
/// (EINTR handling, path validation) lands on both sides at once.
public enum MCPUnixSocket {
    /// `nil` when the path does not fit `sun_path` (103 usable bytes).
    public static func address(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A connected stream socket, or `nil` when nobody listens at `path`.
    public static func connect(path: String) -> Int32? {
        guard var address = address(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        disableSigPipe(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writing to a peer that went away must fail with EPIPE, not kill the process.
    public static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes every byte, retrying short writes and EINTR. `false` once the peer is gone.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

/// Lowercase hex of the first `bytes` bytes of SHA-256: short, stable names derived from long ids.
public enum MCPShortHash {
    public static func hex(_ value: String, bytes: Int) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
