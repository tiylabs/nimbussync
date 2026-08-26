import SwiftUI
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveProductKit
import CloudreveEventCoordinator
import CloudreveFileProviderKit
import CloudreveAuthKit
import CloudreveStoreBridge
import CloudreveDomainService
import ServiceManagement
import AppKit
import FileProvider
import OSLog
import UserNotifications

@main
struct NimbusSyncApp: App {
    @NSApplicationDelegateAdaptor(NimbusSyncAppDelegate.self) private var appDelegate
    @StateObject private var runtime: NimbusSyncAppState

    init() {
        let runtime = NimbusSyncAppState()
        _runtime = StateObject(wrappedValue: runtime)
    }

    var body: some Scene {
        let _ = appDelegate.configure(runtime: runtime)

        MenuBarExtra(
            "NimbusSync",
            systemImage: "externaldrive",
            isInserted: Binding(
                get: { appDelegate.isPrimaryInstance },
                set: { _ in }
            )
        ) {
            StatusPopoverContent(
                runtime: runtime,
                onOpenSettings: { appDelegate.openSettingsWindow() },
                onAddDomain: { appDelegate.openOnboardingWindow() },
                onOpenConflicts: { appDelegate.openConflictsWindow() }
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            settingsView(runtime: runtime, appDelegate: appDelegate)
        }
    }

    private func settingsView(runtime: NimbusSyncAppState, appDelegate: NimbusSyncAppDelegate) -> some View {
        SettingsView(
            domains: runtime.snapshot.domains,
            notificationPreferences: runtime.snapshot.notificationPreferences,
            onOpenFinder: runtime.openFinder,
            onRemove: runtime.removeDomain,
            onOpenWeb: runtime.openWeb,
            onReauthorize: runtime.reauthorize,
            onNotificationsChanged: runtime.setNotificationPreferences,
            onAddDomain: { appDelegate.openOnboardingWindow() }
        )
    }

}

@MainActor
private final class NimbusSyncAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private static let forwardedURLNotification = Notification.Name("ai.tiy.nimbussync.forwarded-external-urls")
    private static let instanceLockFilename = "ai.tiy.nimbussync.instance.lock"

    private let instanceLockDescriptor: Int32?
    private var primaryApplication: NSRunningApplication?
    private var secondaryTerminationWorkItem: DispatchWorkItem?
    private var hasReceivedExternalURLs = false
    private var runtimeStarted = false
    private weak var runtime: NimbusSyncAppState?
    private var pendingExternalURLs: [URL] = []
    private var didFinishLaunching = false
    private var onboardingWindowController: NSWindowController?
    private var conflictsWindowController: NSWindowController?
    private(set) var isPrimaryInstance: Bool

