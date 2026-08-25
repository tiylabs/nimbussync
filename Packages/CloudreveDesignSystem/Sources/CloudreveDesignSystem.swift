import SwiftUI
import CloudreveDomainKit

public enum CloudreveDesignTokens {
    public static let spacing4: CGFloat = 4
    public static let spacing8: CGFloat = 8
    public static let spacing12: CGFloat = 12
    public static let spacing16: CGFloat = 16
    public static let cornerRadius: CGFloat = 8
}

public struct StatusBadge: View {
    public let status: DomainStatus
    public init(status: DomainStatus) { self.status = status }
    public var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.tint)
            .accessibilityLabel(Text(status.title))
    }
}

public struct TaskProgressRow: View {
    public let title: String
    public let progress: Double?
    public let detail: String
    public init(title: String, progress: Double?, detail: String) { self.title = title; self.progress = progress; self.detail = detail }
    public var body: some View {
        VStack(alignment: .leading, spacing: CloudreveDesignTokens.spacing4) {
            HStack {
                Image(systemName: "doc")
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: CloudreveDesignTokens.spacing8)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let progress { ProgressView(value: progress).accessibilityValue(Text("\(Int(progress * 100))%")) } else { ProgressView().progressViewStyle(.linear) }
        }
        .padding(.vertical, CloudreveDesignTokens.spacing4)
    }
}

public struct MenuBarPopoverView: View {
    public let domains: [DomainDescriptor]
    public let tasks: [(String, Double?, String)]
    public init(domains: [DomainDescriptor], tasks: [(String, Double?, String)] = []) { self.domains = domains; self.tasks = tasks }
    public var body: some View {
        VStack(alignment: .leading, spacing: CloudreveDesignTokens.spacing12) {
            HStack {
                Text("Cloudreve").font(.headline)
                Spacer()
                Button(action: {}) { Image(systemName: "gearshape") }.buttonStyle(.borderless).accessibilityLabel(Text("Settings"))
                Button(action: {}) { Image(systemName: "plus") }.buttonStyle(.borderless).accessibilityLabel(Text("Add domain"))
            }
            if domains.isEmpty {
                VStack(spacing: CloudreveDesignTokens.spacing8) {
                    Image(systemName: "externaldrive.badge.plus").font(.title2).accessibilityHidden(true)
                    Text("No domains").font(.headline)
                    Text("Add a Cloudreve domain to use Finder.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CloudreveDesignTokens.spacing16)
            } else {
                ForEach(domains, id: \.identifier) { domain in
                    HStack { Image(systemName: "externaldrive"); Text(domain.displayName); Spacer(); StatusBadge(status: domain.status) }
                }
            }
            if !tasks.isEmpty {
                Divider()
                Text("Active tasks").font(.subheadline)
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in TaskProgressRow(title: task.0, progress: task.1, detail: task.2) }
            }
        }
        .padding(CloudreveDesignTokens.spacing16)
        .frame(minWidth: 360, maxWidth: 380)
    }
}

private extension DomainStatus {
    var title: String {
        switch self { case .healthy: "Up to date"; case .syncing: "Syncing"; case .reconciling: "Checking for updates"; case .offline: "Offline"; case .eventDegraded: "Live updates unavailable"; case .appNotRunning: "Live updates paused"; case .authExpired: "Authorization required"; case .rootUnavailable: "Remote root unavailable"; case .scopeConflict: "Domain scope conflict"; case .conflict: "Conflicts need attention"; case .permanentError: "Action required"; default: "Preparing" }
    }
    var symbol: String { switch self { case .healthy: "checkmark.circle"; case .offline: "wifi.slash"; case .authExpired: "person.crop.circle.badge.exclamationmark"; case .conflict: "exclamationmark.triangle"; default: "arrow.triangle.2.circlepath" } }
    var tint: Color { switch self { case .healthy: .green; case .authExpired, .conflict, .permanentError, .rootUnavailable, .scopeConflict: .orange; case .offline: .secondary; default: .accentColor } }
}
