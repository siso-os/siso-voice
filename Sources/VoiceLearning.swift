import Foundation

enum VoiceLearning {
    /// Learn the changed phrase, not an entire private dictation. Broad rewrites
    /// need a manual replacement instead of an accidental global rule.
    static func correction(original: String, corrected: String) -> (from: String, to: String)? {
        var before = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var after = corrected.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while !before.isEmpty, !after.isEmpty, before.first == after.first {
            before.removeFirst(); after.removeFirst()
        }
        while !before.isEmpty, !after.isEmpty, before.last == after.last {
            before.removeLast(); after.removeLast()
        }
        guard !before.isEmpty, !after.isEmpty, before.count <= 6, after.count <= 6 else { return nil }
        let from = before.joined(separator: " ")
        let to = after.joined(separator: " ")
        guard from != to, from.count <= 100, to.count <= 100 else { return nil }
        return (from, to)
    }
}