    override init() {
        let sharedContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppGroupPaths.identifier, isDirectory: true)
        let lockDirectory = (AppGroupPaths.root() ?? sharedContainer)
            .appendingPathComponent("Runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockPath = lockDirectory.appendingPathComponent(Self.instanceLockFilename).path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            instanceLockDescriptor = descriptor
            isPrimaryInstance = true
        } else {
            if descriptor >= 0 { close(descriptor) }
            instanceLockDescriptor = nil
            isPrimaryInstance = false
        }
        super.init()
        if !isPrimaryInstance {
            primaryApplication = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        }
        if isPrimaryInstance {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleForwardedURLs(_:)), name: Self.forwardedURLNotification, object: nil)
        }
    }

    func configure(runtime: NimbusSyncAppState) {
        self.runtime = runtime
        runtime.onDomainProvisioned = { [weak self] domain in
            guard let self else { return }
            onboardingWindowController?.window?.delegate = nil
            onboardingWindowController?.close()
            onboardingWindowController?.window?.delegate = self
            runtime.openFinder(domain: domain)
        }
        guard didFinishLaunching else { return }
        startRuntimeIfNeeded()
        drainPendingExternalURLs()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isPrimaryInstance else { return }
        NSApp.setActivationPolicy(.prohibited)
        closeSecondaryWindows()
        primaryApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else {
            closeSecondaryWindows()
            scheduleSecondaryTermination()
            return
        }
        UNUserNotificationCenter.current().delegate = self
        didFinishLaunching = true
        startRuntimeIfNeeded()
        drainPendingExternalURLs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        secondaryTerminationWorkItem?.cancel()
        if isPrimaryInstance {
            DistributedNotificationCenter.default().removeObserver(self)
            if let instanceLockDescriptor {
                _ = flock(instanceLockDescriptor, LOCK_UN)
                close(instanceLockDescriptor)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isPrimaryInstance else { return }
        closeSecondaryWindows()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isPrimaryInstance else {
            forwardExternalURLs(urls)
            return
        }
        guard runtime != nil else {
            pendingExternalURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(routeExternalURL)
        application.activate(ignoringOtherApps: true)
        application.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func openSettingsWindow() {
        guard isPrimaryInstance else { return }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        focusWindow(titled: "NimbusSync")
    }

    func openOnboardingWindow() {
        guard isPrimaryInstance, let runtime else { return }
        NSApp.activate(ignoringOtherApps: true)
        if onboardingWindowController == nil {
            let contentSize = NSSize(width: 520, height: 360)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(rootView: OnboardingWindowContent(runtime: runtime))
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.title = "Welcome to NimbusSync"
            window.delegate = self
            window.contentMinSize = contentSize
            window.contentMaxSize = contentSize
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindowController = NSWindowController(window: window)
        }
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindowController?.window else { return }
        runtime?.cancelDomainSetup()
    }

    func openConflictsWindow() {
        guard isPrimaryInstance, let runtime else { return }
        NSApp.activate(ignoringOtherApps: true)
        if conflictsWindowController == nil {
            let contentSize = NSSize(width: 720, height: 520)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            let hostingView = NSHostingView(rootView: ConflictWindowContent(runtime: runtime))
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.title = "Conflicts"
            window.isReleasedWhenClosed = false
            window.center()
            conflictsWindowController = NSWindowController(window: window)
        }
        conflictsWindowController?.showWindow(nil)
        conflictsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func startRuntimeIfNeeded() {
        guard isPrimaryInstance, !runtimeStarted, let runtime else { return }
        runtimeStarted = true
        runtime.start()
    }

    private func scheduleSecondaryTermination() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !hasReceivedExternalURLs else { return }
            NSApp.terminate(nil)
        }
        secondaryTerminationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: workItem)
    }

    private func closeSecondaryWindows() {
        guard !isPrimaryInstance else { return }
        NSApp.windows.forEach { $0.close() }
    }

    private func forwardExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        hasReceivedExternalURLs = true
        secondaryTerminationWorkItem?.cancel()
        let values = urls.map(\.absoluteString)
        DistributedNotificationCenter.default().postNotificationName(
            Self.forwardedURLNotification,
            object: nil,
            userInfo: ["urls": values],
            deliverImmediately: true
        )
        primaryApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
    }

    @objc private func handleForwardedURLs(_ notification: Notification) {
        guard let values = notification.userInfo?["urls"] as? [String] else { return }
        let urls = values.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingExternalURLs.append(contentsOf: urls)
            NSApp.activate(ignoringOtherApps: true)
            drainPendingExternalURLs()
        }
    }

    private func focusWindow(titled title: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func drainPendingExternalURLs() {
        guard runtime != nil, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        urls.forEach(routeExternalURL)
    }

    private func routeExternalURL(_ url: URL) {
        guard let runtime else { pendingExternalURLs.append(url); return }
        if runtime.receiveExternalURL(url) { return }
        switch DeepLinkRouter.destination(url: url) {
        case .conflict:
            openConflictsWindow()
        case .item:
            runtime.openItem(url: url)
        case .conflictItem(let itemIdentifier):
            openConflictsWindow()
            runtime.openConflict(itemIdentifier: itemIdentifier)
        case .reauthorize(let domainIdentifier):
            runtime.openReauthorize(domainIdentifier)
        case .task, .settings:
            openSettingsWindow()
        case nil:
            break
        }
    }
}

private struct OnboardingWindowContent: View {
    @ObservedObject var runtime: NimbusSyncAppState

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { runtime.pendingDomainSetup?.displayName ?? "" },
            set: { runtime.updatePendingDomainDisplayName($0) }
        )
    }

    var body: some View {
        if let setup = runtime.pendingDomainSetup {
            DomainSetupReviewView(
                displayName: displayNameBinding,
                remotePath: setup.remotePath,
                isWorking: runtime.isProvisioningDomain,
                errorMessage: runtime.onboardingError,
                onBack: runtime.cancelDomainSetup,
                onFinish: runtime.finishDomainSetup
            )
        } else {
            OnboardingView(
                isWorking: runtime.isAuthorizing,
                errorMessage: runtime.onboardingError,
                onCancel: runtime.cancelAuthorization,
                onContinue: runtime.addDomain
            )
        }
    }
}

