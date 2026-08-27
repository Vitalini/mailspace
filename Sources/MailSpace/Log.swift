import Foundation

/// The one place MailSpace writes diagnostics.
///
/// stderr rather than `os_log`: `scripts/smoke.sh` runs the bundle as a plain
/// process and reads what it prints, and stdout is reserved for the
/// `SELFTEST …` result line.
enum Log {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("MailSpace: \(message)\n".utf8))
    }

    /// Something that happened on its own and that the user may need to
    /// reconstruct afterwards — an automatic tab recycle, an account reported
    /// signed out. Same stream as `error`: one `log stream`/Console filter finds
    /// everything MailSpace says about itself.
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("MailSpace: \(message)\n".utf8))
    }
}
