import Foundation
import FileProvider
import UniformTypeIdentifiers
import ImageIO
import AppKit
import OSLog
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator

public final class NimbusSyncFileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
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
    public let contentPolicy: NSFileProviderContentPolicy
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

    public init(model: RemoteItem, isDownloaded: Bool = false, hasConflict: Bool = false) {
        self.model = model
        self.itemIdentifier = NSFileProviderItemIdentifier(model.itemIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? model.itemIdentifier : model.itemIdentifier)
        self.parentItemIdentifier = NSFileProviderItemIdentifier(model.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
		self.filename = model.name.isEmpty ? "NimbusSync" : model.name
        self.contentType = UTType(model.contentType) ?? (model.kind == .folder ? .folder : .data)
        self.documentSize = model.kind == .folder ? nil : NSNumber(value: model.size)
        self.childItemCount = model.kind == .folder ? nil : nil
        self.creationDate = model.creationDate
        self.contentModificationDate = model.contentModificationDate
        var itemCapabilities: NSFileProviderItemCapabilities = []
        if model.canRead { itemCapabilities.insert(.allowsReading) }
        if model.canWrite { itemCapabilities.insert(.allowsWriting); itemCapabilities.insert(.allowsRenaming) }
        if model.canAddChildren { itemCapabilities.insert(.allowsAddingSubItems) }
        if model.canWrite { itemCapabilities.insert(.allowsReparenting) }
        if model.canDelete && model.trashed { itemCapabilities.insert(.allowsDeleting) }
        if model.canTrash && !model.trashed { itemCapabilities.insert(.allowsTrashing) }
        self.capabilities = itemCapabilities
        self.contentPolicy = model.canRead && !model.tombstone ? .downloadLazily : .inherited
        self.itemVersion = NSFileProviderItemVersion(contentVersion: model.version.content, metadataVersion: model.version.metadata)
        self.userInfo = ["authenticated": model.canRead, "trashed": model.trashed, "tombstone": model.tombstone, "hasConflict": hasConflict]
        self.isUploaded = !model.tombstone
        self.isUploading = false
        self.uploadingError = nil
        self.isDownloaded = isDownloaded
        self.isDownloading = false
        self.downloadingError = nil
        self.isMostRecentVersionDownloaded = isDownloaded
        self.isShared = false
        self.isSharedByCurrentUser = false
        self.decorations = hasConflict ? [NSFileProviderItemDecorationIdentifier("ai.tiy.nimbussync.conflict")] : nil
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

/// Used when the shared App Group or Domain database cannot be opened. A
/// File Provider callback must fail closed in this state rather than serving
/// detached in-memory data that disappears with the extension process.
public final class UnavailableFileProviderBackend: FileProviderBackend, @unchecked Sendable {
    public init() {}
    public func item(identifier: String) throws -> RemoteItem? { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func children(parentIdentifier: String) throws -> [RemoteItem] { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func content(identifier: String, expectedVersion: Data?) throws -> Data { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws { throw CoreFailure(code: .database, retryable: false, userActionRequired: true) }
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
    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = true; current.trashOriginalParentIdentifier = current.parentIdentifier; current.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue; values[item.itemIdentifier] = current; return current }
    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem { lock.lock(); defer { lock.unlock() }; guard var current = values[item.itemIdentifier] else { throw CoreFailure(code: .notFound, retryable: false) }; if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }; current.trashed = false; current.parentIdentifier = current.trashOriginalParentIdentifier ?? item.parentIdentifier; current.trashOriginalParentIdentifier = nil; values[item.itemIdentifier] = current; return current }
    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = values[identifier] else { return }
        if let expectedVersion, current.version.content != expectedVersion { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let directChildren = values.values.filter { $0.parentIdentifier == identifier }
        if !recursive && !directChildren.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }
        var identifiers = [identifier]
        if recursive {
            var index = 0
            while index < identifiers.count {
                let parent = identifiers[index]
                identifiers.append(contentsOf: values.values.filter { $0.parentIdentifier == parent }.map(\.itemIdentifier))
                index += 1
            }
        }
        for value in identifiers {
            values.removeValue(forKey: value)
            contents.removeValue(forKey: value)
        }
    }
}

public final class NimbusSyncFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.enumerateItemsOnWorker(for: observer, startingAt: page)
        }
    }

    private func enumerateItemsOnWorker(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
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
            observer.didEnumerate(pageResult.items.map { item in
                let downloaded = (try? store?.isMaterialized(item.itemIdentifier)) ?? false
                let hasConflict = (try? store?.hasPendingConflict(itemIdentifier: item.itemIdentifier)) ?? false
                return NimbusSyncFileProviderItem(model: item, isDownloaded: downloaded, hasConflict: hasConflict)
            })
            if let nextOffset = pageResult.nextOffset {
                let next = try PageToken(domainIdentifier: domainIdentifier, parentIdentifier: parentIdentifier, snapshotGeneration: pageResult.generation, offset: nextOffset).encoded()
                observer.finishEnumerating(upTo: NSFileProviderPage(next))
            } else { observer.finishEnumerating(upTo: nil) }
        } catch let error as StoreBridgeError { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
        catch { observer.finishEnumeratingWithError(FileProviderErrorMapper.map(error)) }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard !invalidated else { return }
        guard let store else {
            observer.finishEnumeratingWithError(FileProviderErrorMapper.map(CoreFailure(code: .database, retryable: false, userActionRequired: true)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.enumerateChangesOnWorker(for: observer, from: syncAnchor, store: store)
        }
    }

    private func enumerateChangesOnWorker(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor, store: SQLiteStateStore) {
        guard !invalidated else { return }
        do {
            let anchor = try SyncAnchor.decode(Data(syncAnchor as NSData))
            let batch = try store.enumerateChanges(domainIdentifier: domainIdentifier, scope: parentIdentifier, from: anchor)
            var updates: [NSFileProviderItem] = []
            var deletes: [NSFileProviderItemIdentifier] = []
            for change in batch.changes {
                if change.kind == "deleted" {
                    deletes.append(NSFileProviderItemIdentifier(change.itemIdentifier))
                } else if let item = try backend.item(identifier: change.itemIdentifier) {
                    let hasConflict = (try? store.hasPendingConflict(itemIdentifier: change.itemIdentifier)) ?? false
                    updates.append(NimbusSyncFileProviderItem(model: item, hasConflict: hasConflict))
                }
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
    private let lock = NSLock()
    private var finished = false
    init(_ handler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) { self.handler = handler }
    func call(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(url, item, error)
    }
}

open class NimbusSyncFileProviderExtension: NSObject, NSFileProviderDomainState, NSFileProviderThumbnailing, NSFileProviderCustomAction, @unchecked Sendable {
    public let domain: NSFileProviderDomain
    private var store: SQLiteStateStore?
    private var backend: FileProviderBackend
    private let stateProjection: DomainStateProjection
    private let stateLock = NSLock()
    private var invalidated = false
    private let reconciliationLogger = Logger(subsystem: "ai.tiy.nimbussync", category: "file-provider-reconciliation")

    @objc public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        var resolvedStore: SQLiteStateStore?
        var resolvedBackend: FileProviderBackend = UnavailableFileProviderBackend()
        var authenticated = false
        if let databaseURL = try? AppGroupPaths.prepareDomain(domain.identifier.rawValue), let store = try? SQLiteStateStore(url: databaseURL) {
            resolvedStore = store
            let storedDomain: StoredDomain?
            do { storedDomain = try store.domain(identifier: domain.identifier.rawValue) } catch { storedDomain = nil }
            if let stored = storedDomain, let origin = URL(string: stored.origin) {
                let credentialVault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let secretVault = KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current())
                authenticated = (try? credentialVault.read(reference: stored.secretReference)) != nil
                resolvedBackend = NimbusSyncRemoteBackend(origin: origin, rootURI: stored.rootURI, store: store, vault: credentialVault, credentialReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, providerName: stored.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: secretVault)
            }
        }
        self.store = resolvedStore
        self.backend = resolvedBackend
        if let stateURL = AppGroupPaths.domainVersionURL(domain.identifier.rawValue) {
            self.stateProjection = DomainStateProjection.load(from: stateURL, authenticated: authenticated)
        } else {
            self.stateProjection = DomainStateProjection(authenticated: authenticated)
        }
        super.init()
    }

    public convenience init(domain: NSFileProviderDomain, store: SQLiteStateStore, backend: FileProviderBackend) {
        self.init(domain: domain)
        self.store = store
        self.backend = backend
    }

    @objc public func invalidate() { invalidated = true }

    @objc public var domainVersion: NSFileProviderDomainVersion { stateLock.lock(); defer { stateLock.unlock() }; return stateProjection.domainVersion }
    @objc public var userInfo: [AnyHashable: Any] { stateLock.lock(); defer { stateLock.unlock() }; return stateProjection.userInfo }

    @objc(itemForIdentifier:request:completionHandler:)
    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ItemCompletion(completionHandler)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.invalidated, !progress.isCancelled else {
                completion.call(nil, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            if identifier == .rootContainer {
                completion.call(self.rootItem(), nil)
                progress.completedUnitCount = 1
                return
            }
            do {
                guard let item = try self.backend.item(identifier: identifier.rawValue) else {
                    completion.call(nil, FileProviderErrorMapper.map(CoreFailure(code: .notFound, retryable: false)))
                    return
                }
                let downloaded = (try? self.store?.isMaterialized(identifier.rawValue)) ?? false
                let hasConflict = (try? self.store?.hasPendingConflict(itemIdentifier: identifier.rawValue)) ?? false
                completion.call(NimbusSyncFileProviderItem(model: item, isDownloaded: downloaded, hasConflict: hasConflict), nil)
                progress.completedUnitCount = 1
            } catch {
                completion.call(nil, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    @objc(fetchContentsForItemWithIdentifier:version:request:completionHandler:)
    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let cancellation = FetchCompletion(completionHandler)
        progress.cancellationHandler = { cancellation.call(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !progress.isCancelled else { return }
            var temporaryURL: URL?
            do {
                let manager = NSFileProviderManager(for: self.domain)
                guard let directory = try manager?.temporaryDirectoryURL() else { throw CoreFailure(code: .network, retryable: true) }
				let url = directory.appendingPathComponent("nimbussync-\(UUID().uuidString).tmp")
                temporaryURL = url
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CoreFailure(code: .network, retryable: true) }
                let item = try self.backend.fetchContent(identifier: itemIdentifier.rawValue, expectedVersion: requestedVersion?.contentVersion, to: url)
                guard !progress.isCancelled else { throw CoreFailure(code: .cancelled, retryable: false) }
                try self.store?.setMaterialized(itemIdentifier.rawValue, materialized: true)
                let hasConflict = (try? self.store?.hasPendingConflict(itemIdentifier: itemIdentifier.rawValue)) ?? false
                cancellation.call(url, NimbusSyncFileProviderItem(model: item, isDownloaded: true, hasConflict: hasConflict), nil)
                progress.completedUnitCount = 1
            } catch {
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                cancellation.call(nil, nil, FileProviderErrorMapper.map(error))
            }
        }
        return progress
    }

    @objc(createItemBasedOnTemplate:fields:contents:options:request:completionHandler:)
    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let templateIdentifier = itemTemplate.itemIdentifier.rawValue
        let completion = MutationCompletion(completionHandler)
        progress.cancellationHandler = { [weak self] in
            try? self?.store?.requestCancel(itemIdentifier: templateIdentifier)
            completion.call(nil, fields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(nil, fields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                let content = try url.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
                let model = try self.templateModel(itemTemplate)
                let item = try FileProviderMutationCoordinator(store: self.store, backend: self.backend).create(template: model, content: content, fields: fields, options: options)
                self.advanceDomainState()
                completion.call(NimbusSyncFileProviderItem(model: item), [], false, nil); progress.completedUnitCount = 1
            } catch { completion.call(nil, fields, false, FileProviderErrorMapper.map(error)) }
        }
        return progress
    }

    @objc(modifyItem:baseVersion:changedFields:contents:options:request:completionHandler:)
    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let itemIdentifier = item.itemIdentifier.rawValue
        let completion = MutationCompletion(completionHandler)
        progress.cancellationHandler = { [weak self] in
            try? self?.store?.requestCancel(itemIdentifier: itemIdentifier)
            completion.call(nil, changedFields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(nil, changedFields, false, FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do {
                guard let model = try self.backend.item(identifier: item.itemIdentifier.rawValue) else { throw CoreFailure(code: .notFound, retryable: false) }
                let content = try newContents.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
                var requested = model
                if changedFields.contains(.filename) { requested.name = item.filename }
                if changedFields.contains(.parentItemIdentifier) { requested.parentIdentifier = item.parentItemIdentifier.rawValue }
                let updated = try FileProviderMutationCoordinator(store: self.store, backend: self.backend).modify(item: requested, baseVersion: version, fields: changedFields, contents: content, options: options)
                self.advanceDomainState()
                let hasConflict = (try? self.store?.hasPendingConflict(itemIdentifier: updated.itemIdentifier)) ?? false
                completion.call(NimbusSyncFileProviderItem(model: updated, hasConflict: hasConflict), self.unsupportedFields(changedFields), false, nil); progress.completedUnitCount = 1
            } catch { completion.call(nil, changedFields, false, FileProviderErrorMapper.map(error)) }
        }
        return progress
    }

    @objc(deleteItemWithIdentifier:baseVersion:options:request:completionHandler:)
    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = DeleteCompletion(completionHandler)
        progress.cancellationHandler = { [weak self] in
            try? self?.store?.requestCancel(itemIdentifier: identifier.rawValue)
            completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !progress.isCancelled else {
                completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
                return
            }
            do { try FileProviderMutationCoordinator(store: self.store, backend: self.backend).delete(itemIdentifier: identifier.rawValue, baseVersion: version, options: options); self.advanceDomainState(); completion.call(nil); progress.completedUnitCount = 1 } catch { completion.call(FileProviderErrorMapper.map(error)) }
        }
        return progress
    }

    @objc(enumeratorForContainerItemIdentifier:request:error:)
    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let parent = containerItemIdentifier == .rootContainer ? NSFileProviderItemIdentifier.rootContainer.rawValue : containerItemIdentifier.rawValue
        return NimbusSyncFileProviderEnumerator(parentIdentifier: parent, domainIdentifier: domain.identifier.rawValue, store: store, backend: backend)
    }

    @objc(importDidFinishWithCompletionHandler:)
    public func importDidFinish(completionHandler: @escaping () -> Void) { try? store?.completeSystemSetRefresh("materialized"); completionHandler() }
    @objc(materializedItemsDidChangeWithCompletionHandler:)
    public func materializedItemsDidChange(completionHandler: @escaping () -> Void) { try? store?.markSystemSetRefreshRequired("materialized"); completionHandler() }
    @objc(pendingItemsDidChangeWithCompletionHandler:)
    public func pendingItemsDidChange(completionHandler: @escaping () -> Void) { try? store?.markSystemSetRefreshRequired("pending"); completionHandler() }

    @objc(fetchThumbnailsForItemIdentifiers:requestedSize:perThumbnailCompletionHandler:completionHandler:)
    public func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let completion = ErrorCompletion(completionHandler)
        progress.cancellationHandler = { completion.call(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, !progress.isCancelled else { return }
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
                completion.call(nil)
            } catch { completion.call(FileProviderErrorMapper.map(error)) }
        }
        return progress
    }

    @objc(performActionWithIdentifier:onItemsWithIdentifiers:completionHandler:)
    public func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ErrorCompletion(completionHandler)
        guard actionIdentifier.rawValue == "ai.tiy.nimbussync.check-for-updates" else { completion.call(FileProviderErrorMapper.map(CoreFailure(code: .unsupportedMetadata, retryable: false))); return progress }
        let task = Task { [weak self] in
            guard let self, !progress.isCancelled else { completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false))); return }
            let registry = try? AppGroupStoreFactory().registryStore()
            do {
                guard let store = self.store else { throw CoreFailure(code: .database, retryable: false) }
                let scope = itemIdentifiers.first?.rawValue ?? NSFileProviderItemIdentifier.rootContainer.rawValue
                guard scope == NSFileProviderItemIdentifier.rootContainer.rawValue || scope == NSFileProviderItemIdentifier.workingSet.rawValue || CloudreveIdentifier.validate(scope, prefix: CloudreveIdentifier.itemPrefix) else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
                guard let stored = try store.domain(identifier: self.domain.identifier.rawValue),
                      let remoteScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI),
                      let origin = URL(string: stored.origin) else {
                    throw CoreFailure(code: .database, retryable: false)
                }
                var descriptor = DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: remoteScope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
                descriptor.status = .reconciling
                try store.setDomainStatus(identifier: stored.identifier, status: .reconciling)
                try? registry?.setDomainStatus(identifier: stored.identifier, status: .reconciling)
                reconciliationLogger.info("manual_reconcile.started domain=\(stored.identifier, privacy: .public) scope=\(scope, privacy: .public)")

                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let reconciler = CloudreveReconciliationService(origin: origin, store: store, registry: registry, vault: vault, credentialReference: stored.secretReference)
                try await reconciler.reconcile(descriptor: descriptor, reason: "manual_check")

                let signaller = FileProviderWorkingSetSignaller(domain: self.domain)
                let drainer = SignalOutboxDrainer(store: store, signaller: signaller)
                guard await drainer.drain() else { throw CoreFailure(code: .network, retryable: true) }
                // A manual check must also wake Finder when the item was
                // already journaled but the previous system signal was missed.
                try await signaller.signalWorkingSet()
                try store.setDomainStatus(identifier: stored.identifier, status: .healthy)
                try? registry?.setDomainStatus(identifier: stored.identifier, status: .healthy)
                reconciliationLogger.info("manual_reconcile.completed domain=\(stored.identifier, privacy: .public)")
                progress.completedUnitCount = 1
                completion.call(nil)
            } catch {
                if let store = self.store, let stored = try? store.domain(identifier: self.domain.identifier.rawValue) {
                    let status = fileProviderReconciliationStatus(for: error)
                    try? store.setDomainStatus(identifier: stored.identifier, status: status)
                    try? registry?.setDomainStatus(identifier: stored.identifier, status: status)
                    reconciliationLogger.error("manual_reconcile.failed domain=\(stored.identifier, privacy: .public) code=\(fileProviderErrorCode(error), privacy: .public)")
                } else {
                    reconciliationLogger.error("manual_reconcile.failed code=\(fileProviderErrorCode(error), privacy: .public)")
                }
                completion.call(FileProviderErrorMapper.map(error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            completion.call(FileProviderErrorMapper.map(CoreFailure(code: .cancelled, retryable: false)))
        }
        return progress
    }

    private func rootItem() -> NimbusSyncFileProviderItem {
        let authenticated = userInfo["authenticated"] as? Bool ?? false
        let storedRoot: StoredDomain?
        if let store { storedRoot = try? store.domain(identifier: domain.identifier.rawValue) } else { storedRoot = nil }
        let rootURI = storedRoot?.rootURI ?? "/"
        let root = RemoteItem(itemIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: domain.displayName, uri: rootURI, kind: .folder, contentType: UTType.folder.identifier, version: ItemVersion(content: Data("root".utf8), metadata: Data(domain.identifier.rawValue.utf8)), canRead: authenticated, canWrite: false, canAddChildren: false, canTrash: false, canDelete: false)
        return NimbusSyncFileProviderItem(model: root)
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

    private func advanceDomainState() {
        stateLock.lock()
        stateProjection.advance()
        persistDomainState()
        stateLock.unlock()
    }
}

private final class ErrorCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    private let lock = NSLock()
    private var finished = false
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(error)
    }
}

