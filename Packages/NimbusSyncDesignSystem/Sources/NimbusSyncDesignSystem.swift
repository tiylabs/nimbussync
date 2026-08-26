import SwiftUI
import CloudreveDomainKit

public struct TaskDisplay: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let progress: Double?
    public let detail: String
    public let state: String
    public init(id: UUID, title: String, progress: Double?, detail: String, state: String) { self.id = id; self.title = title; self.progress = progress; self.detail = detail; self.state = state }
}

public enum NimbusSyncDesignTokens {
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
    public let state: String?
    public let onCancel: (() -> Void)?
    public let onRetry: (() -> Void)?
    public init(title: String, progress: Double?, detail: String, state: String? = nil, onCancel: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) { self.title = title; self.progress = progress; self.detail = detail; self.state = state; self.onCancel = onCancel; self.onRetry = onRetry }
    public var body: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing4) {
            HStack {
                Image(systemName: "doc")
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Spacer(minLength: NimbusSyncDesignTokens.spacing8)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let state, ["queued", "running", "retrying", "failed"].contains(state) {
                    if ["retrying", "failed"].contains(state) {
                        Button(action: { onRetry?() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Retry")
                    } else {
                        Button(action: { onCancel?() }) { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Cancel")
                    }
                }
            }
            if let progress { ProgressView(value: progress).accessibilityValue(Text("\(Int(progress * 100))%")) } else { ProgressView().progressViewStyle(.linear) }
        }
        .padding(.vertical, NimbusSyncDesignTokens.spacing4)
    }
}

public struct MenuBarPopoverView: View {
    public let domains: [DomainDescriptor]
    public let tasks: [TaskDisplay]
    public let recentTasks: [TaskDisplay]
    public let hasActionableConflicts: Bool
    public let onOpenSettings: () -> Void
    public let onAddDomain: () -> Void
    public let onOpenConflicts: () -> Void
    public let onCancelTask: (UUID) -> Void
    public let onRetryTask: (UUID) -> Void
    public init(domains: [DomainDescriptor], tasks: [TaskDisplay] = [], recentTasks: [TaskDisplay] = [], hasActionableConflicts: Bool = false, onOpenSettings: @escaping () -> Void = {}, onAddDomain: @escaping () -> Void = {}, onOpenConflicts: @escaping () -> Void = {}, onCancelTask: @escaping (UUID) -> Void = { _ in }, onRetryTask: @escaping (UUID) -> Void = { _ in }) { self.domains = domains; self.tasks = tasks; self.recentTasks = recentTasks; self.hasActionableConflicts = hasActionableConflicts; self.onOpenSettings = onOpenSettings; self.onAddDomain = onAddDomain; self.onOpenConflicts = onOpenConflicts; self.onCancelTask = onCancelTask; self.onRetryTask = onRetryTask }
    public var body: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing12) {
            HStack {
				Text("NimbusSync").font(.headline)
                Spacer()
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).accessibilityLabel(Text("Settings"))
                Button(action: onAddDomain) { Image(systemName: "plus") }.buttonStyle(.borderless).accessibilityLabel(Text("Add domain"))
            }
            if domains.isEmpty {
                VStack(spacing: NimbusSyncDesignTokens.spacing8) {
                    Image(systemName: "externaldrive.badge.plus").font(.title2).accessibilityHidden(true)
                    Text("No domains").font(.headline)
                    Text("Add a Cloudreve domain to use Finder.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NimbusSyncDesignTokens.spacing16)
            } else {
                ForEach(domains, id: \.identifier) { domain in
                    HStack { Image(systemName: "externaldrive"); Text(domain.displayName); Spacer(); StatusBadge(status: domain.status) }
                }
            }
            if !tasks.isEmpty {
                Divider()
                Text("Active tasks").font(.subheadline)
                ForEach(tasks) { task in
                    TaskProgressRow(title: task.title, progress: task.progress, detail: task.detail, state: task.state, onCancel: { onCancelTask(task.id) }, onRetry: { onRetryTask(task.id) })
                }
            }
            if !recentTasks.isEmpty {
                Divider()
                Text("Recent").font(.subheadline)
                ForEach(recentTasks) { task in
                    TaskProgressRow(title: task.title, progress: task.progress, detail: task.detail, state: task.state, onCancel: { onCancelTask(task.id) }, onRetry: { onRetryTask(task.id) })
                }
            }
            if hasActionableConflicts {
                Button(action: onOpenConflicts) { Label("Review conflicts", systemImage: "exclamationmark.triangle") }.buttonStyle(.bordered)
            }
        }
        .padding(NimbusSyncDesignTokens.spacing16)
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
