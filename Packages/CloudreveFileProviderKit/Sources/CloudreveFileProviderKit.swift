import Foundation
import FileProvider
import UniformTypeIdentifiers
import ImageIO
import AppKit
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator

public final class CloudreveFileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    public let model: RemoteItem
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let documentSize: NSNumber?
    public let childItemCount: NSNumber?
    public let creationDate: Date?
    public let contentModificationDate: Date?
    public let capabilities: NSFileProviderItemCapabilities
    public let itemVersion: NSFileProviderItemVersion
    public let userInfo: [AnyHashable: Any]?
    public let isUploaded: Bool
    public let isUploading: Bool
    public let uploadingError: Error?
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let downloadingError: Error?
    public let isMostRecentVersionDownloaded: Bool
    public let isShared: Bool
    public let isSharedByCurrentUser: Bool
    public let decorations: [NSFileProviderItemDecorationIdentifier]?

    public init(model: RemoteItem) {
        self.model = model
        self.itemIdentifier = NSFileProviderItemIdentifier(model.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? model.itemIdentifier : model.itemIdentifier)
        self.parentItemIdentifier = NSFileProviderItemIdentifier(model.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
		self.filename = model.name.isEmpty ? "NimbusSync" : model.name
        self.contentType = UTType(model.contentType) ?? (model.kind == .folder ? .folder : .data)
        self.documentSize = model.kind == .folder ? nil : NSNumber(value: model.size)
        self.childItemCount = model.kind == .folder ? nil : nil
        self.creationDate = nil
        self.contentModificationDate = nil
        var itemCapabilities: NSFileProviderItemCapabilities = []
        if model.canRead { itemCapabilities.insert(.allowsReading) }
        if model.canWrite { itemCapabilities.insert(.allowsWriting); itemCapabilities.insert(.allowsRenaming) }
        if model.canAddChildren { itemCapabilities.insert(.allowsAddingSubItems) }
        if model.canWrite { itemCapabilities.insert(.allowsReparenting) }
        if model.canDelete && model.trashed { itemCapabilities.insert(.allowsDeleting) }
        if model.canTrash && !model.trashed { itemCapabilities.insert(.allowsTrashing) }
        if model.canRead && !model.tombstone { itemCapabilities.insert(.allowsEvicting) }
        self.capabilities = itemCapabilities
        self.itemVersion = NSFileProviderItemVersion(contentVersion: model.version.content, metadataVersion: model.version.metadata)
        self.userInfo = ["authenticated": model.canRead, "trashed": model.trashed, "tombstone": model.tombstone]
        self.isUploaded = !model.tombstone
        self.isUploading = false
        self.uploadingError = nil
        self.isDownloaded = false
        self.isDownloading = false
        self.downloadingError = nil
        self.isMostRecentVersionDownloaded = false
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.decorations = nil
    }
}

public protocol FileProviderBackend: AnyObject, Sendable {
    func item(identifier: String) throws -> RemoteItem?
    func children(parentIdentifier: String) throws -> [RemoteItem]
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage
    func content(identifier: String, expectedVersion: Data?) throws -> Data
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem
    func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem
    func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem
    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem
    func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws
}

public extension FileProviderBackend {
    func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage {
        let all = try children(parentIdentifier: parentIdentifier)
        let boundedLimit = max(1, min(limit, 500))
        let slice = Array(all.dropFirst(max(0, offset)).prefix(boundedLimit))
        let next = offset + slice.count < all.count ? offset + slice.count : nil
        return DirectoryPage(items: slice, nextOffset: next, generation: 1, complete: next == nil)
    }

    /// Production backends override this with bounded streaming. The default
    /// implementation keeps test doubles small while preserving the callback
    /// contract used by the extension.
    func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem {
        let data = try content(identifier: identifier, expectedVersion: expectedVersion)
        guard let item = try item(identifier: identifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = 0
        let blockSize = 1024 * 1024
        while offset < data.count {
            let end = min(data.count, offset + blockSize)
            try handle.write(contentsOf: data[offset..<end])
            offset = end
        }
        return item
    }

    func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
}

public final class StoreFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func item(identifier: String) throws -> RemoteItem? { try store.item(identifier: identifier) }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { try store.listChildren(parentIdentifier: parentIdentifier) }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { throw CoreFailure(code: .network, retryable: true) }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { throw CoreFailure(code: .network, retryable: true) }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
}

