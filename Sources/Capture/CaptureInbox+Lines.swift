import Foundation

// The lines of a capture's text, and the line diff a correction follows them with (capture-event-v0 §3.2).
extension CaptureInbox {
    /// What happened to one line of an earlier text in the corrected one.
    enum LineFate: Equatable { case same(Int), changed(Int), removed }

    /// The most cells the line diff's table may have (16 MB): a correction runs during the sweep, outside the clerk's
    /// poison rule, so its work is bounded whatever the size of the note.
    static let diffCells = 4_000_000

    /// A line diff: the longest common run of equal lines anchors the two texts; between anchors, old and new lines
    /// pair up in order as changed, and what is left over was removed or added. Returns each old line's fate and the
    /// indices of the added new lines. Equal lines at both ends anchor first; when what lies between them would
    /// need a table over `diffCells`, it has no anchors and its lines pair up in order.
    static func diffLines(_ old: [String], _ new: [String]) -> (fates: [LineFate], added: [Int]) {
        let n = old.count, m = new.count
        var head = 0
        while head < n, head < m, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < n - head, tail < m - head, old[n - 1 - tail] == new[m - 1 - tail] { tail += 1 }
        var anchors: [(Int, Int)] = (0..<head).map { ($0, $0) }
        let rows = n - head - tail, cols = m - head - tail
        if rows > 0, cols > 0, rows * cols <= diffCells {
            // Lines as numbers, so the table compares integers.
            var numbers: [String: Int32] = [:]
            func number(_ line: String) -> Int32 {
                if let k = numbers[line] { return k }
                let k = Int32(numbers.count)
                numbers[line] = k
                return k
            }
            let a = old[head..<(head + rows)].map(number), b = new[head..<(head + cols)].map(number)
            let width = cols + 1
            var lcs = [Int32](repeating: 0, count: (rows + 1) * width)
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: cols - 1, through: 0, by: -1) {
                    lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < rows, j < cols {
                if a[i] == b[j] {
                    anchors.append((head + i, head + j)); i += 1; j += 1
                } else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] { i += 1 } else { j += 1 }
            }
        }
        anchors += (0..<tail).map { (n - tail + $0, m - tail + $0) }
        var fates = Array(repeating: LineFate.removed, count: n)
        var added: [Int] = []
        var (a, c) = (0, 0)
        for (b, d) in anchors + [(n, m)] {
            let paired = min(b - a, d - c)
            for t in 0..<paired { fates[a + t] = .changed(c + t) }
            added += Array((c + paired)..<d)
            if b < n { fates[b] = .same(d) }
            (a, c) = (b + 1, d + 1)
        }
        return (fates, added)
    }

    /// Non-empty lines of a capture's text, trimmed, with half-open offsets in Unicode scalars
    /// (capture-event-v0 §3, spans).
    static func lines(of text: String) -> [(text: String, start: Int, end: Int)] {
        var out: [(String, Int, Int)] = []
        var current: [Unicode.Scalar] = []
        var start = 0
        func flush() {
            var lo = 0, hi = current.count
            while lo < hi, current[lo].properties.isWhitespace { lo += 1 }
            while hi > lo, current[hi - 1].properties.isWhitespace { hi -= 1 }
            if lo < hi {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: current[lo..<hi])
                out.append((String(s), start + lo, start + hi))
            }
        }
        var index = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}" {
                flush()
                current = []
                start = index + 1
            } else {
                current.append(scalar)
            }
            index += 1
        }
        flush()
        return out
    }
}
