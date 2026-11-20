import CoreServices
import Foundation

/// Calls `onChange` on the main actor when anything in the AWS SSO cache directory changes, so a
/// login in a terminal is seen when it happens rather than at the next tick. The AWS CLI rewrites
/// a session's file in place, which a directory-level File System Events stream reports. The
/// directory may not exist yet, or be removed: the stream also watches its path and starts again
/// when the directory appears or goes, since a stream sees nothing inside a directory created
/// after it started.
@MainActor
public final class AWSCacheWatcher {
    /// How long File System Events gathers changes before reporting them, as one call.
    private static let latency: CFTimeInterval = 1

    private let directory: URL
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    public init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
        start()
    }

    isolated deinit {
        stop()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency, flags)
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

    /// A stream reset from inside its own callback can fail, so a restart waits for the callback
    /// to return.
    private func handle(rootChanged: Bool) {
        if rootChanged {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
                self?.start()
            }
        }
        onChange()
    }

    private static let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<AWSCacheWatcher>.fromOpaque(info).takeUnretainedValue()
        let rootChanged = (0..<count).contains {
            flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }
        MainActor.assumeIsolated { watcher.handle(rootChanged: rootChanged) }
    }
}
