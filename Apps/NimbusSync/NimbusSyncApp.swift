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
    @Environment(\.openWindow) private var openWindow
    @StateObject private var runtime: NimbusSyncAppState

    init() {
        let runtime = NimbusSyncAppState()
        _runtime = StateObject(wrappedValue: runtime)
        runtime.start()
    }

    var body: some Scene {
        let _ = appDelegate.configure(
            runtime: runtime,
            openOnboarding: { openWindow(id: "onboarding") },
            openConflicts: { openWindow(id: "conflicts") }
        )

        Settings {
            SettingsView(domains: runtime.snapshot.domains, notificationPreferences: runtime.snapshot.notificationPreferences, onOpenFinder: runtime.openFinder, onRemove: runtime.removeDomain, onOpenWeb: runtime.openWeb, onReauthorize: runtime.reauthorize, onNotificationsChanged: runtime.setNotificationPreferences)
        }

        Window("Welcome to NimbusSync", id: "onboarding") {
            OnboardingView(isWorking: runtime.isAuthorizing, errorMessage: runtime.onboardingError, onCancel: runtime.cancelAuthorization) { origin in
                runtime.addDomain(origin: origin)
            }
        }
        .windowResizability(.contentSize)

        Window("Conflicts", id: "conflicts") {
            ConflictCenterView(conflicts: Binding(get: { runtime.snapshot.conflicts }, set: { runtime.snapshot.conflicts = $0 }), selectedItemIdentifier: runtime.selectedConflictItemIdentifier, onKeepRemote: runtime.keepRemote, onOverwriteRemote: runtime.prepareOverwriteRemote, onKeepBoth: runtime.prepareKeepBoth)
        }
    }
}