public final class MemoryFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    private var values: [String: RemoteItem]
    private var contents: [String: Data]
    private let lock = NSLock()
    public init(items: [RemoteItem] = [], contents: [String: Data] = [:]) { self.values = Dictionary(uniqueKeysWithValues: items.map { ($0.itemIdentifier, $0) }); self.contents = contents }
    public func item(identifier: String) throws -> RemoteItem? { lock.lock(); defer { lock.unlock() }; return values[identifier] }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { lock.lock(); defer { lock.unlock() }; return values.values.filter { $0.parentIdentifier == parentIdentifier && !$0.tombstone }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { let all = try children(parentIdentifier: parentIdentifier); let boundedLimit = max(1, min(limit, 500)); let slice = Array(all.dropFirst(max(0, offset)).prefix(boundedLimit)); let next = offset + slice.count < all.count ? offset + slice.count : nil; return DirectoryPage(items: slice, nextOffset: next, generation: 1, complete: next == nil) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let value = values[identifier], let data = contents[identifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, expectedVersion != value.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; return data }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { let data = try content(identifier: identifier, expectedVersion: expectedVersion); guard let item = try self.item(identifier: identifier) else { throw CoreFailure(code: .notFound, retryable: false) }; try data.write(to: destination, options: .atomic); return item }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; if let existing = values.values.first(where: { $0.parentIdentifier == template.parentIdentifier && $0.name == template.name }) { return existing }; var item = template; item.remoteID = item.remoteID ?? "remote-\(item.itemIdentifier)"; values[item.itemIdentifier] = item; contents[item.itemIdentifier] = content ?? Data(); return item }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; if changedFields.contains(.contents) { guard let content else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }; contents[item.itemIdentifier] = content; current.version = ItemVersion(content: VersionHasher.content(primaryEntity: "\(content.count)-\(replayKey)"), metadata: current.version.metadata); current.size = Int64(content.count) }; if changedFields.contains(.filename) { current.name = item.name }; if changedFields.contains(.parentItemIdentifier) { current.parentIdentifier = item.parentIdentifier }; values[item.itemIdentifier] = current; return current }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = true; current.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue; values[item.itemIdentifier] = current; return current }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = false; current.parentIdentifier = item.parentIdentifier; values[item.itemIdentifier] = current; return current }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { lock.lock(); defer { lock.unlock() }; guard let current = values[identifier] else { return }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; let descendants = values.values.filter { $0.parentIdentifier == identifier }; if !recursive && !descendants.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }; values.removeValue(forKey: identifier); contents.removeValue(forKey: identifier); if recursive { for child in descendants { values.removeValue(forKey: child.itemIdentifier); contents.removeValue(forKey: child.itemIdentifier) } } }
}

