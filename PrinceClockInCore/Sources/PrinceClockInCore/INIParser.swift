import Foundation

/// One `[name]` section of an INI file with its `key = value` pairs.
public struct INISection: Equatable, Sendable {
    /// The text between the `[` and the line's last `]`, trimmed, such as `sso-session dev`.
    public let name: String
    /// The section's keys and values, trimmed. A repeated key keeps its last value.
    public let values: [String: String]

    public init(name: String, values: [String: String]) {
        self.name = name
        self.values = values
    }
}

/// Parses the INI dialect of the AWS CLI and Databricks CLI config files, in file order.
///
/// Comment lines (`#`, `;`), blank lines and lines that are neither a section header nor
/// `key = value` are skipped, as are pairs before the first header and after a malformed header.
/// A header ends at the line's last `]` and any text after it, such as a comment, is ignored, as in
/// both CLIs' readers. A line starting with `[` and holding no `]` is a malformed header.
/// As in Python's `configparser`, a line indented deeper than the key before it continues that
/// key's value (AWS's nested `s3 =` blocks) and is skipped, so nested keys never leak into the
/// section. A leading UTF-8 BOM is ignored.
///
/// - Parameter stripInlineComments: when true, a `#` or `;` after a space or tab ends a value, as in
///   the Databricks CLI's reader. The AWS CLI's reader (`RawConfigParser`) keeps it in the value.
public func parseINI(_ text: String, stripInlineComments: Bool = false) -> [INISection] {
    var sections: [INISection] = []
    var name: String?
    var values: [String: String] = [:]
    var keyIndent: Int?

    func closeSection() {
        if let name { sections.append(INISection(name: name, values: values)) }
        name = nil
        values = [:]
        keyIndent = nil
    }

    let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

        if line.hasPrefix("[") {
            closeSection()
            if let close = line.lastIndex(of: "]") {
                name = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            }
            continue
        }

        let indent = rawLine.prefix(while: \.isWhitespace).count
        if let keyIndent, indent > keyIndent { continue }

        guard name != nil, let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        var value = String(line[line.index(after: equals)...])
        if stripInlineComments { value = withoutInlineComment(value) }
        values[key] = value.trimmingCharacters(in: .whitespaces)
        keyIndent = indent
    }
    closeSection()
    return sections
}

private func withoutInlineComment(_ value: String) -> String {
    var previous: Character?
    for index in value.indices {
        let character = value[index]
        if character == "#" || character == ";", previous == " " || previous == "\t" {
            return String(value[..<index])
        }
        previous = character
    }
    return value
}
