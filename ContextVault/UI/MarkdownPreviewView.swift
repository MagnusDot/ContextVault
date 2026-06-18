import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = renderHTML(markdown)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator { var lastHTML = "" }
}

// MARK: - HTML shell

private func renderHTML(_ md: String) -> String {
    """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:14px;
         line-height:1.65;color:light-dark(#1d1d1f,#ececec);background:transparent;
         max-width:740px;margin:0 auto;padding:24px 28px;word-break:break-word}
    h1{font-size:1.9em;font-weight:700;border-bottom:1px solid light-dark(#e4e4e4,#383838);
       padding-bottom:.3em;margin:.5em 0 .45em}
    h2{font-size:1.45em;font-weight:600;margin:.9em 0 .35em}
    h3{font-size:1.15em;font-weight:600;margin:.8em 0 .3em}
    h4,h5,h6{font-size:1em;font-weight:600;margin:.7em 0 .25em}
    p{margin:.5em 0}
    code{font-family:'SF Mono',Menlo,Consolas,monospace;font-size:.875em;
         background:light-dark(rgba(0,0,0,.07),rgba(255,255,255,.1));
         padding:1px 5px;border-radius:4px}
    pre{background:light-dark(rgba(0,0,0,.05),rgba(255,255,255,.07));
        border-radius:8px;padding:14px 16px;overflow-x:auto;margin:.75em 0}
    pre code{background:none;padding:0;font-size:.86em}
    blockquote{margin:.75em 0;padding:4px 0 4px 14px;
               border-left:3px solid light-dark(#ccc,#555);
               color:light-dark(#666,#aaa)}
    ul,ol{padding-left:1.6em;margin:.4em 0}
    li{margin:.2em 0}
    hr{border:none;border-top:1px solid light-dark(#ddd,#444);margin:1.1em 0}
    a{color:light-dark(#007AFF,#409CFF);text-decoration:none}
    a:hover{text-decoration:underline}
    strong{font-weight:600}
    del{opacity:.6}
    img{max-width:100%;border-radius:4px}
    table{border-collapse:collapse;width:100%;margin:.75em 0;font-size:.95em}
    th,td{border:1px solid light-dark(#ddd,#444);padding:6px 12px;text-align:left}
    th{background:light-dark(rgba(0,0,0,.04),rgba(255,255,255,.05));font-weight:600}
    </style></head><body>\(parseBlocks(md.isEmpty ? "*Empty note*" : md))</body></html>
    """
}

// MARK: - Block parser

private func parseBlocks(_ md: String) -> String {
    let lines = md.components(separatedBy: "\n")
    var out = ""
    var i = 0

    while i < lines.count {
        let line = lines[i]

        let fencePrefix = line.hasPrefix("```") ? "```" : (line.hasPrefix("~~~") ? "~~~" : nil)
        if let fence = fencePrefix {
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix(fence) {
                codeLines.append(htmlEscape(lines[i]))
                i += 1
            }
            let cls = lang.isEmpty ? "" : " class=\"language-\(htmlEscape(lang))\""
            out += "<pre><code\(cls)>\(codeLines.joined(separator: "\n"))</code></pre>"
            i += 1
            continue
        }

        if line.hasPrefix("#") {
            var lvl = 0
            for ch in line { if ch == "#" { lvl += 1 } else { break } }
            if lvl <= 6 {
                let rest = String(line.dropFirst(lvl)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    out += "<h\(lvl)>\(inline(rest))</h\(lvl)>"
                    i += 1; continue
                }
            }
        }

        let stripped = line.filter { !$0.isWhitespace }
        if (stripped == "---" || stripped == "***" || stripped == "___") && stripped.count >= 3 {
            out += "<hr>"; i += 1; continue
        }

        if line.hasPrefix(">") {
            var bq: [String] = []
            while i < lines.count && lines[i].hasPrefix(">") {
                let rest = lines[i].dropFirst()
                bq.append(rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest))
                i += 1
            }
            out += "<blockquote>\(parseBlocks(bq.joined(separator: "\n")))</blockquote>"
            continue
        }

        if isUL(line) {
            out += "<ul>"
            while i < lines.count && isUL(lines[i]) {
                out += "<li>\(inline(String(lines[i].dropFirst(2))))</li>"; i += 1
            }
            out += "</ul>"; continue
        }

        if isOL(line) {
            out += "<ol>"
            while i < lines.count && isOL(lines[i]) {
                let text = lines[i].replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
                out += "<li>\(inline(text))</li>"; i += 1
            }
            out += "</ol>"; continue
        }

        if i + 1 < lines.count && line.contains("|") && isTableSeparator(lines[i + 1]) {
            var rows = [line]
            i += 2
            while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(lines[i]); i += 1
            }
            out += renderTable(rows); continue
        }

        if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }

        var para: [String] = []
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix("~~~") || l.hasPrefix(">") { break }
            if isUL(l) || isOL(l) { break }
            let s2 = l.filter { !$0.isWhitespace }
            if (s2 == "---" || s2 == "***" || s2 == "___") && s2.count >= 3 { break }
            para.append(l); i += 1
        }
        if !para.isEmpty {
            out += "<p>\(inline(para.joined(separator: "\n")))</p>"
        }
    }
    return out
}

private func isUL(_ l: String) -> Bool { l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") }
private func isOL(_ l: String) -> Bool { l.range(of: "^\\d+\\.\\s", options: .regularExpression) != nil }
private func isTableSeparator(_ l: String) -> Bool {
    l.range(of: "^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?\\s*$", options: .regularExpression) != nil
}

private func renderTable(_ rows: [String]) -> String {
    func cells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    guard !rows.isEmpty else { return "" }
    var html = "<table><thead><tr>"
    html += cells(rows[0]).map { "<th>\(inline($0))</th>" }.joined()
    html += "</tr></thead>"
    if rows.count > 1 {
        html += "<tbody>"
        for row in rows.dropFirst() {
            html += "<tr>" + cells(row).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }
        html += "</tbody>"
    }
    return html + "</table>"
}

// MARK: - Inline parser

private func inline(_ text: String) -> String {
    var s = htmlEscape(text)
    var codes: [String] = []

    if let re = try? NSRegularExpression(pattern: "`(.+?)`") {
        var out = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let full = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) {
                out += s[last..<full.lowerBound]
                out += "\u{E000}\(codes.count)\u{E001}"
                codes.append("<code>\(s[inner])</code>")
                last = full.upperBound
            }
        }
        out += s[last...]; s = out
    }

    s = s.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*",       with: "<strong>$1</strong>",          options: .regularExpression)
    s = s.replacingOccurrences(of: "\\*([^*\\n]+?)\\*",       with: "<em>$1</em>",                  options: .regularExpression)
    s = s.replacingOccurrences(of: "~~(.+?)~~",               with: "<del>$1</del>",                options: .regularExpression)
    s = s.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "<img alt=\"$1\" src=\"$2\" style=\"max-width:100%\">", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)",  with: "<a href=\"$2\">$1</a>",                               options: .regularExpression)
    s = s.replacingOccurrences(of: "\n", with: "<br>")

    for (idx, code) in codes.enumerated() {
        s = s.replacingOccurrences(of: "\u{E000}\(idx)\u{E001}", with: code)
    }
    return s
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}
