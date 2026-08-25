import SwiftUI
import CloudreveDomainKit

public struct OnboardingView: View {
    @State private var origin = ""
    public let onContinue: (String) -> Void
    public init(onContinue: @escaping (String) -> Void) { self.onContinue = onContinue }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Cloudreve", systemImage: "externaldrive").font(.title2)
            Text("Connect a Cloudreve domain to use it in Finder.").foregroundStyle(.secondary)
            TextField("Cloudreve URL", text: $origin).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Continue") { onContinue(origin) }.buttonStyle(.borderedProminent).disabled(origin.isEmpty) }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
    }
}

public struct ConflictCenterView: View {
    @Binding public var conflicts: [ProductConflict]
    public let onResolve: (ProductConflict) -> Void
    public init(conflicts: Binding<[ProductConflict]>, onResolve: @escaping (ProductConflict) -> Void) { _conflicts = conflicts; self.onResolve = onResolve }
    public var body: some View {
        NavigationSplitView {
            List(conflicts.filter { $0.state == "pending" }) { conflict in
                VStack(alignment: .leading) { Text(conflict.filename); Text(conflict.kind).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Conflicts")
        } detail: {
            if let first = conflicts.first(where: { $0.state == "pending" }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(first.filename).font(.title2)
                    Text("Local: \(first.localSummary)")
                    Text("Remote: \(first.remoteSummary)")
                    HStack {
                        Button("Keep Remote") { onResolve(first) }.buttonStyle(.bordered)
                        Button("Keep Both") { onResolve(first) }.buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }.padding(24)
            } else { Text("No conflicts need attention.").foregroundStyle(.secondary) }
        }
        .frame(minWidth: 640, minHeight: 460)
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