@MainActor
private final class NimbusSyncAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private weak var runtime: NimbusSyncAppState?
    private var openOnboarding: (() -> Void)?
    private var openConflicts: (() -> Void)?
    private var pendingExternalURLs: [URL] = []
    private var didFinishLaunching = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func configure(runtime: NimbusSyncAppState, openOnboarding: @escaping () -> Void, openConflicts: @escaping () -> Void) {
        self.runtime = runtime
        self.openOnboarding = openOnboarding
        self.openConflicts = openConflicts
        guard didFinishLaunching else { return }
        installStatusItemIfNeeded()
        drainPendingExternalURLs()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        didFinishLaunching = true
        installStatusItemIfNeeded()
        drainPendingExternalURLs()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard runtime != nil else {
            pendingExternalURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(routeExternalURL)
        application.activate(ignoringOtherApps: true)
        application.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil, let runtime else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NimbusSync")
        button.imagePosition = .imageOnly
        button.toolTip = "NimbusSync"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let content = StatusPopoverContent(
            runtime: runtime,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onAddDomain: { [weak self] in self?.openOnboardingWindow() },
            onOpenConflicts: { [weak self] in self?.openConflictsWindow() }
        )
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit NimbusSync", action: #selector(quitFromStatusMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: quitItem, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func quitFromStatusMenu(_ sender: Any?) {
        runtime?.quitApplication()
    }

    private func openSettings() {
        popover.performClose(nil)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func openOnboardingWindow() {
        popover.performClose(nil)
        openOnboarding?()
    }

    private func openConflictsWindow() {
        popover.performClose(nil)
        openConflicts?()
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
            openSettings()
        case nil:
            break
        }
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
                Button(action: onOpenConflicts) { Label("Conflicts", systemImage: "exclamationmark.triangle") }.buttonStyle(.borderless).disabled(runtime.snapshot.actionableConflicts.isEmpty)
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

@MainActor
private final class NimbusSyncAppState: ObservableObject {
    @Published var snapshot = ProductSnapshot()
    @Published var isAuthorizing = false
    @Published var onboardingError: String?
    @Published var selectedConflictItemIdentifier: String?

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
        guard !isAuthorizing else { return }
        let correlationID = UUID()
        let correlation = correlationID.uuidString.lowercased()
        onboardingError = nil
        isAuthorizing = true
        oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.started")
        Task {
            var stage = "registry"
            do {
                guard let registry else { throw StoreBridgeError.openFailed("App Group is unavailable") }
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
                let rootURI = scope.rootURI
                let registryService = DomainRegistryService(store: registry, vault: KeychainCredentialVault(accessGroup: KeychainAccessGroup.current()), storeFactory: factory)
                let name = authorization.callback.displayNameHint?.isEmpty == false ? authorization.callback.displayNameHint! : (site.title ?? origin.host ?? "Cloudreve")
                stage = "domain_provisioning"
                _ = try await registryService.provision(displayName: name, scope: scope, credential: credential, capabilitySnapshot: CapabilitySnapshot(serverVersion: site.serverVersion), iconURL: site.iconURL, resolveIdentity: {
                    try await resolver.resolve(origin: origin, credential: credential, rootURI: rootURI)
                }, firstRead: {
                    try await resolver.verifyFirstRead(origin: origin, credential: credential, rootURI: rootURI)
                })
                oauthLogger.info("[\(correlation, privacy: .public)] oauth.add_domain.provisioning_succeeded")
                onboardingError = nil
                reload()
            } catch {
                logOAuthFailure(error, stage: stage, correlation: correlation)
                onboardingError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            isAuthorizing = false
        }
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

private struct SettingsView: View {
    let domains: [DomainDescriptor]
    let onOpenFinder: (DomainDescriptor) -> Void
    let onRemove: (DomainDescriptor) -> Void
    let onOpenWeb: (DomainDescriptor) -> Void
    let onReauthorize: (DomainDescriptor) -> Void
    let onNotificationsChanged: (NotificationPreferences) -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationPreferences: NotificationPreferences
    @State private var pendingRemoval: DomainDescriptor?

    init(domains: [DomainDescriptor], notificationPreferences: NotificationPreferences, onOpenFinder: @escaping (DomainDescriptor) -> Void, onRemove: @escaping (DomainDescriptor) -> Void, onOpenWeb: @escaping (DomainDescriptor) -> Void, onReauthorize: @escaping (DomainDescriptor) -> Void, onNotificationsChanged: @escaping (NotificationPreferences) -> Void) {
        self.domains = domains; self.onOpenFinder = onOpenFinder; self.onRemove = onRemove; self.onOpenWeb = onOpenWeb; self.onReauthorize = onReauthorize; self.onNotificationsChanged = onNotificationsChanged
        _notificationPreferences = State(initialValue: notificationPreferences)
    }

    var body: some View {
        NavigationSplitView {
            List {
                Label("Domains", systemImage: "externaldrive")
                Label("General", systemImage: "gearshape")
                Label("Notifications", systemImage: "bell")
                Label("Diagnostics", systemImage: "stethoscope")
                Label("About", systemImage: "info.circle")
            }
			.navigationTitle("NimbusSync")
        } detail: {
            Form {
                Section("Domains") {
                    if domains.isEmpty { Text("No domains configured.").foregroundStyle(.secondary) }
                    ForEach(domains, id: \.identifier) { domain in
                        HStack {
                            if let iconURL = domain.iconURL {
                                AsyncImage(url: iconURL) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Image(systemName: "externaldrive")
                                }
                                .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "externaldrive")
                            }
                            VStack(alignment: .leading) { Text(domain.displayName); Text(domain.scope.origin).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            StatusBadge(status: domain.status)
                            Button { onOpenFinder(domain) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Open in Finder")
                            Button { onOpenWeb(domain) } label: { Image(systemName: "safari") }.buttonStyle(.borderless).help("Open Cloudreve")
                            Button { onReauthorize(domain) } label: { Image(systemName: "person.crop.circle.badge.checkmark") }.buttonStyle(.borderless).help("Reauthorize")
                            Button { pendingRemoval = domain } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove domain")
                        }
                    }
                }
                Section("General") {
                    Toggle("Launch NimbusSync at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                        launchAtLogin = enabled
                        try? (enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                    }))
                    Toggle("Notifications", isOn: Binding(get: { notificationPreferences.enabled }, set: { enabled in
                        notificationPreferences.enabled = enabled
                        onNotificationsChanged(notificationPreferences)
                    }))
                    Toggle("Authorization", isOn: Binding(get: { notificationPreferences.authExpired }, set: { enabled in
                        notificationPreferences.authExpired = enabled
                        onNotificationsChanged(notificationPreferences)
                    }))
                    Toggle("Conflicts", isOn: Binding(get: { notificationPreferences.conflicts }, set: { enabled in
                        notificationPreferences.conflicts = enabled
                        onNotificationsChanged(notificationPreferences)
                    }))
                    Toggle("Permanent failures", isOn: Binding(get: { notificationPreferences.permanentFailures }, set: { enabled in
                        notificationPreferences.permanentFailures = enabled
                        onNotificationsChanged(notificationPreferences)
                    }))
                }
                Section("Support") {
					Text("Unsupported capabilities remain read-only until verified for this server and storage provider.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: 640, minHeight: 460)
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "domain")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { domain in
            Button("Remove", role: .destructive) { onRemove(domain); pendingRemoval = nil }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Remote files will not be deleted. Dirty local data may be preserved by File Provider.")
        }
    }
}
