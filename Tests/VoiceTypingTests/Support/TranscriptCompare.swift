import Foundation

/// Char-level Levenshtein distance. Used by the batch-vs-streaming diff.
/// O(len(a) * len(b)) time, O(min(len(a), len(b))) memory. Good enough for
/// transcripts up to a few thousand characters — plenty for our fixtures.
func levenshteinDistance(_ a: String, _ b: String) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }

    var previous = Array(0...bChars.count)
    var current = [Int](repeating: 0, count: bChars.count + 1)

    for i in 1...aChars.count {
        current[0] = i
        for j in 1...bChars.count {
            let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
            current[j] = min(
                previous[j] + 1,        // deletion
                current[j - 1] + 1,     // insertion
                previous[j - 1] + cost  // substitution
            )
        }
        swap(&previous, &current)
    }
    return previous[bChars.count]
}

/// Normalised similarity in [0, 1]. Strips whitespace + punctuation, lowercases,
/// so "Hello, world!" and "hello world" score 1.0. CJK substring match is
/// Character-level (grapheme clusters), so emoji / CJK compare cleanly.
func normalizedSimilarity(_ a: String, _ b: String) -> Double {
    let na = normaliseForDiff(a)
    let nb = normaliseForDiff(b)
    if na.isEmpty && nb.isEmpty { return 1.0 }
    let maxLen = max(na.count, nb.count)
    guard maxLen > 0 else { return 1.0 }
    let dist = levenshteinDistance(na, nb)
    return 1.0 - Double(dist) / Double(maxLen)
}

/// Lowercases, drops whitespace + punctuation. Punctuation drop lets
/// "my fellow Americans, ask not" and "my fellow Americans. Stop. ask not"
/// compare on the actual tokens rather than on trivial sentence splits.
func normaliseForDiff(_ s: String) -> String {
    let lower = s.lowercased()
    var out = String.UnicodeScalarView()
    let whitespace = CharacterSet.whitespacesAndNewlines
    let punctuation = CharacterSet.punctuationCharacters
    for scalar in lower.unicodeScalars where
        !whitespace.contains(scalar) && !punctuation.contains(scalar) {
        out.append(scalar)
    }
    return String(out)
}
