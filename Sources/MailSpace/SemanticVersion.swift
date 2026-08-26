import Foundation

/// Three integers, ordered the way a release train is.
///
/// Deliberately strict: anything that is not `major.minor.patch` (with an
/// optional leading `v`, and with a bare `1.0` read as `1.0.0`) fails to parse
/// and is never treated as newer than what is installed. A version string the
/// app cannot read is a reason to say so, not a reason to offer an update.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        // A pre-release or build-metadata suffix is refused rather than ignored.
        // Dropping it would make 2.0.0-beta.1 compare equal to 2.0.0, which is
        // the one comparison that must never be wrong.
        guard !text.contains("-"), !text.contains("+") else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
