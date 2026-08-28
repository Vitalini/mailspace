import Foundation
import os

/// The one place MailSpace writes diagnostics.
///
/// **Both** stderr and `os_log`, because the two readers are different people.
/// `scripts/smoke.sh` runs the bundle as a plain process and reads what it
/// prints (stdout is reserved for the `SELFTEST …` result line) — but an app
/// launched from the Dock or Finder has no stderr at all, so for a year every
/// line this app wrote about itself in real use went nowhere. "No MailSpace
/// entries in the system log" was therefore never evidence of anything: a
/// download could fail and leave no trace a person could find.
///
/// `privacy: .public` on the message, and that is a promise the *call sites*
/// have to keep. The unified log is world-readable on this Mac and keeps for
/// days, so anything handed to `Log` has left the app's privacy boundary. The
/// rule, in three parts:
///
/// - **Never a downloaded file's name.** It is what a person wrote on a
///   contract, an invoice, an X-ray. `NavigationPolicy.redactedName` reduces one
///   to its extension and its size in bytes, which is also what a person
///   debugging this actually needs.
/// - **Never a whole URL from a page.** A Gmail address carries the id of the
///   open thread and an attachment endpoint carries the attachment's. Hosts are
///   logged; paths and fragments are not.
/// - **Never an error's own text.** A Cocoa file error spells the filename out
///   in its message and a URL error carries the failing URL, so a domain and a
///   code go in instead.
///
/// Marking the message `.private` instead would put the log back where it was —
/// unreadable, which is where a year of download failures went unnoticed. The
/// content is left out, not hidden.
enum Log {
    private static let system = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vitalii.MailSpace",
        category: "app"
    )

    /// Where a line goes. The same seam as `TabRecycler.now` and
    /// `TabRecycler.load`, and for the same reason: the recycler's log *is* the
    /// record of what it did on its own overnight, so a rule about how often it
    /// writes — "one line per webview per twelve hours" — should be a test
    /// rather than a promise. Nothing in the app ever replaces this.
    static var sink: (String) -> Void = { message in
        FileHandle.standardError.write(Data("MailSpace: \(message)\n".utf8))
        system.error("\(message, privacy: .public)")
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
