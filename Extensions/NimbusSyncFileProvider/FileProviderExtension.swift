import FileProvider
import CloudreveFileProviderKit

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderDomainState, NSFileProviderThumbnailing, NSFileProviderCustomAction, @unchecked Sendable {
    private let implementation: NimbusSyncFileProviderExtension

    required init(domain: NSFileProviderDomain) {
        implementation = NimbusSyncFileProviderExtension(domain: domain)
        super.init()
    }

    func invalidate() {
        implementation.invalidate()
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        implementation.item(for: identifier, request: request, completionHandler: completionHandler)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        implementation.fetchContents(for: itemIdentifier, version: requestedVersion, request: request, completionHandler: completionHandler)
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        implementation.createItem(basedOn: itemTemplate, fields: fields, contents: url, options: options, request: request, completionHandler: completionHandler)
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        implementation.modifyItem(item, baseVersion: version, changedFields: changedFields, contents: newContents, options: options, request: request, completionHandler: completionHandler)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        implementation.deleteItem(identifier: identifier, baseVersion: version, options: options, request: request, completionHandler: completionHandler)
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        try implementation.enumerator(for: containerItemIdentifier, request: request)
    }

    func importDidFinish(completionHandler: @escaping () -> Void) {
        implementation.importDidFinish(completionHandler: completionHandler)
    }

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        implementation.materializedItemsDidChange(completionHandler: completionHandler)
    }

    func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        implementation.pendingItemsDidChange(completionHandler: completionHandler)
    }

    var domainVersion: NSFileProviderDomainVersion {
        implementation.domainVersion
    }

    var userInfo: [AnyHashable: Any] {
        implementation.userInfo
    }

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        implementation.fetchThumbnails(for: itemIdentifiers, requestedSize: size, perThumbnailCompletionHandler: perThumbnailCompletionHandler, completionHandler: completionHandler)
    }

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier, onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier], completionHandler: @escaping (Error?) -> Void) -> Progress {
        implementation.performAction(identifier: actionIdentifier, onItemsWithIdentifiers: itemIdentifiers, completionHandler: completionHandler)
    }
}
