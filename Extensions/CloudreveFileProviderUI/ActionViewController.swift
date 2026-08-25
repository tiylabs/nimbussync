import AppKit
import FileProviderUI

final class ActionViewController: FPUIActionExtensionViewController {
    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        let label = NSTextField(labelWithString: "Cloudreve is preparing this action.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 300, height: 40)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        view.addSubview(label)
        self.view = view
        extensionContext.completeRequest()
    }

    override func prepare(forError error: Error) {
        extensionContext.cancelRequest(withError: error as NSError)
    }
}

