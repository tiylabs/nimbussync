import Foundation
import FileProvider
import UniformTypeIdentifiers
import CryptoKit
import CloudreveAuthKit
import CloudreveDomainKit
import CloudreveStoreBridge

private struct APIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: Value?
}

private struct RemoteFileDTO: Decodable {
    let type: Int
    let id: String
    let name: String
    let createdAt: String?
    let updatedAt: String?
    let size: Int64?
    let path: String
    let permission: String?
    let capability: String?
    let primaryEntity: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case size
        case path
        case permission
        case capability
        case primaryEntity = "primary_entity"
    }
}

private struct StoragePolicyDTO: Decodable {
    let type: String?
    let encryption: Bool?
    let streamingEncryption: Bool?
    enum CodingKeys: String, CodingKey { case type; case encryption; case streamingEncryption = "streaming_encryption" }
}

private struct UploadCredentialDTO: Decodable {
    let sessionID: String
    let expires: Int64
    let chunkSize: Int64
    let uploadURLs: [String]?
    let callbackSecret: String?
    let completeURL: String?
    let storagePolicy: StoragePolicyDTO?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case expires
        case chunkSize = "chunk_size"
        case uploadURLs = "upload_urls"
        case callbackSecret = "callback_secret"
        case completeURL = "completeURL"
        case storagePolicy = "storage_policy"
    }
}

private struct EmptyResponse: Decodable {}

private struct UploadCredentialCache: Codable {
    let sessionID: String
    let uploadURLs: [String]
    let callbackSecret: String?
    let completeURL: String?
    let provider: String
    let expiresAt: Date?
}

private struct RemotePagination: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalItems: Int64?
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "page_size"
        case totalItems = "total_items"
        case nextToken = "next_token"
    }
}

private struct RemoteListDTO: Decodable {
    let files: [RemoteFileDTO]
    let pagination: RemotePagination?
}

private struct FileURLDTO: Decodable {
    let urls: [String]
    let expires: String?
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if task.currentRequest?.url?.host != request.url?.host { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

/// A bounded synchronous facade around URLSession. File Provider callbacks are
/// callback-based, so the network operation is kept off the main queue and has
/// a hard deadline while preserving the callback's ownership rules.
public final class CloudreveRemoteBackend: FileProviderBackend, @unchecked Sendable {
    private let origin: URL
    private let rootURI: String
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let capabilitySnapshot: CapabilitySnapshot
    private let providerName: String
    private let secretVault: OpaqueSecretVault

    public init(origin: URL, rootURI: String, store: SQLiteStateStore, vault: CredentialVault, credentialReference: String, capabilitySnapshot: CapabilitySnapshot = CapabilitySnapshot(), providerName: String = "unverified", secretVault: OpaqueSecretVault = MemoryOpaqueSecretVault(), requestTimeout: TimeInterval = 60) {
        self.origin = origin
        self.rootURI = rootURI
        self.store = store
        self.vault = vault
        self.credentialReference = credentialReference
        self.requestTimeout = requestTimeout
        self.capabilitySnapshot = capabilitySnapshot
        self.providerName = providerName
        self.secretVault = secretVault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    public func item(identifier: String) throws -> RemoteItem? { try store.item(identifier: identifier) }

    public func children(parentIdentifier: String) throws -> [RemoteItem] {
        var offset = 0
        var result: [RemoteItem] = []
        repeat {
            let page = try childrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: 500)
            result.append(contentsOf: page.items)
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        return result
    }

    public func childrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage {
        do {
            if try store.hasCompleteSnapshot(parentIdentifier: parentIdentifier) {
                return try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit)
            }
            let uri = try parentURI(for: parentIdentifier)
            let pageSize = 500
            let storedCursor = try store.snapshotCursor(parentIdentifier: parentIdentifier)
            let pageNumber: Int
            if let storedCursor, storedCursor.hasPrefix("page:"), let storedPage = Int(storedCursor.dropFirst("page:".count)) {
                pageNumber = storedPage
            } else {
                pageNumber = max(1, try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: 0, limit: pageSize).items.count / pageSize + 1)
            }
            var query = [
                URLQueryItem(name: "uri", value: uri),
                URLQueryItem(name: "page_size", value: String(pageSize)),
                URLQueryItem(name: "order_by", value: "name"),
                URLQueryItem(name: "order_direction", value: "asc"),
            ]
            if let cursor = storedCursor, cursor.hasPrefix("token:") {
                query.append(URLQueryItem(name: "next_page_token", value: String(cursor.dropFirst("token:".count))))
            } else {
                query.append(URLQueryItem(name: "page", value: String(pageNumber)))
            }
            let response: RemoteListDTO = try request(path: "file", method: "GET", query: query, body: nil, authenticated: true)
            let mapped = try response.files.map { dto in
                try store.upsertRemoteItem(makeItem(dto, parentIdentifier: parentIdentifier))
            }
            let pagination = response.pagination
            let hasMore: Bool
            if let nextToken = pagination?.nextToken {
                try store.recordSnapshotProgress(parentIdentifier: parentIdentifier, generation: 1, nextCursor: "token:\(nextToken)", complete: false)
                hasMore = true
            } else if let total = pagination?.totalItems {
                hasMore = Int64(offset + mapped.count) < total
                try store.recordSnapshotProgress(parentIdentifier: parentIdentifier, generation: 1, nextCursor: hasMore ? "page:\(pageNumber + 1)" : nil, complete: !hasMore)
            } else {
                hasMore = mapped.count >= min(limit, 500)
                try store.recordSnapshotProgress(parentIdentifier: parentIdentifier, generation: 1, nextCursor: hasMore ? "page:\(pageNumber + 1)" : nil, complete: !hasMore)
            }
            let localPage = try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit)
            return DirectoryPage(items: localPage.items, nextOffset: hasMore ? offset + localPage.items.count : nil, generation: 1, complete: !hasMore)
        } catch let error as CoreFailure where error.code == .network {
            guard try store.hasCompleteSnapshot(parentIdentifier: parentIdentifier) else { throw error }
            return try store.listChildrenPage(parentIdentifier: parentIdentifier, offset: offset, limit: limit)
        }
    }