public final class CloudreveFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let parentIdentifier: String
    private let domainIdentifier: String
    private let store: SQLiteStateStore?
    private let backend: FileProviderBackend
    private var invalidated = false
    private var snapshot: [RemoteItem]?
    private let snapshotGeneration: UInt64 = 1

    public init(parentIdentifier: String, domainIdentifier: String, store: SQLiteStateStore?, backend: FileProviderBackend) { self.parentIdentifier = parentIdentifier; self.domainIdentifier = domainIdentifier; self.store = store; self.backend = backend }
    public func invalidate() { invalidated = true }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard !invalidated else { return }
        do {
            let rawPage = Data(page as NSData)
            let initialByDate = Data(NSFileProviderPage.initialPageSortedByDate as NSData)
            let initialByName = Data(NSFileProviderPage.initialPageSortedByName as NSData)
            let pageToken = rawPage == initialByDate || rawPage == initialByName ? nil : try PageToken.decode(rawPage)
            if let pageToken, (pageToken.domainIdentifier != domainIdentifier || pageToken.parentIdentifier != parentIdentifier || pageToken.snapshotGeneration != snapshotGeneration) {
                throw StoreBridgeError.schemaFenced
            }
            let offset = pageToken?.offset ?? 0
            let suggestedPageSize = observer.suggestedPageSize ?? 100
            let limit = max(1, min(suggestedPageSize > 0 ? suggestedPageSize : 100, 500))
            let pageResult = try backend.childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit)
            snapshot = pageResult.items
            observer.didEnumerate(pageResult.items.map(CloudreveFileProviderItem.init))
            if let nextOffset = pageResult.nextOffset {
                let next = try PageToken(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, snapshotGeneration: pageResult.generation, offset: nextOffset).encoded()
                observer.finishEnumerating(upTo: NSFileProviderPage(next))
            } else { observer.finishEnumerating(upTo: nil) }
        } catch let error as StoreBridgeError { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
        catch { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard !invalidated, let store else { return }
        do {
            let anchor = try SyncAnchor.decode(Data(syncAnchor as NSData))
            let batch = try store.enumerateChanges(domainIdentifier: domainIdentifier, scope: parentIdentifier, from: anchor)
            var updates: [NSFileProviderItem] = []
            var deletes: [NSFileProviderItemIdentifier] = []
            for change in batch.changes {
                if change.kind == "deleted" { deletes.append(NSFileProviderItemIdentifier(change.itemIdentifier)) } else if let item = try backend.item(identifier: change.itemIdentifier) { updates.append(CloudreveFileProviderItem(model: item)) }
            }
            if !updates.isEmpty { observer.didUpdate(updates) }
            if !deletes.isEmpty { observer.didDeleteItems(withIdentifiers: deletes) }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(try batch.nextAnchor.encoded()), moreComing: batch.moreComing)
        } catch { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let store else { completionHandler(nil); return }
        do { completionHandler(NSFileProviderSyncAnchor(try store.currentAnchor(domainIdentifier: domainIdentifier, scope: parentIdentifier).encoded())) } catch { completionHandler(nil) }
    }
}

private final class FetchCompletion: @unchecked Sendable {
    private let handler: (URL?, NSFileProviderItem?, Error?) -> Void
    init(_ handler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) { self.handler = handler }
    func call(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) { handler(url, item, error) }
}