private final class ItemCompletion: @unchecked Sendable {
    private let handler: (NSFileProviderItem?, Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (NSFileProviderItem?, Error?) -> Void) { self.handler = handler }

    func call(_ item: NSFileProviderItem?, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(item, error)
    }
}

private final class MutationCompletion: @unchecked Sendable {
    private let handler: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) { self.handler = handler }

    func call(_ item: NSFileProviderItem?, _ fields: NSFileProviderItemFields, _ replaced: Bool, _ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(item, fields, replaced, error)
    }
}

private final class DeleteCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    func call(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler(error)
    }
}

private func makeThumbnail(data: Data, size: CGSize) -> Data? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(16, Int(max(size.width, size.height))), kCGImageSourceCreateThumbnailWithTransform: true]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let destinationData = CFDataCreateMutable(nil, 0), let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return destinationData as Data
}

private func fileProviderErrorCode(_ error: Error) -> String {
    if let failure = error as? CoreFailure { return failure.code.rawValue }
    if error is CancellationError { return "cancelled" }
    let nsError = error as NSError
    return "error_\(nsError.domain)_\(nsError.code)"
}

private func fileProviderReconciliationStatus(for error: Error) -> DomainStatus {
    guard let failure = error as? CoreFailure else { return .eventDegraded }
    switch failure.code {
    case .authentication: return .authExpired
    case .rootUnavailable: return .rootUnavailable
    case .scopeConflict: return .scopeConflict
    case .database: return .repairRequired
    default: return .eventDegraded
    }
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
