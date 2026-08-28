import SwiftUI
import Combine
import AppKit
import CloudreveDomainKit

public struct OnboardingView: View {
    @State private var origin = ""
    @FocusState private var originFieldIsFocused: Bool
    public let onContinue: (String) -> Void
    public let onCancel: () -> Void
    public let isWorking: Bool
    public let errorMessage: String?
    public init(isWorking: Bool = false, errorMessage: String? = nil, onCancel: @escaping () -> Void = {}, onContinue: @escaping (String) -> Void) { self.isWorking = isWorking; self.errorMessage = errorMessage; self.onCancel = onCancel; self.onContinue = onContinue }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
			Label("NimbusSync", systemImage: "externaldrive").font(.title2)
            Text("Connect a Cloudreve domain to use it in Finder.").foregroundStyle(.secondary)
            TextField("Cloudreve URL", text: $origin)
                .textFieldStyle(.roundedBorder)
                .focused($originFieldIsFocused)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel", action: onCancel).buttonStyle(.bordered)
                }
                Button("Continue") { onContinue(origin) }.buttonStyle(.borderedProminent).disabled(origin.isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 480)
        .tint(Color(red: 5 / 255, green: 111 / 255, blue: 238 / 255))
        .accessibilityElement(children: .contain)
        .onAppear(perform: focusOriginField)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Welcome to NimbusSync" else { return }
            focusOriginField()
        }
    }

    private func focusOriginField() {
        originFieldIsFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            originFieldIsFocused = true
        }
    }
}

public struct ConflictCenterView: View {
    @Binding public var conflicts: [ProductConflict]
    public let onKeepRemote: (ProductConflict) -> Void
    public let onOverwriteRemote: (ProductConflict) -> Void
    public let onKeepBoth: (ProductConflict) -> Void
    public let selectedItemIdentifier: String?
    @State private var selectedID: UUID?
    public init(conflicts: Binding<[ProductConflict]>, selectedItemIdentifier: String? = nil, onKeepRemote: @escaping (ProductConflict) -> Void, onOverwriteRemote: @escaping (ProductConflict) -> Void, onKeepBoth: @escaping (ProductConflict) -> Void) { _conflicts = conflicts; self.selectedItemIdentifier = selectedItemIdentifier; self.onKeepRemote = onKeepRemote; self.onOverwriteRemote = onOverwriteRemote; self.onKeepBoth = onKeepBoth; _selectedID = State(initialValue: conflicts.wrappedValue.first(where: { $0.itemIdentifier == selectedItemIdentifier })?.id) }
    public var body: some View {
        NavigationSplitView {
            List(conflicts.filter { $0.state == "pending" }, selection: $selectedID) { conflict in
                VStack(alignment: .leading) { Text(conflict.filename); Text(conflict.kind).font(.caption).foregroundStyle(.secondary) }
                    .tag(conflict.id)
            }
            .navigationTitle("Conflicts")
        } detail: {
            if let first = conflicts.first(where: { $0.id == selectedID }) ?? conflicts.first(where: { $0.state == "pending" }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(first.filename).font(.title2)
                    Text("Base: \(first.baseSummary)").font(.caption).foregroundStyle(.secondary)
                    Text("Local: \(first.localSummary)")
                    Text("Remote: \(first.remoteSummary)")
                    HStack {
                        Button("Keep Remote") { onKeepRemote(first) }.buttonStyle(.bordered)
                        Button("Overwrite Remote") { onOverwriteRemote(first) }.buttonStyle(.bordered)
                        Button("Keep Both") { onKeepBoth(first) }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }.padding(24)
            } else { Text("No conflicts need attention.").foregroundStyle(.secondary) }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onReceive(Just(selectedItemIdentifier)) { itemIdentifier in
            selectedID = conflicts.first(where: { $0.itemIdentifier == itemIdentifier })?.id
        }
    }
}

public struct ExclusionRulesView: View {
    @State private var text: String
    public let onApply: (String) -> Void
    public init(initialText: String = "", onApply: @escaping (String) -> Void) { _text = State(initialValue: initialText); self.onApply = onApply }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclude from this Mac").font(.title3)
            Text("One pattern per line. Remote files remain on Cloudreve.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack { Spacer(); Button("Apply") { onApply(text) }.buttonStyle(.borderedProminent) }
        }.padding(20)
    }
}