open class CloudreveFileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderDomainState, NSFileProviderThumbnailing, NSFileProviderCustomAction {
    public let domain: NSFileProviderDomain
    private var store: SQLiteStateStore?
    private var backend: FileProviderBackend
    private let stateProjection: DomainStateProjection
    private var invalidated = false

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        if let databaseURL = try? AppGroupPaths.prepareDomain(domain.identifier.rawValue), let store = try? SQLiteStateStore(url: databaseURL) {
            self.store = store
            if let stored = try? store.domain(identifier: domain.identifier.rawValue), let origin = URL(string: stored.origin) {
                let credentialVault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let secretVault = KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current())
                self.backend = CloudreveRemoteBackend(origin: origin, rootURI: stored.rootURI, store: store, vault: credentialVault, credentialReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, providerName: stored.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: secretVault)
            } else {
                self.backend = StoreFileProviderBackend(store: store)
            }
        } else {
            self.store = nil
            self.backend = MemoryFileProviderBackend()
        }
        if let stateURL = AppGroupPaths.domainVersionURL(domain.identifier.rawValue) {
            self.stateProjection = DomainStateProjection.load(from: stateURL, authenticated: true)
        } else {
            self.stateProjection = DomainStateProjection(authenticated: true)
        }
        super.init()
    }

    public convenience init(domain: NSFileProviderDomain, store: SQLiteStateStore, backend: FileProviderBackend) {
        self.init(domain: domain)
        self.store = store
        self.backend = backend
    }

    public func invalidate() { invalidated = true }

    public var domainVersion: NSFileProviderDomainVersion { stateProjection.domainVersion }
    public var userInfo: [AnyHashable: Any] { stateProjection.userInfo }

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard !invalidated else { completionHandler(nil, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false))); return progress }
        if identifier == .rootContainer { completionHandler(rootItem(), nil); progress.completedUnitCount = 1; return progress }
        do { guard let item = try backend.item(identifier: identifier.rawValue) else { completionHandler(nil, FileProviderErrorMapper.map(CoreFailure(code: .notFound, retryable: false))); return progress }; completionHandler(CloudreveFileProviderItem(model: item), nil); progress.completedUnitCount = 1 } catch { completionHandler(nil, FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let cancellation = FetchCompletion(completionHandler)
        progress.cancellationHandler = { cancellation.call(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)) }
        do {
            let manager = NSFileProviderManager(for: domain)
            guard let directory = try manager?.temporaryDirectoryURL() else { throw CoreFailure(code: .network, retryable: true) }
			let url = directory.appendingPathComponent("nimbussync-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CoreFailure(code: .network, retryable: true) }
            let item = try backend.fetchContent(identifier: itemIdentifier.rawValue, expectedVersion: requestedVersion?.contentVersion, to: url)
            completionHandler(url, CloudreveFileProviderItem(model: item), nil)
            progress.completedUnitCount = 1
        } catch { completionHandler(nil, nil, FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let content = try url.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
            let model = try templateModel(itemTemplate)
            let item = try FileProviderMutationCoordinator(store: store, backend: backend).create(template: model, content: content, fields: fields, options: options)
            stateProjection.advance()
            persistDomainState()
            completionHandler(CloudreveFileProviderItem(model: item), [], false, nil); progress.completedUnitCount = 1
        } catch { completionHandler(nil, fields, false, FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            guard let model = try backend.item(identifier: item.itemIdentifier.rawValue) else { throw CoreFailure(code: .notFound, retryable: false) }
            let content = try newContents.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
            var requested = model
            if changedFields.contains(.filename) { requested.name = item.filename }
            if changedFields.contains(.parentItemIdentifier) { requested.parentIdentifier = item.parentItemIdentifier.rawValue }
            let updated = try FileProviderMutationCoordinator(store: store, backend: backend).modify(item: requested, baseVersion: version, fields: changedFields, contents: content, options: options)
            stateProjection.advance()
            persistDomainState()
            completionHandler(CloudreveFileProviderItem(model: updated), unsupportedFields(changedFields), false, nil); progress.completedUnitCount = 1
        } catch { completionHandler(nil, changedFields, false, FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do { try FileProviderMutationCoordinator(store: store, backend: backend).delete(itemIdentifier: identifier.rawValue, baseVersion: version, options: options); stateProjection.advance(); persistDomainState(); completionHandler(nil); progress.completedUnitCount = 1 } catch { completionHandler(FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let parent = containerItemIdentifier == .rootContainer ? NSFileProviderItemIdentifier.rootContainer.rawValue : containerItemIdentifier.rawValue
        return CloudreveFileProviderEnumerator(parentIdentifier: parent, domainIdentifier: domain.identifier.rawValue, store: store, backend: backend)
    }

    public func importDidFinish(completionHandler: @escaping () -> Void) { completionHandler() }
    public func materializedItemsDidChange(completionHandler: @escaping () -> Void) { completionHandler() }
    public func pendingItemsDidChange(completionHandler: @escaping () -> Void) { completionHandler() }

    public func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let completion = ErrorCompletion(completionHandler)
        progress.cancellationHandler = { completion.call(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)) }
        do {
            for identifier in itemIdentifiers {
                guard let item = try self.backend.item(identifier: identifier.rawValue), item.kind == .file else { perThumbnailCompletionHandler(identifier, nil, nil); progress.completedUnitCount += 1; continue }
                do {
                    let data = try self.backend.content(identifier: identifier.rawValue, expectedVersion: item.version.content)
                    let thumbnail = makeThumbnail(data: data, size: size)
                    perThumbnailCompletionHandler(identifier, thumbnail, nil)
                } catch { perThumbnailCompletionHandler(identifier, nil, nil) }
                progress.completedUnitCount += 1
            }
            completionHandler(nil)
        } catch { completionHandler(FileProviderErrorMapper.map(error)) }
        return progress
    }

    public func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
		guard actionIdentifier.rawValue == "ai.tiylabs.nimbussync.check-for-updates" else { completionHandler(FileProviderErrorMapper.map(CoreFailure(code: .unsupportedMetadata, retryable: false))); return progress }
        do {
            guard let store else { throw CoreFailure(code: .database, retryable: false) }
            let scope = itemIdentifiers.first?.rawValue ?? NSFileProviderItemIdentifier.rootContainer.rawValue
            try store.startReconcile(runID: UUID(), scope: scope, generation: 1, phase: "prepared", cursor: nil)
            try store.updateSyncState(reconcileStatus: "reconciling")
            progress.completedUnitCount = 1
            completionHandler(nil)
        } catch {
            completionHandler(FileProviderErrorMapper.map(error))
        }
        return progress
    }

    private func rootItem() -> CloudreveFileProviderItem {
        let root = RemoteItem(itemIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: domain.displayName, uri: "/", kind: .folder, contentType: UTType.folder.identifier, version: ItemVersion(content: Data("root".utf8), metadata: Data(domain.identifier.rawValue.utf8)), canRead: true, canWrite: false, canAddChildren: false, canTrash: false, canDelete: false)
        return CloudreveFileProviderItem(model: root)
    }

    private func templateModel(_ template: NSFileProviderItem) throws -> RemoteItem {
        guard let type = template.contentType else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
        let kind: RemoteItemKind = type.conforms(to: .symbolicLink) ? .symlink : (type.conforms(to: .folder) ? .folder : .file)
        let size = (template.documentSize as? NSNumber)?.int64Value ?? 0
        return RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: template.itemIdentifier.rawValue), parentIdentifier: template.parentItemIdentifier.rawValue, name: template.filename, uri: "/\(template.filename)", kind: kind, contentType: type.identifier, size: size, version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true, canAddChildren: kind == .folder, canTrash: true, canDelete: false)
    }

    private func unsupportedFields(_ fields: NSFileProviderItemFields) -> NSFileProviderItemFields {
        fields.subtracting([.contents, .filename, .parentItemIdentifier, .creationDate, .contentModificationDate])
    }

    private func persistDomainState() {
        guard let url = AppGroupPaths.domainVersionURL(domain.identifier.rawValue) else { return }
        try? stateProjection.persist(to: url)
    }
}

private final class ErrorCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) { handler(error) }
}