private struct DomainSetupReviewView: View {
    @Binding var displayName: String
    let remotePath: String
    let isWorking: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add to Finder", systemImage: "externaldrive.badge.checkmark")
                .font(.title2)
            Text("Authorization succeeded. Confirm how this Domain appears on your Mac.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Domain name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Remote path")
                        .foregroundStyle(.secondary)
                    Text(remotePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Mac location")
                        .foregroundStyle(.secondary)
                    Text("Finder > Locations > \(displayName)")
                        .lineLimit(1)
                }
            }

            Text("macOS manages the local File Provider location. NimbusSync does not sync into an arbitrary local folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Back", action: onBack)
                    .disabled(isWorking)
                Spacer()
                if isWorking { ProgressView() }
                Button("Add to Finder", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct ConflictWindowContent: View {
    @ObservedObject var runtime: NimbusSyncAppState

    var body: some View {
        ConflictCenterView(
            conflicts: Binding(
                get: { runtime.snapshot.conflicts },
                set: { runtime.snapshot.conflicts = $0 }
            ),
            selectedItemIdentifier: runtime.selectedConflictItemIdentifier,
            onKeepRemote: runtime.keepRemote,
            onOverwriteRemote: runtime.prepareOverwriteRemote,
            onKeepBoth: runtime.prepareKeepBoth
        )
    }
}

private struct StatusPopoverContent: View {
    @ObservedObject var runtime: NimbusSyncAppState
    let onOpenSettings: () -> Void
    let onAddDomain: () -> Void
    let onOpenConflicts: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPopoverView(
                domains: runtime.snapshot.domains,
                tasks: runtime.snapshot.activeTasks.map { runtime.taskDisplay($0) },
                recentTasks: runtime.snapshot.taskProjection.recent.filter { task in
                    !runtime.snapshot.activeTasks.contains { active in active.id == task.id }
                }.map { runtime.taskDisplay($0) },
                hasActionableConflicts: !runtime.snapshot.actionableConflicts.isEmpty,
                onOpenSettings: onOpenSettings,
                onAddDomain: onAddDomain,
                onOpenConflicts: onOpenConflicts,
                onCancelTask: runtime.cancelTask,
                onRetryTask: runtime.retryTask
            )
            Divider()
            HStack {
                Button(action: onAddDomain) { Label("Add Domain", systemImage: "plus") }.buttonStyle(.borderless)
                Spacer()
                if !runtime.snapshot.actionableConflicts.isEmpty {
                    Button(action: onOpenConflicts) {
                        Label("Conflicts", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.borderless)
                }
                Button(role: .destructive, action: runtime.quitApplication) {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit NimbusSync")
                .help("Quit NimbusSync")
            }
            .padding(12)
        }
        .frame(width: 380)
    }
}

private struct PendingDomainSetup {
    var displayName: String
    let origin: URL
    let serverVersion: String?
    let iconURL: URL?
    let credential: Credential
    let scope: RemoteScope
    let remotePath: String
}

@MainActor
private final class NimbusSyncAppState: ObservableObject {
    @Published var snapshot = ProductSnapshot()
    @Published var isAuthorizing = false
    @Published var isProvisioningDomain = false
    @Published var onboardingError: String?
    @Published fileprivate var pendingDomainSetup: PendingDomainSetup?
    @Published var selectedConflictItemIdentifier: String?
    var onDomainProvisioned: ((DomainDescriptor) -> Void)?

    private let factory = AppGroupStoreFactory()
    private let registry: SQLiteStateStore?
    private let productStore: ProductStore
    private let oauth = OAuthAuthorizationSession()
    private let oauthLogger = Logger(subsystem: "ai.tiy.nimbussync", category: "oauth")
    private let heartbeat: HeartbeatCoordinator
    private let notifications: NotificationCoordinator
    private var started = false
    private var eventSupervisors: [String: EventSupervisor] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var eventRootURIs: [String: String] = [:]
    private var notificationAuthorizationRequested = false
    private var isQuitting = false
    private var terminationObserver: NSObjectProtocol?

    init() {
        registry = try? factory.registryStore()
        productStore = ProductStore(registry: registry, storeFactory: factory)
        heartbeat = HeartbeatCoordinator(store: registry, role: "app")
        notifications = NotificationCoordinator(preferences: productStore)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.markApplicationNotRunning() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
        Task { await notifications.configureCategories() }
        Task { [heartbeat] in
            while !Task.isCancelled {
                await heartbeat.beat()
                reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if let registry {
            let service = DomainRegistryService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
            Task { await service.recoverProvisioning(); reload() }
        }
    }

    func reload() {
        Task {
            let next = await productStore.snapshot()
            let previous = snapshot
            snapshot = next
            syncEventSupervisors(for: next.domains)
            await notifyChanges(from: previous, to: next)
        }
    }

    private func notifyChanges(from old: ProductSnapshot, to next: ProductSnapshot) async {
        let preferences = next.notificationPreferences
        guard preferences.enabled else { return }
        if preferences.authExpired, let domain = next.domains.first(where: { $0.status == .authExpired }), old.domains.first(where: { $0.identifier == domain.identifier })?.status != .authExpired {
            await ensureNotificationPermission()
            try? await notifications.notify(kind: "auth", opaqueID: domain.identifier, title: "Authorization required", body: domain.displayName, enabled: true)
        }
        if preferences.conflicts {
            for conflict in next.actionableConflicts where !old.actionableConflicts.contains(where: { $0.id == conflict.id }) {
                await ensureNotificationPermission()
                try? await notifications.notify(kind: "conflict", opaqueID: conflict.id.uuidString, title: "Conflict needs attention", body: conflict.filename, enabled: true)
            }
        }
        if preferences.permanentFailures {
            for task in next.tasks where task.state == .failed && !old.tasks.contains(where: { $0.id == task.id && $0.state == .failed }) {
                await ensureNotificationPermission()
                try? await notifications.notify(kind: "failure", opaqueID: task.id.uuidString, title: "Action required", body: task.title, enabled: true)
            }
        }
    }

    private func ensureNotificationPermission() async {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        _ = try? await notifications.requestAuthorizationIfNeeded()
    }

    private func syncEventSupervisors(for domains: [DomainDescriptor]) {
        let desired = Set(domains.map(\.identifier))
        for identifier in Array(eventSupervisors.keys) where !desired.contains(identifier) {
            eventTasks.removeValue(forKey: identifier)?.cancel()
            let supervisor = eventSupervisors.removeValue(forKey: identifier)
            eventRootURIs.removeValue(forKey: identifier)
            if let supervisor { Task { await supervisor.stop() } }
        }
        for descriptor in domains {
            if let supervisor = eventSupervisors[descriptor.identifier], eventRootURIs[descriptor.identifier] != descriptor.currentRootURI {
                eventTasks.removeValue(forKey: descriptor.identifier)?.cancel()
                eventSupervisors.removeValue(forKey: descriptor.identifier)
                eventRootURIs.removeValue(forKey: descriptor.identifier)
                Task { await supervisor.stop() }
            }
            guard eventSupervisors[descriptor.identifier] == nil else { continue }
            guard let origin = URL(string: descriptor.scope.origin), let store = try? factory.domainStore(identifier: descriptor.identifier), (try? KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()).read(reference: descriptor.secretReference)) != nil else { continue }
            let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
            guard let clientID = try? store.ensureEventClientID() else { continue }
            let streamFactory = CloudreveEventStreamFactory(origin: origin, uri: descriptor.currentRootURI, clientID: clientID, vault: vault, credentialReference: descriptor.secretReference)
            guard let runtime = DomainEventRuntime(descriptor: descriptor, store: store, registry: registry, vault: vault, onRootChanged: { [weak self, weak streamFactory] rootURI in
                await streamFactory?.update(uri: rootURI)
                await self?.reload()
            }) else { continue }
            let supervisor = EventSupervisor(factory: streamFactory, delegate: runtime)
            eventSupervisors[descriptor.identifier] = supervisor
            eventRootURIs[descriptor.identifier] = descriptor.currentRootURI
            eventTasks[descriptor.identifier] = Task { await supervisor.run() }
        }
    }

    func addDomain(origin rawOrigin: String) {
        guard !isAuthorizing, !isProvisioningDomain else { return }
        let correlationID = UUID()
        let correlation = correlationID.uuidString.lowercased()
        onboardingError = nil
        isAuthorizing = true
        oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.started")
        Task {
            var stage = "registry"
            do {
                guard registry != nil else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                stage = "site_validation"
                let site = try await SiteService().validate(origin: rawOrigin)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.site_validation.succeeded")
                let origin = site.origin
                stage = "authorization_callback"
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.waiting_for_callback")
                let authorization = try await oauth.authorize(origin: origin, correlationID: correlationID)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.callback_accepted")
                stage = "token_exchange"
                let credential = try await OAuthTokenExchange().exchange(origin: origin, callback: authorization.callback, verifier: authorization.verifier, correlationID: correlationID)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.token_exchange_succeeded")
                stage = "account_identity"
                let resolver = CloudreveIdentityResolver()
                let accountID = try await resolver.accountID(origin: origin, credential: credential)
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.account_identity_resolved")
                let requestedRoot = authorization.callback.remotePath?.isEmpty == false ? authorization.callback.remotePath! : "/"
                let scope = try RemoteScope(origin: origin.absoluteString, accountID: accountID, rootURI: requestedRoot)
                let name = authorization.callback.displayNameHint?.isEmpty == false ? authorization.callback.displayNameHint! : (site.title ?? origin.host ?? "Cloudreve")
                pendingDomainSetup = PendingDomainSetup(
                    displayName: name,
                    origin: origin,
                    serverVersion: site.serverVersion,
                    iconURL: site.iconURL,
                    credential: credential,
                    scope: scope,
                    remotePath: requestedRoot
                )
                onboardingError = nil
            } catch {
                logOAuthFailure(error, stage: stage, correlation: correlation)
                if error as? OAuthAuthorizationSessionError == .cancelled {
                    onboardingError = nil
                } else {
                    onboardingError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
            isAuthorizing = false
        }
    }

    func updatePendingDomainDisplayName(_ displayName: String) {
        pendingDomainSetup?.displayName = displayName
    }

    func finishDomainSetup() {
        guard !isProvisioningDomain, let setup = pendingDomainSetup, let registry else { return }
        isProvisioningDomain = true
        onboardingError = nil
        let correlation = UUID().uuidString.lowercased()
        Task {
            do {
                let resolver = CloudreveIdentityResolver()
                let rootURI = setup.scope.rootURI
                let service = DomainRegistryService(
                    store: registry,
                    vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()),
                    storeFactory: factory
                )
                let descriptor = try await service.provision(
                    displayName: setup.displayName,
                    scope: setup.scope,
                    credential: setup.credential,
                    capabilitySnapshot: CapabilitySnapshot(serverVersion: setup.serverVersion),
                    iconURL: setup.iconURL,
                    resolveIdentity: {
                        try await resolver.resolve(origin: setup.origin, credential: setup.credential, rootURI: rootURI)
                    },
                    firstRead: {
                        try await resolver.verifyFirstRead(origin: setup.origin, credential: setup.credential, rootURI: rootURI)
                    }
                )
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.provisioning_succeeded")
                pendingDomainSetup = nil
                reload()
                onDomainProvisioned?(descriptor)
            } catch {
                logOAuthFailure(error, stage: "domain_provisioning", correlation: correlation)
                onboardingError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            isProvisioningDomain = false
        }
    }

    func cancelDomainSetup() {
        guard !isProvisioningDomain else { return }
        oauth.cancel()
        pendingDomainSetup = nil
        onboardingError = nil
        isAuthorizing = false
    }

    @discardableResult
    func receiveExternalURL(_ url: URL) -> Bool {
        let scheme = url.scheme ?? "missing"
        let host = url.host ?? "missing"
        oauthLogger.info("oauth.external_url.received scheme=\(scheme, privacy: .public) host=\(host, privacy: .public) path=\(url.path, privacy: .public)")
        return oauth.receiveCallback(url)
    }

    func cancelAuthorization() {
        oauth.cancel()
    }

    func quitApplication() {
        guard !isQuitting else { return }
        isQuitting = true
        oauth.cancel()
        Task {
            await markApplicationNotRunning()
            NSApplication.shared.terminate(nil)
        }
    }

    private func logOAuthFailure(_ error: Error, stage: String, correlation: String) {
        if let failure = error as? CoreFailure {
            oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) core_code=\(failure.code.rawValue, privacy: .public) retryable=\(failure.retryable, privacy: .public)")
            return
        }
        let nsError = error as NSError
        oauthLogger.error("[\(correlation, privacy: .public)] oauth.add_domain.failed stage=\(stage, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)")
    }

    func keepRemote(_ conflict: ProductConflict) {
        Task {
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }), let domainStore = try? factory.domainStore(identifier: domain.identifier), let item = try domainStore.item(identifier: conflict.itemIdentifier), let origin = URL(string: domain.scope.origin) else { throw CoreFailure(code: .notFound, retryable: false) }
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let backend = NimbusSyncRemoteBackend(origin: origin, rootURI: domain.currentRootURI, store: domainStore, vault: vault, credentialReference: domain.secretReference, capabilitySnapshot: domain.capabilitySnapshot, providerName: domain.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current()))
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: item.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: nil, sourceGeneration: 0, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion)
                _ = try ConflictResolutionService(store: domainStore, backend: backend).keepRemote(conflict: projection)
                let systemDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain.identifier), displayName: domain.displayName)
                if let manager = NSFileProviderManager(for: systemDomain) {
                    try? await manager.signalEnumerator(for: .workingSet)
                    try? await manager.reimportItems(below: NSFileProviderItemIdentifier(item.itemIdentifier))
                }
                reload()
            } catch { onboardingError = String(describing: error) }
        }
    }

    func prepareOverwriteRemote(_ conflict: ProductConflict) {
        prepareConflictResolution(conflict, resolution: .overwriteRemote)
    }

    func prepareKeepBoth(_ conflict: ProductConflict) {
        prepareConflictResolution(conflict, resolution: .keepBoth)
    }

    private func prepareConflictResolution(_ conflict: ProductConflict, resolution: ConflictResolutionAction) {
        Task {
            do {
                guard let domain = snapshot.domains.first(where: { $0.identifier == conflict.domainIdentifier }),
                      let domainStore = try? factory.domainStore(identifier: domain.identifier),
                      let origin = URL(string: domain.scope.origin) else { throw CoreFailure(code: .notFound, retryable: false) }
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let backend = NimbusSyncRemoteBackend(origin: origin, rootURI: domain.currentRootURI, store: domainStore, vault: vault, credentialReference: domain.secretReference, capabilitySnapshot: domain.capabilitySnapshot, providerName: domain.capabilitySnapshot.providers.first?.name ?? "unverified", secretVault: KeychainOpaqueSecretVault(accessGroup: KeychainAccessGroup.current()))
                let projection = ConflictProjection(conflictID: conflict.id, itemIdentifier: conflict.itemIdentifier, kind: conflict.kind, baseSummary: conflict.baseSummary, remoteSummary: conflict.remoteSummary, localSummary: conflict.localSummary, pendingItemIdentifier: conflict.itemIdentifier, sourceGeneration: 0, createdAt: conflict.createdAt, remoteVersion: conflict.remoteVersion)
                let service = ConflictResolutionService(store: domainStore, backend: backend)
                switch resolution {
                case .overwriteRemote: try service.prepareOverwriteRemote(conflict: projection)
                case .keepBoth: try service.prepareKeepBoth(conflict: projection)
                case .keepRemote: break
                }
                let systemDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain.identifier), displayName: domain.displayName)
                if let manager = NSFileProviderManager(for: systemDomain) { try? await manager.signalEnumerator(for: .workingSet) }
                reload()
            } catch { onboardingError = String(describing: error) }
        }
    }


    func openItem(url: URL) {
        guard case let .item(itemIdentifier) = DeepLinkRouter.destination(url: url) else { return }
        for domain in snapshot.domains {
            guard let store = try? factory.domainStore(identifier: domain.identifier) else { continue }
            let item: RemoteItem?
            do { item = try store.item(identifier: itemIdentifier) } catch { continue }
            guard let item, let origin = URL(string: domain.scope.origin), var components = URLComponents(url: origin.appendingPathComponent("home"), resolvingAgainstBaseURL: false) else { continue }
            let folderURI = item.kind == .folder ? item.uri : (item.parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? domain.scope.rootURI : item.uri)
            let openURI = item.kind == .folder ? nil : item.uri
            components.queryItems = [URLQueryItem(name: "path", value: folderURI), URLQueryItem(name: "open", value: openURI)]
            guard let target = components.url else { continue }
            NSWorkspace.shared.open(target)
            return
        }
    }

    func openFinder(domain: DomainDescriptor) {
        let systemDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain.identifier), displayName: domain.displayName)
        guard let manager = NSFileProviderManager(for: systemDomain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, _ in
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    func openWeb(domain: DomainDescriptor) {
        guard let url = URL(string: domain.scope.origin) else { return }
        NSWorkspace.shared.open(url)
    }

    func removeDomain(_ domain: DomainDescriptor) {
        Task {
            do {
                guard let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let service = SafeDomainRemovalService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
                _ = try await service.remove(descriptor: domain)
                reload()
            } catch { onboardingError = String(describing: error) }
        }
    }

    func reauthorize(_ domain: DomainDescriptor) {
        Task {
            do {
                guard let origin = URL(string: domain.scope.origin), let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
                let site = try await SiteService().validate(origin: domain.scope.origin)
                let authorization = try await oauth.authorize(origin: origin)
                let exchanged = try await OAuthTokenExchange().exchange(origin: origin, callback: authorization.callback, verifier: authorization.verifier)
                let vault = KeychainCredentialVault(accessGroup: KeychainAccessGroup.current())
                let resolver = CloudreveIdentityResolver()
                let identity = try await resolver.resolve(origin: origin, credential: exchanged, rootURI: domain.currentRootURI)
                guard identity.accountID == domain.accountID, identity.rootRemoteID == domain.rootRemoteID else { throw DomainProvisioningError.accountMismatch }
                let previousGeneration = (try vault.read(reference: domain.secretReference)?.generation ?? 0)
                let credential = Credential(accessToken: exchanged.accessToken, refreshToken: exchanged.refreshToken, accessExpiry: exchanged.accessExpiry, refreshExpiry: exchanged.refreshExpiry, generation: previousGeneration + 1)
                try vault.write(credential, reference: domain.secretReference)
                try registry.setDomainStatus(identifier: domain.identifier, status: .reconciling)
                await resetEventSupervisor(domainIdentifier: domain.identifier)
                _ = site
                reload()
            } catch { onboardingError = String(describing: error) }
        }
    }

    func openReauthorize(_ domainIdentifier: String) {
        guard let domain = snapshot.domains.first(where: { $0.identifier == domainIdentifier }) else { return }
        reauthorize(domain)
    }

    func openConflict(itemIdentifier: String) {
        selectedConflictItemIdentifier = itemIdentifier
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        Task {
            var preferences = await productStore.snapshot().notificationPreferences
            preferences.enabled = enabled
            try? await productStore.saveNotificationPreferences(preferences)
            reload()
        }
    }

    func setNotificationPreferences(_ preferences: NotificationPreferences) {
        Task {
            try? await productStore.saveNotificationPreferences(preferences)
            reload()
        }
    }

    func cancelTask(_ taskID: UUID) {
        Task {
            try? await productStore.cancelTask(taskID)
            reload()
        }
    }

    func retryTask(_ taskID: UUID) {
        Task {
            try? await productStore.retryTask(taskID)
            reload()
        }
    }

    func taskDisplay(_ task: ProductTask) -> TaskDisplay {
        let state = task.errorCode == nil ? task.state.rawValue : (task.errorCode == "unknown_outcome" || task.errorCode == "version_conflict" || task.errorCode == "authentication_required" ? "action_required" : task.state.rawValue)
        return TaskDisplay(id: task.id, title: task.title, progress: task.progress, detail: task.errorCode ?? task.state.rawValue, state: state)
    }

    private func resetEventSupervisor(domainIdentifier: String) async {
        eventTasks.removeValue(forKey: domainIdentifier)?.cancel()
        if let supervisor = eventSupervisors.removeValue(forKey: domainIdentifier) {
            await supervisor.stop()
        }
        eventRootURIs.removeValue(forKey: domainIdentifier)
    }

    private func markApplicationNotRunning() async {
        await heartbeat.markQuit()
        for domain in snapshot.domains {
            try? registry?.setDomainStatus(identifier: domain.identifier, status: .appNotRunning)
            if let store = try? factory.domainStore(identifier: domain.identifier) {
                try? store.setDomainStatus(identifier: domain.identifier, status: .appNotRunning)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case domains
    case general
    case notifications
    case diagnostics
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .domains: "Domains"
        case .general: "General"
        case .notifications: "Notifications"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .domains: "externaldrive"
        case .general: "gearshape"
        case .notifications: "bell"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

private struct SettingsView: View {
    let domains: [DomainDescriptor]
    let onOpenFinder: (DomainDescriptor) -> Void
    let onRemove: (DomainDescriptor) -> Void
    let onOpenWeb: (DomainDescriptor) -> Void
    let onReauthorize: (DomainDescriptor) -> Void
    let onNotificationsChanged: (NotificationPreferences) -> Void
    let onAddDomain: () -> Void
    @State private var selectedSection: SettingsSection = .domains
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationPreferences: NotificationPreferences
    @State private var pendingRemoval: DomainDescriptor?

    init(domains: [DomainDescriptor], notificationPreferences: NotificationPreferences, onOpenFinder: @escaping (DomainDescriptor) -> Void, onRemove: @escaping (DomainDescriptor) -> Void, onOpenWeb: @escaping (DomainDescriptor) -> Void, onReauthorize: @escaping (DomainDescriptor) -> Void, onNotificationsChanged: @escaping (NotificationPreferences) -> Void, onAddDomain: @escaping () -> Void) {
        self.domains = domains
        self.onOpenFinder = onOpenFinder
        self.onRemove = onRemove
        self.onOpenWeb = onOpenWeb
        self.onReauthorize = onReauthorize
        self.onNotificationsChanged = onNotificationsChanged
        self.onAddDomain = onAddDomain
        _notificationPreferences = State(initialValue: notificationPreferences)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("NimbusSync")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            detailView
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 600)
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "domain")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { domain in
            Button("Remove", role: .destructive) { onRemove(domain); pendingRemoval = nil }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Remote files will not be deleted. Dirty local data may be preserved by File Provider.")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .domains:
            SettingsPage(title: "Domains", description: "Manage the Cloudreve domains available in Finder.") {
                Section("Connected domains") {
                    if domains.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("No domains configured", systemImage: "externaldrive.badge.plus")
                                .font(.headline)
                            Text("Add a Cloudreve domain to make it available in Finder.")
                                .foregroundStyle(.secondary)
                            Button(action: onAddDomain) {
                                Label("Add Domain", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(domains, id: \.identifier) { domain in
                            domainRow(domain)
                        }
                    }
                }
            }
        case .general:
            SettingsPage(title: "General", description: "Control how NimbusSync starts and runs in the background.") {
                Section("Startup") {
                    Toggle("Launch NimbusSync at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                        launchAtLogin = enabled
                        try? (enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                    }))
                }
            }
        case .notifications:
            SettingsPage(title: "Notifications", description: "Choose which sync events should notify you.") {
                Section("Delivery") {
                    Toggle("Allow notifications", isOn: notificationBinding(\.enabled))
                }
                Section("Alert types") {
                    Toggle("Authorization required", isOn: notificationBinding(\.authExpired))
                    Toggle("Conflicts", isOn: notificationBinding(\.conflicts))
                    Toggle("Permanent failures", isOn: notificationBinding(\.permanentFailures))
                }
                .disabled(!notificationPreferences.enabled)
            }
        case .diagnostics:
            SettingsPage(title: "Diagnostics", description: "Review the current local integration state.") {
                Section("Status") {
                    LabeledContent("Configured domains", value: "\(domains.count)")
                    LabeledContent("Application mode", value: "Menu bar")
                }
                Section("Support") {
                    Text("Unsupported capabilities remain read-only until verified for this server and storage provider.")
                        .foregroundStyle(.secondary)
                }
            }
        case .about:
            SettingsPage(title: "About", description: "NimbusSync keeps your Cloudreve files available in Finder.") {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NimbusSync").font(.headline)
                            Text("Cloudreve for macOS").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                }
            }
        }
    }

    @ViewBuilder
    private func domainRow(_ domain: DomainDescriptor) -> some View {
        HStack(spacing: 12) {
            if let iconURL = domain.iconURL {
                AsyncImage(url: iconURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "externaldrive")
                }
                .frame(width: 24, height: 24)
            } else {
                Image(systemName: "externaldrive")
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(domain.displayName)
                Text(domain.scope.origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            StatusBadge(status: domain.status)
            HStack(spacing: 8) {
                Button { onOpenFinder(domain) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Open in Finder")
                Button { onOpenWeb(domain) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open Cloudreve")
                Button { onReauthorize(domain) } label: { Image(systemName: "person.crop.circle.badge.checkmark") }
                    .buttonStyle(.borderless)
                    .help("Reauthorize")
                Button { pendingRemoval = domain } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove domain")
            }
        }
        .padding(.vertical, 4)
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { notificationPreferences[keyPath: keyPath] },
            set: { enabled in
                notificationPreferences[keyPath: keyPath] = enabled
                onNotificationsChanged(notificationPreferences)
            }
        )
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: () -> Content

    init(title: String, description: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form(content: content)
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
