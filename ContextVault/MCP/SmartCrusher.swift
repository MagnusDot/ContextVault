import Foundation

// Headroom SmartCrusher port (Swift).
// Converts JSON arrays-of-objects into a compact columnar table,
// and large single objects into key:value lines.
// Saves 40–70% tokens on structured tool outputs.
enum SmartCrusher {

    // Max rows shown inline; remainder offloaded to CCR.
    static let inlineRowLimit = 8

    // Try to crush a parsed JSON value.
    // Returns nil if the shape isn't suitable (caller falls back to minification).
    static func crush(_ value: Any) -> String? {
        if let arr = value as? [[String: Any]], arr.count >= 2 {
            return crushArray(arr)
        }
        if let obj = value as? [String: Any], obj.count >= 4 {
            return crushObject(obj)
        }
        return nil
    }

    // MARK: - Array of homogeneous objects → columnar table

    private static func crushArray(_ arr: [[String: Any]]) -> String {
        // Collect column names in first-seen order (stable across rows)
        var cols = [String]()
        var colSet = Set<String>()
        for row in arr {
            for key in row.keys.sorted() where colSet.insert(key).inserted {
                cols.append(key)
            }
        }
        guard !cols.isEmpty else { return "[]" }

        var lines = ["cols: \(cols.joined(separator: " | "))"]

        let inline = Array(arr.prefix(inlineRowLimit))
        for row in inline {
            lines.append(cols.map { formatCell(row[$0]) }.joined(separator: " | "))
        }

        let remaining = arr.count - inline.count
        if remaining > 0 {
            let tail = Array(arr.dropFirst(inline.count))
            if let data = try? JSONSerialization.data(withJSONObject: tail),
               let str = String(data: data, encoding: .utf8) {
                let hash = CCRStore.shared.put(str)
                lines.append("[\(remaining) more rows — retrieve(hash:\"\(hash)\")]")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Single object → key: value per line

    private static func crushObject(_ obj: [String: Any]) -> String {
        obj.keys.sorted()
            .map { "\($0): \(formatCell(obj[$0]))" }
            .joined(separator: "\n")
    }

    // MARK: - Cell formatter

    // Bool must be checked before NSNumber since Swift Bool bridges to NSNumber.
    static func formatCell(_ val: Any?) -> String {
        guard let val else { return "∅" }
        if val is NSNull { return "∅" }
        if let b = val as? Bool { return b ? "✓" : "✗" }
        if let s = val as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "\"\"" : (t.count <= 40 ? t : String(t.prefix(37)) + "…")
        }
        if let n = val as? NSNumber { return n.stringValue }
        if let d = val as? [String: Any] { return "{…\(d.count)keys}" }
        if let a = val as? [Any]        { return "[…\(a.count)]" }
        let s = "\(val)"
        return s.count <= 40 ? s : String(s.prefix(37)) + "…"
    }
}
