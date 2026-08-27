import Foundation

/// The one place MailSpace writes diagnostics.
///
/// stderr rather than `os_log`: `scripts/smoke.sh` runs the bundle as a plain
/// process and reads what it prints, and stdout is reserved for the
/// `SELFTEST …` result line.
enum Log {
    /// Where a line goes. The same seam as `TabRecycler.now` and
    /// `TabRecycler.load`, and for the same reason: the recycler's log *is* the
    /// record of what it did on its own overnight, so a rule about how often it
    /// writes — "one line per webview per twelve hours" — should be a test
    /// rather than a promise. Nothing in the app ever replaces this.
    static var sink: (String) -> Void = { message in
        FileHandle.standardError.write(Data("MailSpace: \(message)\n".utf8))
    }

    static func error(_ message: String) {
        sink(message)
    }

    /// Something that happened on its own and that the user may need to
    /// reconstruct afterwards — an automatic tab recycle, an account reported
    /// signed out. Same stream as `error`: one `log stream`/Console filter finds
    /// everything MailSpace says about itself.
    static func info(_ message: String) {
        sink(message)
    }
}
