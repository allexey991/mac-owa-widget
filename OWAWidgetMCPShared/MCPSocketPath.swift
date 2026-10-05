import Foundation

/// Where the app listens for MCP bridge connections.
///
/// One formula for both sides: the bridge recomputes it from its own bundle, so the two can never
/// disagree about the path.
///
/// - Not `$TMPDIR`: `dirhelper` deletes files there that nobody has accessed for three days, and
///   a menu-bar app keeps its socket for weeks.
/// - Short on purpose: `sun_path` holds 103 usable bytes. A name built from the full bundle id
///   took 96-98 bytes with an 11-character user name, so a longer name would have broken binding.
/// - The bundle id is hashed, not dropped, so the `.dev` build and the release build never share
///   a socket.
public enum MCPSocketPath {
    /// Usable bytes in `sockaddr_un.sun_path` (104 including the terminating NUL).
    public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func directory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("owawidget", isDirectory: true)
    }

    public static func socketURL(bundleIdentifier: String, homeDirectory: URL) -> URL {
        directory(homeDirectory: homeDirectory)
            .appendingPathComponent("mcp-\(shortHash(bundleIdentifier)).sock", isDirectory: false)
    }

    /// The real home directory, even when the caller runs in a sandbox: `NSHomeDirectory()` would
    /// return the container there, and the bridge must find the app's socket, not its own.
    public static func userHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static func fitsSocketAddress(_ url: URL) -> Bool {
        url.path.utf8.count <= maxPathBytes
    }

    static func shortHash(_ value: String) -> String {
        MCPShortHash.hex(value, bytes: 4)
    }
}
