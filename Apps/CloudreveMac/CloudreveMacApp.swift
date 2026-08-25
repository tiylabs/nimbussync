import SwiftUI
import Combine
import CloudreveDesignSystem
import CloudreveDomainKit
import CloudreveProductKit
import CloudreveEventCoordinator
import ServiceManagement

@main
struct CloudreveMacApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var domains: [DomainDescriptor] = []
    @State private var conflicts: [ProductConflict] = []

    var body: some Scene {
        MenuBarExtra("Cloudreve", systemImage: "externaldrive") {
            VStack(spacing: 0) {
                MenuBarPopoverView(domains: domains, tasks: [])
                Divider()
                HStack {
                    Button(action: { openWindow(id: "onboarding") }) { Label("Add Domain", systemImage: "plus") }.buttonStyle(.borderless)
                    Spacer()
                    Button(action: { openWindow(id: "conflicts") }) { Label("Conflicts", systemImage: "exclamationmark.triangle") }.buttonStyle(.borderless).disabled(conflicts.isEmpty)
                }.padding(12)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(domains: domains)
        }

        Window("Welcome to Cloudreve", id: "onboarding") {
            OnboardingView { _ in }
        }
        .windowResizability(.contentSize)

        Window("Conflicts", id: "conflicts") {
            ConflictCenterView(conflicts: $conflicts) { conflict in
                conflicts.removeAll { $0.id == conflict.id }
            }
        }
    }
}

private struct SettingsView: View {
    let domains: [DomainDescriptor]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationsEnabled = true

    var body: some View {
        NavigationSplitView {
            List {
                Label("Domains", systemImage: "externaldrive")
                Label("General", systemImage: "gearshape")
                Label("Notifications", systemImage: "bell")
                Label("Diagnostics", systemImage: "stethoscope")
                Label("About", systemImage: "info.circle")
            }
            .navigationTitle("Cloudreve")
        } detail: {
            Form {
                Section("Domains") {
                    if domains.isEmpty { Text("No domains configured.").foregroundStyle(.secondary) }
                    ForEach(domains, id: \.identifier) { domain in
                        HStack { Image(systemName: "externaldrive"); VStack(alignment: .leading) { Text(domain.displayName); Text(domain.scope.origin).font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusBadge(status: domain.status) }
                    }
                }
                Section("General") {
                    Toggle("Launch Cloudreve at login", isOn: $launchAtLogin)
                        .onReceive(Just(launchAtLogin).dropFirst()) { enabled in try? (enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
                    Toggle("Notifications", isOn: $notificationsEnabled)
                }
                Section("Support") {
                    Text("Unsupported capabilities remain read-only until verified for this Cloudreve server and storage provider.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}
