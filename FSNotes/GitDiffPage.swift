import Foundation

/// A self-contained, script-free diff document. Repository content is always escaped.
enum GitDiffPage {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func message(_ title: String, detail: String, symbol: String = "◇", dark: Bool) -> String {
        page(body: "<div class='empty'><div class='symbol'>\(escape(symbol))</div><h2>\(escape(title))</h2><p>\(escape(detail))</p></div>", dark: dark)
    }

    static func render(_ diff: GitChangeDiff, change: GitChange, sideBySide: Bool, dark: Bool) -> String {
        if diff.binary {
            return message(NSLocalizedString("Binary file changed", comment: "Git changes"),
                detail: NSLocalizedString("Text comparison is unavailable for this file. You can still stage and commit it.", comment: "Git changes"), symbol: "▧", dark: dark)
        }
        if diff.lines.isEmpty {
            let detail = change.kind == .renamed ? change.oldPath + " → " + change.path
                : NSLocalizedString("No text differences. The file status or permissions may have changed.", comment: "Git changes")
            return message(NSLocalizedString("No text differences", comment: "Git changes"), detail: detail, dark: dark)
        }
        let oldLabel = change.area == .staged ? "HEAD" : NSLocalizedString("Index", comment: "Git changes")
        let newLabel = change.area == .staged ? NSLocalizedString("Index", comment: "Git changes") : NSLocalizedString("Working tree", comment: "Git changes")
        let rename = change.kind == .renamed ? "<div class='rename'>\(escape(change.oldPath)) → \(escape(change.path))</div>" : ""
        var body = rename + "<div class='legend'><span>\(escape(oldLabel)) → \(escape(newLabel))</span><span><b class='plus'>+\(diff.additions)</b> <b class='minus'>−\(diff.deletions)</b></span></div>"
        if sideBySide {
            body += "<table class='split'><colgroup><col class='number'><col><col class='number'><col></colgroup><thead><tr><th colspan='2'>\(escape(oldLabel))</th><th colspan='2'>\(escape(newLabel))</th></tr></thead><tbody>"
            var removed = [GitChangeDiff.Line](), added = [GitChangeDiff.Line]()
            func flush() {
                for index in 0..<max(removed.count, added.count) {
                    let old = removed.indices.contains(index) ? removed[index] : nil
                    let new = added.indices.contains(index) ? added[index] : nil
                    body += "<tr>" + cells(old, old: true) + cells(new, old: false) + "</tr>"
                }
                removed.removeAll(); added.removeAll()
            }
            for line in diff.lines {
                switch line.kind {
                case .removed: removed.append(line)
                case .added: added.append(line)
                case .context:
                    flush()
                    body += "<tr>" + cells(line, old: true) + cells(line, old: false) + "</tr>"
                case .hunk, .notice:
                    flush()
                    body += "<tr class='\(line.kind == .hunk ? "hunk" : "notice")'><td colspan='4'>\(escape(line.text))</td></tr>"
                }
            }
            flush()
        } else {
            body += "<table class='unified'><colgroup><col class='number'><col class='number'><col class='sign'><col></colgroup><tbody>"
            for line in diff.lines {
                if line.kind == .hunk || line.kind == .notice {
                    body += "<tr class='\(line.kind == .hunk ? "hunk" : "notice")'><td colspan='4'>\(escape(line.text))</td></tr>"
                } else {
                    let style = line.kind == .added ? "add" : line.kind == .removed ? "remove" : "context"
                    let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                    body += "<tr class='\(style)'><td class='num'>\(line.oldNumber.map(String.init) ?? "")</td><td class='num'>\(line.newNumber.map(String.init) ?? "")</td><td class='prefix'>\(sign)</td><td class='code'>\(escape(line.text))</td></tr>"
                }
            }
        }
        body += "</tbody></table>"
        if diff.truncated {
            body += "<p class='limit'>\(escape(NSLocalizedString("Preview limited to 8,000 lines. Open the file to review the remaining changes.", comment: "Git changes")))</p>"
        }
        return page(body: body, dark: dark)
    }

    private static func cells(_ line: GitChangeDiff.Line?, old: Bool) -> String {
        guard let line = line else { return "<td class='num blank'></td><td class='code blank'></td>" }
        let style = line.kind == .added ? "add" : line.kind == .removed ? "remove" : "context"
        let number = old ? line.oldNumber : line.newNumber
        return "<td class='num \(style)'>\(number.map(String.init) ?? "")</td><td class='code \(style)'>\(escape(line.text))</td>"
    }

    private static func page(body: String, dark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); --bg: \(dark ? "#1e2024" : "#ffffff"); --fg: \(dark ? "#dddfe4" : "#2d323b");
          --muted: \(dark ? "#9298a4" : "#7d8490"); --border: \(dark ? "#333741" : "#e7e9ed"); --head: \(dark ? "#252830" : "#f7f8fa");
          --add: \(dark ? "#213b30" : "#eaf7ee"); --remove: \(dark ? "#46282d" : "#fff0f0"); --hunk: \(dark ? "#243245" : "#eff5fd"); }
        * { box-sizing: border-box; } body { margin: 0; background: var(--bg); color: var(--fg); font: 12px -apple-system, sans-serif; }
        .legend { display: flex; justify-content: space-between; padding: 13px 22px; border-bottom: 1px solid var(--border); color: var(--muted); }
        .plus { color: \(dark ? "#83d4a0" : "#247d45"); margin-right: 10px; } .minus { color: \(dark ? "#f4a0a3" : "#bb454a"); }
        table { border-collapse: collapse; width: 100%; table-layout: fixed; font: 12px/1.7 ui-monospace, SFMono-Regular, Menlo, monospace; }
        col.number { width: 47px; } col.sign { width: 24px; }
        th { position: sticky; top: 0; background: var(--head); padding: 9px 14px; text-align: left; font: 11px -apple-system, sans-serif; color: var(--muted); border-bottom: 1px solid var(--border); }
        .num { text-align: right; padding: 0 10px 0 3px; color: var(--muted); user-select: none; vertical-align: top; }
        .code { white-space: pre-wrap; overflow-wrap: anywhere; tab-size: 4; padding: 0 12px; vertical-align: top; }
        .split td:nth-child(2), th:first-child { border-right: 1px solid var(--border); }
        .add { background: var(--add); } .remove { background: var(--remove); } .blank { background: var(--head); }
        .hunk td { padding: 8px 20px; color: var(--muted); background: var(--hunk); }
        .notice td { padding: 3px 20px; color: var(--muted); font-style: italic; }
        .prefix { user-select: none; text-align: center; vertical-align: top; }
        .rename, .limit { padding: 14px 22px; color: var(--muted); }
        .empty { display: flex; min-height: 75vh; align-items: center; justify-content: center; flex-direction: column; padding: 40px; text-align: center; }
        .empty .symbol { color: var(--muted); font-size: 42px; font-weight: 200; margin-bottom: 12px; }
        .empty h2 { font-size: 17px; font-weight: 500; margin: 10px 0; } .empty p { color: var(--muted); font-size: 13px; line-height: 1.6; max-width: 420px; }
        </style></head><body>\(body)</body></html>
        """
    }
}
