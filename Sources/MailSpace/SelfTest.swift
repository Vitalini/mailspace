import AppKit

/// Headless launch check driven by `scripts/smoke.sh`.
///
/// With `MAILSPACE_SELFTEST=1` in the environment the app boots exactly as
/// normal, then prints a single `SELFTEST …` state line to stdout and exits.
/// It is the only non-interactive proof that the assembled bundle actually
/// starts and reaches its first-launch UI state. Inert on a normal launch.
enum SelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MAILSPACE_SELFTEST"] != nil
    }

    /// Waits for the first-launch UI to settle, prints the report, then exits.
    static func schedule(report: @escaping () -> String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("SELFTEST \(report())")
            fflush(stdout)
            exit(0)
        }
    }
}
