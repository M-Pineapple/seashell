import Foundation

/// Per-user scratch folder for command scripts and captured output.
/// Lives under the user's private temporary directory (not the shared
/// `/tmp`) and is created owner-only (`0700`).
enum SeashellTemp {
    static let scriptPOSIXPermissions: Int = 0o700
    static let directoryPOSIXPermissions: Int = 0o700

    static var dir: String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("seashell")
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPOSIXPermissions]
        )
        try? fm.setAttributes([.posixPermissions: directoryPOSIXPermissions], ofItemAtPath: base)
        return base
    }
}