private func makeThumbnail(data: Data, size: CGSize) -> Data? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(16, Int(max(size.width, size.height))), kCGImageSourceCreateThumbnailWithTransform: true]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let destinationData = CFDataCreateMutable(nil, 0), let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return destinationData as Data
}

public enum FileProviderErrorMapper {
    public static func map(_ error: Error) -> NSError {
        if let error = error as? NSError, error.domain == NSFileProviderErrorDomain || error.domain == NSCocoaErrorDomain { return error }
        let code: Int
        let context: [String: Any]
        if let failure = error as? CoreFailure {
            switch failure.code {
            case .authentication: code = NSFileProviderError.notAuthenticated.rawValue
            case .network: code = NSFileProviderError.serverUnreachable.rawValue
            case .notFound: code = NSFileProviderError.noSuchItem.rawValue
            case .quotaExceeded: code = NSFileProviderError.insufficientQuota.rawValue
            case .versionConflict: code = NSFileProviderError.cannotSynchronize.rawValue
            case .nameCollision: code = NSFileProviderError.filenameCollision.rawValue
            case .directoryNotEmpty: code = NSFileProviderError.directoryNotEmpty.rawValue
            case .cancelled: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            case .excludedFromSync: code = NSFileProviderError.excludedFromSync.rawValue
            default: code = NSFileProviderError.cannotSynchronize.rawValue
            }
            context = ["correlationID": failure.correlationID.uuidString]
        } else if let storeError = error as? StoreBridgeError, storeError == .schemaFenced {
            code = NSFileProviderError.cannotSynchronize.rawValue; context = ["reason": "schema_fenced"]
        } else { code = NSFileProviderError.cannotSynchronize.rawValue; context = [:] }
        return NSError(domain: NSFileProviderErrorDomain, code: code, userInfo: context)
    }
}
