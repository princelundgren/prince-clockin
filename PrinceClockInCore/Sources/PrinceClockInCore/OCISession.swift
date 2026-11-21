import Foundation

/// A session profile of the OCI CLI's config: one with a `security_token_file`, as
/// `oci session authenticate` writes it. The app reads only its name, `region` and
/// `security_token_file`, never the token or a key.
public struct OCISessionProfile: Equatable, Sendable {
    public let name: String
    /// The profile's own `region`, else `[DEFAULT]`'s; `nil` when neither is set or it is empty.
    public let region: String?
    /// `security_token_file` with a leading `~` expanded: always an absolute path.
    public let securityTokenFile: URL

    public init(name: String, region: String?, securityTokenFile: URL) {
        self.name = name
        self.region = region
        self.securityTokenFile = securityTokenFile
    }

    /// The profile's session folder, which holds the token and the key pair.
    public var sessionDirectory: URL { securityTokenFile.deletingLastPathComponent() }

    /// The folder `oci session authenticate --token-location` names, which it writes the profile's
    /// session folder into.
    public var tokenLocation: URL { sessionDirectory.deletingLastPathComponent() }

    /// The session's public key, which `oci session authenticate` writes anew at each login and
    /// `oci session refresh` never touches. It is no secret, and the app only reads its date.
    public var publicKeyFile: URL {
        sessionDirectory.appending(path: "oci_api_key_public.pem", directoryHint: .notDirectory)
    }
}

/// The session profiles of the OCI config `text`, in file order, a leading `~` in a path expanded
/// to `home`.
///
/// The OCI CLI reads its config with Python's `configparser`, so keys match ignoring case and a
/// section that repeats adds to the first. `[DEFAULT]` is a profile of its own, and a profile
/// without a `region` takes `[DEFAULT]`'s. `security_token_file` counts only in the profile's own
/// section: `oci session authenticate` always writes one there, and one inherited from
/// `[DEFAULT]` names another profile's session. A `security_token_file` that isn't absolute once
/// `~` is expanded is left out, since the CLI would resolve it against its working directory, as
/// is a name `oci session authenticate` refuses (only `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`, `@`,
/// and not `.` or `..`).
public func discoverOCISessionProfiles(configText: String?, home: String) -> [OCISessionProfile] {
    guard let configText else { return [] }
    var order: [String] = []
    var sections: [String: [String: String]] = [:]
    for section in parseINI(configText) {
        if sections[section.name] == nil { order.append(section.name) }
        for (key, value) in section.values { sections[section.name, default: [:]][key.lowercased()] = value }
    }
    let defaults = sections["DEFAULT"] ?? [:]
    return order.compactMap { name in
        let values = sections[name] ?? [:]
        guard isOCIProfileName(name), let tokenPath = values["security_token_file"],
              let tokenFile = absolutePath(tokenPath, home: home)
        else { return nil }
        let region = (values["region"] ?? defaults["region"]).flatMap { $0.isEmpty ? nil : $0 }
        return OCISessionProfile(name: name, region: region, securityTokenFile: tokenFile)
    }
}

private func isOCIProfileName(_ name: String) -> Bool {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-@")
    return !name.isEmpty && name != "." && name != ".." && name.allSatisfy(allowed.contains)
}

private func absolutePath(_ path: String, home: String) -> URL? {
    let expanded = if path == "~" {
        home
    } else if path.hasPrefix("~/") {
        home + path.dropFirst()
    } else {
        path
    }
    return expanded.hasPrefix("/") ? URL(filePath: expanded, directoryHint: .notDirectory) : nil
}

/// A session's public key file, as read and as stored per login.
public enum OCIKeyFileState: Codable, Hashable, Sendable {
    case missing
    /// `modified` is whole seconds.
    case present(modified: Date)

    /// The same state with its date rounded down to whole seconds.
    var wholeSeconds: OCIKeyFileState {
        if case .present(let modified) = self { .present(modified: modified.wholeSeconds) } else { .missing }
    }
}

/// What the app read of the OCI config: the file, its session profiles, and the date of each one's
/// public key file.
public struct OCIConfig: Equatable, Sendable {
    public let file: URL
    public let profiles: [OCISessionProfile]
    /// By profile name. A profile whose key file exists but couldn't be read has none.
    public let publicKeys: [String: OCIKeyFileState]

    public init(file: URL, profiles: [OCISessionProfile], publicKeys: [String: OCIKeyFileState]) {
        self.file = file
        self.profiles = profiles
        self.publicKeys = publicKeys.mapValues(\.wholeSeconds)
    }

