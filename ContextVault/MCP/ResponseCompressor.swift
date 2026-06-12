import Foundation

// ContentRouter + compression pipeline, inspired by headroom's architecture.
// Detects content type and applies the cheapest lossless (or near-lossless)
// compression. For content over the CCR threshold, offloads the tail to
// CCRStore and returns a retrieval marker.
enum ResponseCompressor {

    // Lines above this threshold trigger CCR offloading.
    static let ccrLineThreshold = 80
    // Lines shown inline when CCR kicks in.
    static let ccrInlineLines = 40

    // MARK: - Public entry point

    // Compress any MCP text response.
    // Returns the compressed string (may contain a <<ccr:…>> marker).
    static func compress(_ text: String) -> String {
        let type_ = detect(text)
        switch type_ {
        case .json:    return compressJSON(text)
        case .log:     return compressLog(text)
        case .code:    return text  // already extracted by CodeIndexer
        case .markdown: return compressMarkdown(text)
        }
    }

    // Compress a note body, applying CCR if it's too large.
    static func compressNote(_ body: String, title: String) -> String {
        let normalized = normalizeMarkdown(body)
        let lines = normalized.components(separatedBy: "\n")

        guard lines.count > ccrLineThreshold else {
            return normalized
        }

        // Offload tail to CCR
        let inline = lines.prefix(ccrInlineLines).joined(separator: "\n")
        let offloaded = lines.dropFirst(ccrInlineLines).joined(separator: "\n")
        let hash = CCRStore.shared.put(offloaded)
        let dropped = lines.count - ccrInlineLines

        return """
        \(inline)
        <<ccr:\(hash) \(dropped)_lines_offloaded — retrieve(hash:"\(hash)") for full note>>
        """
    }

    // MARK: - Content detection (ContentRouter equivalent)

    enum ContentType { case json, log, code, markdown }

    static func detect(_ text: String) -> ContentType {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") { return .json }
        if t.hasPrefix("idx:") || t.contains(": F:") || t.contains(": C:") { return .code }
        if logScore(t) > 3 { return .log }
        return .markdown
    }

    // MARK: - JSON compressor (SmartCrusher → columnar table, falls back to minification)

    static func compressJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return text }

        // SmartCrusher: arrays of objects → columnar table (40–70% savings)
        if let crushed = SmartCrusher.crush(obj) { return crushed }

        // Fallback: lossless minification (removes whitespace)
        guard let minified = try? JSONSerialization.data(withJSONObject: obj),
              let result = String(data: minified, encoding: .utf8),
              result.count < text.count
        else { return text }
        return result
    }

    // MARK: - Log compressor
    // Keeps ERROR/FAIL lines + their immediate context, drops INFO/DEBUG noise.
    // Headroom achieves 10-50× on build output with this approach.

    static func compressLog(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 20 else { return text }

        var kept: [String] = []
        let errorKeywords = ["error", "fail", "fatal", "exception", "panic", "assert",
                              "cannot", "could not", "no such", "undefined", "❌", "✗"]
        let warnKeywords  = ["warn", "warning", "deprecated", "⚠"]
        let skipKeywords  = ["debug", "trace", "verbose", "info:", "[info]"]

        var prevWasError = false
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            let isError = errorKeywords.contains { lower.contains($0) }
            let isWarn  = warnKeywords.contains  { lower.contains($0) }
            let isSkip  = !isError && !isWarn && skipKeywords.contains { lower.contains($0) }

            if isError {
                // Include 1 line of context before
                if i > 0 && !kept.contains(lines[i-1]) { kept.append(lines[i-1]) }
                kept.append(line)
                prevWasError = true
            } else if isWarn {
                kept.append(line)
                prevWasError = false
            } else if prevWasError && !isSkip {
                // 1 line of context after error
                kept.append(line)
                prevWasError = false
            } else if !isSkip && kept.count < 5 {
                // Always keep a few header lines
                kept.append(line)
            }
        }

        let dropped = lines.count - kept.count
        if dropped == 0 { return text }

        let summary = dropped > 0 ? "\n[log_compressor: \(dropped) lines dropped — INFO/DEBUG filtered]" : ""
        return kept.joined(separator: "\n") + summary
    }

    // MARK: - Markdown normalizer + compressor

    static func compressMarkdown(_ text: String) -> String {
        let normalized = normalizeMarkdown(text)
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > ccrLineThreshold else { return normalized }

        // CCR for large markdown blobs
        let inline = lines.prefix(ccrInlineLines).joined(separator: "\n")
        let offloaded = lines.dropFirst(ccrInlineLines).joined(separator: "\n")
        let hash = CCRStore.shared.put(offloaded)
        let dropped = lines.count - ccrInlineLines

        return inline + "\n<<ccr:\(hash) \(dropped)_lines_available — retrieve(hash:\"\(hash)\")>>"
    }

    // Core normalization: collapse blank lines, strip trailing spaces,
    // deduplicate identical consecutive lines.
    static func normalizeMarkdown(_ text: String) -> String {
        var result: [String] = []
        var blankRun = 0
        var prev: String? = nil

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)

            if trimmed.isEmpty {
                blankRun += 1
                if blankRun <= 1 { result.append("") }
            } else {
                blankRun = 0
                // Skip exact duplicate consecutive lines (repeated headers, separators)
                if trimmed != prev || trimmed.hasPrefix("#") {
                    result.append(trimmed)
                }
            }
            prev = trimmed.isEmpty ? prev : trimmed
        }

        // Trim leading/trailing blank lines
        while result.first == "" { result.removeFirst() }
        while result.last == "" { result.removeLast() }

        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func logScore(_ text: String) -> Int {
        let markers = ["ERROR", "WARN", "DEBUG", "INFO", "FATAL",
                       "Traceback", "at line", "stack trace", "stderr"]
        return markers.reduce(0) { text.contains($1) ? $0 + 1 : $0 }
    }
}
