import CoreServices
import Foundation

/// Calls `onChange` on the main actor when something in a directory changes, the AWS SSO cache
/// directory or gcloud's or the Azure CLI's config directory, so a login in a terminal is seen when
/// it happens rather than at the next tick. The AWS CLI rewrites a session's file in place, gcloud
/// its `credentials.db` and the Azure CLI its `azureProfile.json`, which a File System Events
/// stream reports. The directory may not exist yet,
/// or be removed: the stream also watches its path and starts again when the directory appears or
/// goes, since a stream sees nothing inside a directory created after it started.
@MainActor
public final class AWSCacheWatcher {
    /// How long File System Events gathers changes before reporting them, as one call.
    private static let latency: CFTimeInterval = 1

    private let directory: URL
    private let fileNames: Set<String>?
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    /// With `fileNames`, only a change to one of those files directly in `directory` calls
    /// `onChange`, besides the directory itself appearing or going and a batch File System Events
    /// couldn't itemize; with none, any change in it does.
    public init(directory: URL, fileNames: Set<String>? = nil, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.fileNames = fileNames
        self.onChange = onChange
        start()
    }

    isolated deinit {
        stop()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var flags = kFSEventStreamCreateFlagWatchRoot
        if fileNames != nil { flags |= kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes }
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency, FSEventStreamCreateFlags(flags))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether the event at `path` with `flags` concerns a watched file. Paths are matched by their
    /// last two components, since File System Events reports the resolved path (`/private/var/…`
    /// for `/var/…`), and the directory's own name or, through a symlink, its target's.
    private func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
        guard let fileNames else { return true }
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
        if flags & rescan != 0 { return true }
        let names = Set([directory.lastPathComponent, directory.resolvingSymlinksInPath().lastPathComponent])
        let suffixes = names.flatMap { name in fileNames.map { "/\(name)/\($0)" } }
        return suffixes.contains(where: path.hasSuffix)
    }

    /// A stream reset from inside its own callback can fail, so a restart waits for the callback
    /// to return.
    private func handle(rootChanged: Bool, events: [(path: String, flags: FSEventStreamEventFlags)]) {
        if rootChanged {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.start()
            }
        }
        if rootChanged || events.contains(where: { isRelevant(path: $0.path, flags: $0.flags) }) {
            onChange()
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<AWSCacheWatcher>.fromOpaque(info).takeUnretainedValue()
        let rootChanged = (0..<count).contains {
            flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }
        // Paths are a CFArray of CFStrings only with `kFSEventStreamCreateFlagUseCFTypes`, which only
        // a filtered watch sets; an unfiltered one never reads them.
        let names: [String] = watcher.fileNames == nil
            ? [] : (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? [])
        let events = (0..<count).map { (path: $0 < names.count ? names[$0] : "", flags: flags[$0]) }
        MainActor.assumeIsolated { watcher.handle(rootChanged: rootChanged, events: events) }
    }
}
