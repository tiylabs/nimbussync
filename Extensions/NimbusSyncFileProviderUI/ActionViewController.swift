import AppKit
import FileProviderUI

final class ActionViewController: FPUIActionExtensionViewController {
    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
		let itemIdentifier = itemIdentifiers.first?.rawValue ?? ""
		guard ["ai.tiylabs.nimbussync.open-in-nimbussync", "ai.tiylabs.nimbussync.resolve-conflict"].contains(actionIdentifier), itemIdentifier.hasPrefix("cri-"), itemIdentifier.count == 40 else {
			extensionContext.cancelRequest(withError: NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
			return
		}
		let label = NSTextField(labelWithString: "NimbusSync is opening this item.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 300, height: 40)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        view.addSubview(label)
        self.view = view
		let destination = actionIdentifier == "ai.tiylabs.nimbussync.resolve-conflict" ? "conflict-item" : "item"
		let url = URL(string: "nimbussync://\(destination)/\(itemIdentifier)")!
		extensionContext.open(url) { [weak self] _ in self?.extensionContext.completeRequest() }
    }

    override func prepare(forError error: Error) {
        extensionContext.cancelRequest(withError: error as NSError)
    }
}
