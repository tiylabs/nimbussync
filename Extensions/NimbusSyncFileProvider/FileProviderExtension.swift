import FileProvider
import CloudreveFileProviderKit

// The principal class must carry the replicated conformance itself. The base
// class supplies the callbacks and durable state, so no forwarding wrapper is
// needed at the File Provider boundary.
@objc class FileProviderExtension: NimbusSyncFileProviderExtension, NSFileProviderReplicatedExtension, @unchecked Sendable {}
