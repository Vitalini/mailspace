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
}