    public func profile(named name: String) -> OCISessionProfile? {
        profiles.first { $0.name == name }
    }

    /// The public key file of profile `name` now: missing when the config no longer has it as a
    /// session profile, as after `oci session terminate`; `nil` when its file couldn't be read.
    public func publicKeyState(profile name: String) -> OCIKeyFileState? {
        profile(named: name) == nil ? .missing : publicKeys[name]
    }
}

/// An OCI config that exists but couldn't be read as text. It names only the file.
public struct OCIConfigError: Error, Equatable, LocalizedError {
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    public var errorDescription: String? { "Could not read the OCI CLI's config \(fileName)." }
}

/// Reads the OCI config at `file` and the date of each session profile's public key file, which
/// is never opened. A missing config has no profiles.
public func readOCIConfig(at file: URL, home: String) throws(OCIConfigError) -> OCIConfig {
    let manager = FileManager.default
    guard manager.fileExists(atPath: file.path) else { return OCIConfig(file: file, profiles: [], publicKeys: [:]) }
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        throw OCIConfigError(fileName: file.lastPathComponent)
    }
    let profiles = discoverOCISessionProfiles(configText: text, home: home)
    var publicKeys: [String: OCIKeyFileState] = [:]
    for profile in profiles {
        let path = profile.publicKeyFile.path
        if !manager.fileExists(atPath: path) {
            publicKeys[profile.name] = .missing
        } else if let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            publicKeys[profile.name] = .present(modified: modified)
        }
    }
    return OCIConfig(file: file, profiles: profiles, publicKeys: publicKeys)
}

/// The OCI config's file in the folder a watch of it covers: every `oci session authenticate` and
/// `oci session terminate` rewrites the config after changing the key files, and
/// `oci session refresh` writes only the token, so a watch of the config alone sees every login and
/// logout.
public func ociConfigFileNames(configFile: URL) -> Set<String> {
    [configFile.lastPathComponent]
}

/// Reads the OCI CLI's config.
public protocol OCIConfigReading: Sendable {
    /// The config now; `nil` when the file exists but can't be read.
    func read() -> OCIConfig?
}

/// Reads the config at `file`, normally `~/.oci/config`, with a leading `~` in a path expanded to
/// `home`.
public struct OCIConfigFileReader: OCIConfigReading {
    public let file: URL
    public let home: String

    public init(file: URL, home: String) {
        self.file = file
        self.home = home
    }

    public func read() -> OCIConfig? {
        try? readOCIConfig(at: file, home: home)
    }
}

/// What a change from `previous`, `nil` when never seen, to `current` means.
/// `oci session authenticate` writes a new key pair at each login, so a newer public key is a
/// login, at the file's date; `oci session refresh` writes only the token, so a refresh is no
/// change. A key gone, or its profile gone from the config, is a logout (`oci session terminate`);
/// a first sight is a baseline.
public func observeOCIPublicKey(previous: OCIKeyFileState?, current: OCIKeyFileState) -> GcloudObservation {
    switch (previous, current) {
    case (nil, _), (.missing, .missing):
        .noChange
    case (.present, .missing):
        .loggedOut
    case (.missing, .present(let modified)):
        .newLogin(at: modified)
    case (.present(let old), .present(let new)):
        new > old ? .newLogin(at: new) : .noChange
    }
}

/// Why an OCI session profile's login can't run.
public enum OCILoginRefusal: Error, Equatable, Sendable {
    /// The config exists but couldn't be read.
    case configUnreadable
    /// The config no longer has the profile as a session profile.
    case notASessionProfile
    /// Neither the profile nor `[DEFAULT]` has a region, which `oci session authenticate` would
    /// ask for in a terminal the app doesn't have.
    case noRegion
}

/// `oci session authenticate` for profile `name` of `config`, writing where the config already
/// points: the config the app read, and the folder that holds the profile's session folder. Each
/// value is joined to its flag, so one starting with `-` can't be read as a flag of its own.
public func ociLoginCommand(profile name: String, config: OCIConfig?) -> Result<LoginCommand, OCILoginRefusal> {
    guard let config else { return .failure(.configUnreadable) }
    guard let profile = config.profile(named: name) else { return .failure(.notASessionProfile) }
    guard let region = profile.region else { return .failure(.noRegion) }
    return .success(LoginCommand(executable: "oci", arguments: [
        "session", "authenticate", "--profile-name=\(name)", "--region=\(region)",
        "--config-location=\(filePath(config.file))", "--token-location=\(filePath(profile.tokenLocation))",
    ]))
}

/// `url`'s path without the trailing `/` a folder's URL carries.
private func filePath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
}
