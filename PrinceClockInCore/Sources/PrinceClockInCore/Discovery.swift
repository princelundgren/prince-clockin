import Foundation

/// The names of the `[sso-session <name>]` sections of an AWS CLI config, in file order.
///
/// As in botocore, a section whose name starts with `sso-session` is split into words the way
/// Python's `shlex.split` does, and kept only when that gives exactly two words; the second is the
/// session name, so `[sso-session "my team"]` names `my team`. An empty name is skipped. A name that
/// repeats is listed once. A missing file (`nil`) or one with no such sections gives `[]`.
public func discoverAWSSessions(configText: String?) -> [String] {
    guard let configText else { return [] }
    var seen: Set<String> = []
    return parseINI(configText).compactMap { section in
        guard section.name.hasPrefix("sso-session"), let words = shellWords(section.name), words.count == 2
        else { return nil }
        let sessionName = words[1]
        return sessionName.isEmpty || !seen.insert(sessionName).inserted ? nil : sessionName
    }
}

/// `text` split into words as Python's `shlex.split` does in its default POSIX mode: words are
/// separated by spaces, tabs, carriage returns and line feeds; single quotes keep everything
/// literally; a backslash escapes any character outside quotes and only `"` or `\` inside double
/// quotes. `nil` for an unclosed quote or a trailing backslash, which `shlex.split` rejects.
private func shellWords(_ text: String) -> [String]? {
    enum State { case between, word, singleQuoted, doubleQuoted }
    let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]
    var words: [String] = []
    var word = String.UnicodeScalarView()
    var state = State.between
    var scalars = text.unicodeScalars.makeIterator()

    while let scalar = scalars.next() {
        switch state {
        case .between, .word:
            if whitespace.contains(scalar) {
                if state == .word { words.append(String(word)) }
                word = String.UnicodeScalarView()
                state = .between
            } else if scalar == "\\" {
                guard let escaped = scalars.next() else { return nil }
                word.append(escaped)
                state = .word
            } else if scalar == "'" {
                state = .singleQuoted
            } else if scalar == "\"" {
                state = .doubleQuoted
            } else {
                word.append(scalar)
                state = .word
            }
        case .singleQuoted:
            if scalar == "'" { state = .word } else { word.append(scalar) }
        case .doubleQuoted:
            if scalar == "\"" {
                state = .word
            } else if scalar == "\\" {
                guard let escaped = scalars.next() else { return nil }
                if escaped != "\"" && escaped != "\\" { word.append(scalar) }
                word.append(escaped)
            } else {
                word.append(scalar)
            }
        }
    }
    switch state {
    case .between: return words
    case .word: return words + [String(word)]
    case .singleQuoted, .doubleQuoted: return nil
    }
}

/// A Databricks CLI profile the user can log in to.
public struct DatabricksProfile: Equatable, Sendable {
    public let name: String
    /// True for a profile for the account rather than a workspace: one with a `host` and an
    /// `account_id` but no `workspace_id`, or the `workspace_id` `none`, as the Databricks CLI tells
    /// them apart. A workspace profile can hold an `account_id` too. The profile is still offered.
    public let accountLevel: Bool

    public init(name: String, accountLevel: Bool) {
        self.name = name
        self.accountLevel = accountLevel
    }
}

/// The profiles of a `.databrickscfg` whose `auth_type` is `databricks-cli`, in file order.
/// A name that repeats is listed once. A missing file (`nil`) or one with no such profiles gives `[]`.
public func discoverDatabricksProfiles(configText: String?) -> [DatabricksProfile] {
    guard let configText else { return [] }
    var seen: Set<String> = []
    return parseINI(configText, stripInlineComments: true).compactMap { section in
        guard section.values["auth_type"] == "databricks-cli", seen.insert(section.name).inserted else {
            return nil
        }
        return DatabricksProfile(name: section.name, accountLevel: isAccountProfile(section.values))
    }
}

private func isAccountProfile(_ values: [String: String]) -> Bool {
    let workspaceID = values["workspace_id"] ?? ""
    return !(values["host"] ?? "").isEmpty && !(values["account_id"] ?? "").isEmpty
        && (workspaceID.isEmpty || workspaceID == "none")
}

/// Where the AWS CLI and the Databricks CLI keep their config files.
public struct ConfigPaths: Equatable, Sendable {
    public var awsConfig: URL
    public var databricksConfig: URL

    public init(awsConfig: URL, databricksConfig: URL) {
        self.awsConfig = awsConfig
        self.databricksConfig = databricksConfig
    }

    /// `AWS_CONFIG_FILE` and `DATABRICKS_CONFIG_FILE` when set and non-empty, else `~/.aws/config` and
    /// `~/.databrickscfg`. A leading `~` or `~/` expands to `HOME` from `environment`, or the user's
    /// home directory when `HOME` is absent. `~user` and environment variables in a path are not expanded.
    public static func standard(environment: [String: String]) -> ConfigPaths {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()

        func path(override key: String, default defaultPath: String) -> URL {
            let value = environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
            if value == "~" { return URL(filePath: home) }
            if value.hasPrefix("~/") { return URL(filePath: home + value.dropFirst()) }
            return URL(filePath: value)
        }

        return ConfigPaths(
            awsConfig: path(override: "AWS_CONFIG_FILE", default: "~/.aws/config"),
            databricksConfig: path(override: "DATABRICKS_CONFIG_FILE", default: "~/.databrickscfg"))
    }
}