    public func content(identifier: String, expectedVersion: Data?) throws -> Data {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try fetchContent(identifier: identifier, expectedVersion: expectedVersion, to: temporaryURL)
        return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
    }

    public func fetchContent(identifier: String, expectedVersion: Data?, to destination: URL) throws -> RemoteItem {
        guard let current = try store.item(identifier: identifier), let remoteID = current.remoteID else { throw CoreFailure(code: .notFound, retryable: false) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let fileURL: FileURLDTO = try request(path: "file/url", method: "POST", query: [], body: ["uris": [current.uri], "download": true, "redirect": false], authenticated: true)
        guard let signedURL = fileURL.urls.first, let url = URL(string: signedURL) else { throw CoreFailure(code: .notFound, retryable: false) }
        try downloadWithoutBearer(url: url, to: destination, expectedSize: current.size)
        let refreshed = try fetchRemoteItem(remoteID: remoteID, fallback: current)
        guard refreshed.version.content == current.version.content else {
            try? FileManager.default.removeItem(at: destination)
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        return refreshed
    }

    public func create(template: RemoteItem, content: Data?, replayKey: String) throws -> RemoteItem {
        try requireWrite()
        let parentURI = try parentURI(for: template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
        let targetURI = parentURI == "/" ? "/\(template.name)" : "\(parentURI)/\(template.name)"
        if let content, !content.isEmpty { return try uploadFile(uri: targetURI, content: content, previous: nil, itemIdentifier: template.itemIdentifier) }
        let dto: RemoteFileDTO = try request(path: "file/create", method: "POST", query: [], body: ["uri": targetURI, "type": template.kind == .folder ? "folder" : "file", "err_on_conflict": true], authenticated: true)
        return try store.upsertRemoteItem(makeItem(dto, parentIdentifier: template.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: template.itemIdentifier))
    }

    public func modify(item: RemoteItem, expectedVersion: Data?, changedFields: NSFileProviderItemFields, content: Data?, replayKey: String) throws -> RemoteItem {
        try requireWrite()
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        var result = current
        if changedFields.contains(.contents) {
            guard let content else { throw CoreFailure(code: .unsupportedMetadata, retryable: false) }
            result = try uploadFile(uri: current.uri, content: content, previous: current.remoteVersion, itemIdentifier: current.itemIdentifier)
        }
        if changedFields.contains(.filename) {
            let dto: RemoteFileDTO = try request(path: "file/rename", method: "POST", query: [], body: ["uri": result.uri, "new_name": item.name], authenticated: true)
            result = try store.upsertRemoteItem(makeItem(dto, parentIdentifier: result.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: result.itemIdentifier))
        }
        if changedFields.contains(.parentItemIdentifier) {
            let destination = try parentURI(for: item.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue)
            let _: EmptyResponse = try request(path: "file/move", method: "POST", query: [], body: ["uris": [result.uri], "dst": destination, "copy": false], authenticated: true)
            result.parentIdentifier = item.parentIdentifier
            result.uri = destination == "/" ? "/\(result.name)" : "\(destination)/\(result.name)"
            try store.insertItem(result)
        }
        return result
    }

    public func trash(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem {
        try requireWrite()
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try request(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": false], authenticated: true)
        var trashed = current
        trashed.trashed = true
        trashed.parentIdentifier = NSFileProviderItemIdentifier.trashContainer.rawValue
        try store.insertItem(trashed)
        return trashed
    }

    public func restore(item: RemoteItem, expectedVersion: Data?, replayKey: String) throws -> RemoteItem {
        try requireWrite()
        guard let current = try store.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try request(path: "file/restore", method: "POST", query: [], body: ["uris": [current.uri]], authenticated: true)
        var restored = current
        restored.trashed = false
        restored.parentIdentifier = item.parentIdentifier
        try store.insertItem(restored)
        return restored
    }

    public func delete(identifier: String, expectedVersion: Data?, recursive: Bool) throws {
        try requireWrite()
        guard let current = try store.item(identifier: identifier) else { return }
        if let expectedVersion, expectedVersion != current.version.content { throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true) }
        if current.kind == .folder && !recursive {
            let children = try children(parentIdentifier: identifier)
            if !children.isEmpty { throw CoreFailure(code: .directoryNotEmpty, retryable: false) }
        }
        guard current.trashed else { throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true) }
        let _: EmptyResponse = try request(path: "file", method: "DELETE", query: [], body: ["uris": [current.uri], "skip_soft_delete": true], authenticated: true)
        var tombstone = current
        tombstone.tombstone = true
        try store.insertItem(tombstone)
    }

    private func parentURI(for identifier: String) throws -> String {
        if identifier == NSFileProviderItemIdentifier.rootContainer.rawValue { return rootURI }
        guard let item = try store.item(identifier: identifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        return item.uri
    }

    private func requireWrite() throws {
        guard capabilitySnapshot.canWrite(provider: providerName) else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
    }

    private func uploadFile(uri: String, content: Data, previous: String?, itemIdentifier: String) throws -> RemoteItem {
        let operationID = UUID(uuidString: String(itemIdentifier.dropFirst(4))) ?? UUID()
        let fingerprint = Data(SHA256.hash(data: content + Data((previous ?? "").utf8)))
        var session = try store.uploadSession(operationID: operationID)
        var cache: UploadCredentialCache?
        if let existing = session, existing.fingerprint == fingerprint, existing.expiresAt.map({ $0 > Date() }) ?? true, let reference = existing.secretReference, let encoded = try secretVault.readSecret(reference: reference), let data = Data(base64Encoded: encoded) {
            cache = try? JSONDecoder().decode(UploadCredentialCache.self, from: data)
        } else if let existing = session, existing.fingerprint != fingerprint {
            var abandoned = existing
            abandoned.state = "abandoned"
            try store.saveUploadSession(abandoned)
            session = nil
        }
        if cache == nil {
            var uploadBody: [String: Any] = ["uri": uri, "size": content.count, "policy_id": ""]
            if let previous { uploadBody["previous"] = previous }
            let credential: UploadCredentialDTO = try request(path: "file/upload", method: "PUT", query: [], body: uploadBody, authenticated: true)
            let provider = credential.storagePolicy?.type?.lowercased() ?? providerName.lowercased()
            guard provider == providerName.lowercased() || providerName == "local" else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
            let expiresAt = credential.expires > 0 ? Date(timeIntervalSince1970: TimeInterval(credential.expires)) : nil
            let secretReference = "transfer-\(operationID.uuidString)"
            let newCache = UploadCredentialCache(sessionID: credential.sessionID, uploadURLs: credential.uploadURLs ?? [], callbackSecret: credential.callbackSecret, completeURL: credential.completeURL, provider: provider, expiresAt: expiresAt)
            try secretVault.writeSecret(JSONEncoder().encode(newCache).base64EncodedString(), reference: secretReference)
            let descriptors = planParts(size: content.count, chunkSize: max(1, Int(credential.chunkSize)))
            let parts = descriptors.map { descriptor in UploadPartCheckpoint(index: descriptor.index, offset: Int64(descriptor.offset), length: Int64(descriptor.length), sourceHash: Data(SHA256.hash(data: content[descriptor.offset..<(descriptor.offset + descriptor.length)]))) }
            session = UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: credential.sessionID, secretReference: secretReference, fingerprint: fingerprint, provider: provider, chunkSize: credential.chunkSize, expiresAt: expiresAt, state: "active", parts: parts)
            cache = newCache
            try store.saveUploadSession(session!)
        }
        guard var active = session, let cache else { throw CoreFailure(code: .unknownOutcome, retryable: false) }
        guard active.fingerprint == fingerprint else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
        for index in active.parts.indices {
            let part = active.parts[index]
            let start = Int(part.offset)
            let end = min(content.count, start + Int(part.length))
            let data = content[start..<end]
            let hash = Data(SHA256.hash(data: data))
            if part.state == "completed" {
                guard hash == part.sourceHash else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
                continue
            }
            let etag: String?
            if let uploadURL = cache.uploadURLs[safe: part.index], let url = URL(string: uploadURL), !uploadURL.isEmpty {
                etag = try uploadSignedPart(url: url, data: Data(data))
            } else {
                etag = try uploadRelayPart(sessionID: cache.sessionID, index: part.index, data: Data(data))
            }
            active.parts[index].etag = etag
            active.parts[index].sourceHash = hash
            active.parts[index].state = "completed"
            active.parts[index].attempt += 1
            try store.saveUploadSession(active)
        }
        if let secret = cache.callbackSecret {
            let policy = cache.provider.isEmpty ? providerName : cache.provider
            _ = try? requestNoContent(path: "callback/\(policy)/\(cache.sessionID)/\(secret)", method: "GET", authenticated: false)
        }
        let result = try fetchRemoteByURI(uri: uri, fallbackIdentifier: itemIdentifier)
        active.state = "completed"
        try store.saveUploadSession(active)
        return result
    }

    private func fetchRemoteByURI(uri: String, fallbackIdentifier: String) throws -> RemoteItem {
        let dto: RemoteFileDTO = try request(path: "file/info", method: "GET", query: [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "extended", value: "true")], body: nil, authenticated: true)
        return try store.upsertRemoteItem(makeItem(dto, parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: fallbackIdentifier))
    }

    private func uploadSignedPart(url: URL, data: Data) throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        let (_, response) = try perform(request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        return response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func uploadRelayPart(sessionID: String, index: Int, data: Data) throws -> String? {
        _ = try requestNoContent(path: "file/upload/\(sessionID)/\(index)", method: "POST", authenticated: true, body: data)
        return nil
    }

    private func requestNoContent(path: String, method: String, authenticated: Bool, body: Data? = nil) throws -> (Data, URLResponse) {
        let url = origin.appendingPathComponent("api/v4").appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        if let body { request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        if authenticated {
            guard let credential = try vault.read(reference: credentialReference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try perform(request)
    }

    private func fetchRemoteItem(remoteID: String, fallback: RemoteItem) throws -> RemoteItem {
        do {
            let dto: RemoteFileDTO = try request(path: "file/info", method: "GET", query: [URLQueryItem(name: "id", value: remoteID), URLQueryItem(name: "extended", value: "true")], body: nil, authenticated: true)
            return try store.upsertRemoteItem(makeItem(dto, parentIdentifier: fallback.parentIdentifier ?? NSFileProviderItemIdentifier.rootContainer.rawValue, itemIdentifier: fallback.itemIdentifier))
        } catch { return fallback }
    }

    private func makeItem(_ dto: RemoteFileDTO, parentIdentifier: String, itemIdentifier: String? = nil) -> RemoteItem {
        let primary = dto.primaryEntity ?? dto.updatedAt ?? dto.createdAt ?? dto.id
        let isFolder = dto.type == 1
        let writable = capabilitySnapshot.canWrite(provider: providerName)
        let trashable = writable && capabilitySnapshot.trashRestore == .verified
        return RemoteItem(itemIdentifier: itemIdentifier ?? CloudreveIdentifier.item(), remoteID: dto.id, parentIdentifier: parentIdentifier, name: dto.name, uri: dto.path, kind: isFolder ? .folder : .file, contentType: isFolder ? UTType.folder.identifier : UTType.data.identifier, size: max(0, dto.size ?? 0), remoteVersion: primary, version: ItemVersion(content: VersionHasher.content(primaryEntity: primary), metadata: VersionHasher.metadata(parent: parentIdentifier, name: dto.name, kind: isFolder ? .folder : .file, permissionBits: 1, revision: dto.updatedAt)), canRead: true, canWrite: writable, canAddChildren: writable && isFolder, canTrash: trashable, canDelete: trashable)
    }

    private func request<Value: Decodable>(path: String, method: String, query: [URLQueryItem], body: [String: Any]?, authenticated: Bool) throws -> Value {
        var url = origin.appendingPathComponent("api/v4").appendingPathComponent(path)
        if !query.isEmpty { var components = URLComponents(url: url, resolvingAgainstBaseURL: false); components?.queryItems = query; url = components?.url ?? url }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            guard let credential = try vault.read(reference: credentialReference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try perform(request)
        guard let httpResponse = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        guard (200..<300).contains(httpResponse.statusCode) else { throw mapHTTPStatus(httpResponse.statusCode) }
        let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: data)
        guard envelope.code == 0 else { throw mapAPIError(envelope.code) }
        if let value = envelope.data { return value }
        if Value.self == EmptyResponse.self, let empty = EmptyResponse() as? Value { return empty }
        throw CoreFailure(code: .unknownOutcome, retryable: false)
    }

    private func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLSessionResult()
        let task = session.dataTask(with: request) { data, response, error in
            result.set(data: data ?? Data(), response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else { task.cancel(); throw CoreFailure(code: .network, retryable: true) }
        if let resultError = result.error { throw CoreFailure(code: .network, retryable: true, redactedContext: ["error": String(describing: resultError)]) }
        guard let resultResponse = result.response else { throw CoreFailure(code: .network, retryable: true) }
        return (result.data, resultResponse)
    }

    private func downloadWithoutBearer(url: URL, to destination: URL, expectedSize: Int64) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLSessionResult()
        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: requestTimeout)) { url, response, error in
            result.set(data: Data(), response: response, error: error, temporaryURL: url)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else { task.cancel(); throw CoreFailure(code: .network, retryable: true) }
        if let resultError = result.error { throw CoreFailure(code: .network, retryable: true, redactedContext: ["error": String(describing: resultError)]) }
        guard let temporaryURL = result.temporaryURL else { throw CoreFailure(code: .network, retryable: true) }
        let input = try FileHandle(forReadingFrom: temporaryURL)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close(); try? FileManager.default.removeItem(at: temporaryURL) }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            total += Int64(chunk.count)
        }
        guard expectedSize == 0 || total == expectedSize else { throw CoreFailure(code: .integrityFailure, retryable: true) }
    }
}

private final class URLSessionResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    private(set) var response: URLResponse?
    private(set) var error: Error?
    private(set) var temporaryURL: URL?

    func set(data: Data, response: URLResponse?, error: Error?, temporaryURL: URL? = nil) {
        lock.lock()
        self.data = data; self.response = response; self.error = error; self.temporaryURL = temporaryURL
        lock.unlock()
    }
}

private func mapHTTPStatus(_ status: Int) -> CoreFailure {
    switch status { case 401: CoreFailure(code: .authentication, retryable: false, userActionRequired: true); case 403: CoreFailure(code: .permissionDenied, retryable: false); case 404: CoreFailure(code: .notFound, retryable: false); default: CoreFailure(code: .network, retryable: true) }
}

private func mapAPIError(_ code: Int) -> CoreFailure {
    switch code { case 401, 40020, 40089: CoreFailure(code: .authentication, retryable: false, userActionRequired: true); case 40006, 40007, 40008: CoreFailure(code: .permissionDenied, retryable: false); case 40009, 40010: CoreFailure(code: .notFound, retryable: false); default: CoreFailure(code: .unknownOutcome, retryable: false) }
}

private struct UploadPartDescriptor {
    let index: Int
    let offset: Int
    let length: Int
}

private func planParts(size: Int, chunkSize: Int) -> [UploadPartDescriptor] {
    let chunkSize = max(1, chunkSize)
    if size == 0 { return [UploadPartDescriptor(index: 0, offset: 0, length: 0)] }
    var result: [UploadPartDescriptor] = []
    var offset = 0
    var index = 0
    while offset < size {
        let length = min(chunkSize, size - offset)
        result.append(UploadPartDescriptor(index: index, offset: offset, length: length))
        offset += length; index += 1
    }
    return result
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
