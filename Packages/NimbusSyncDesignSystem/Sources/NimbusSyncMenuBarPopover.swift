import SwiftUI
import CloudreveDomainKit

public struct MenuBarPopoverView: View {
    public let domains: [DomainDescriptor]
    public let tasks: [TaskDisplay]
    public let recentTasks: [TaskDisplay]
    public let hasActionableConflicts: Bool
    public let onOpenSettings: () -> Void
    public let onAddDomain: () -> Void
    public let onOpenConflicts: () -> Void
    public let onOpenDomain: (DomainDescriptor) -> Void
    public let onCancelTask: (UUID) -> Void
    public let onRetryTask: (UUID) -> Void

    public init(
        domains: [DomainDescriptor],
        tasks: [TaskDisplay] = [],
        recentTasks: [TaskDisplay] = [],
        hasActionableConflicts: Bool = false,
        onOpenSettings: @escaping () -> Void = {},
        onAddDomain: @escaping () -> Void = {},
        onOpenConflicts: @escaping () -> Void = {},
        onOpenDomain: @escaping (DomainDescriptor) -> Void = { _ in },
        onCancelTask: @escaping (UUID) -> Void = { _ in },
        onRetryTask: @escaping (UUID) -> Void = { _ in }
    ) {
        self.domains = domains
        self.tasks = tasks
        self.recentTasks = recentTasks
        self.hasActionableConflicts = hasActionableConflicts
        self.onOpenSettings = onOpenSettings
        self.onAddDomain = onAddDomain
        self.onOpenConflicts = onOpenConflicts
        self.onOpenDomain = onOpenDomain
        self.onCancelTask = onCancelTask
        self.onRetryTask = onRetryTask
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing16) {
                    statusOverview

                    if domains.isEmpty {
                        emptyState
                    } else {
                        domainsSection
                    }

                    if hasActionableConflicts {
                        conflictCallout
                    }

                    if !tasks.isEmpty {
                        taskSection(title: "Active tasks", tasks: tasks)
                    }

                    if !recentTasks.isEmpty {
                        taskSection(title: "Recent activity", tasks: recentTasks)
                    }
                }
                .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
                .padding(.vertical, NimbusSyncDesignTokens.spacing16)
            }
            .frame(maxHeight: 520)
        }
        .frame(minWidth: 380, idealWidth: NimbusSyncDesignTokens.popoverWidth, maxWidth: 420)
        .tint(NimbusSyncDesignTokens.brandColor)
    }

    private var header: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            DomainIconView(iconURL: nil, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("NimbusSync")
                    .font(.headline)
                Text("Cloudreve for Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)

            HStack(spacing: NimbusSyncDesignTokens.spacing4) {
                settingsButton

                Button(action: onAddDomain) {
                    Image(systemName: "plus")
                        .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Add domain"))
                .help("Add domain")
            }
        }
        .padding(.horizontal, NimbusSyncDesignTokens.spacing16)
        .padding(.vertical, NimbusSyncDesignTokens.spacing12)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                settingsButtonLabel
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Settings"))
            .help("Settings")
        } else {
            Button(action: onOpenSettings) {
                settingsButtonLabel
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Settings"))
            .help("Settings")
        }
    }

    private var settingsButtonLabel: some View {
        Image(systemName: "gearshape")
            .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
    }

    private var statusOverview: some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing12) {
            Image(systemName: overallStatus.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(overallStatus.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusSummary)
                    .font(.subheadline.weight(.semibold))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)
            if !domains.isEmpty {
                Text("\(domains.count)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(overallStatus.tint)
                    .accessibilityLabel(Text("\(domains.count) connected domains"))
            }
        }
        .padding(NimbusSyncDesignTokens.spacing12)
        .background(overallStatus.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var domainsSection: some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading("Connected domains", count: domains.count)
            ForEach(domains, id: \.identifier) { domain in
                domainRow(domain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: NimbusSyncDesignTokens.spacing8) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(NimbusSyncDesignTokens.brandColor)
                .accessibilityHidden(true)
            Text("Connect your first domain")
                .font(.headline)
            Text("Add a Cloudreve domain to make it available in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAddDomain) {
                Label("Add domain", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NimbusSyncDesignTokens.spacing16)
    }

    private func domainRow(_ domain: DomainDescriptor) -> some View {
        HStack(spacing: NimbusSyncDesignTokens.spacing8) {
            DomainIconView(iconURL: domain.iconURL, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(domain.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusBadge(status: domain.status, compact: true)
            }

            Spacer(minLength: NimbusSyncDesignTokens.spacing8)

            Button(action: { onOpenDomain(domain) }) {
                Image(systemName: "folder")
                    .frame(width: NimbusSyncDesignTokens.controlSize, height: NimbusSyncDesignTokens.controlSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("Open \(domain.displayName) in Finder"))
            .help("Open in Finder")
        }
        .padding(NimbusSyncDesignTokens.spacing8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
    }

    private var conflictCallout: some View {
        Button(action: onOpenConflicts) {
            HStack(spacing: NimbusSyncDesignTokens.spacing8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conflicts need attention")
                        .font(.subheadline.weight(.semibold))
                    Text("Review the latest local and remote versions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: NimbusSyncDesignTokens.spacing8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(NimbusSyncDesignTokens.spacing12)
            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: NimbusSyncDesignTokens.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Review conflicts"))
    }

    private func taskSection(title: String, tasks: [TaskDisplay]) -> some View {
        VStack(alignment: .leading, spacing: NimbusSyncDesignTokens.spacing8) {
            sectionHeading(title, count: tasks.count)
            ForEach(tasks) { task in
                TaskProgressRow(
                    title: task.title,
                    progress: task.progress,
                    detail: task.detail,
                    state: task.state,
                    onCancel: { onCancelTask(task.id) },
                    onRetry: { onRetryTask(task.id) }
                )
                if task.id != tasks.last?.id {
                    Divider()
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: NimbusSyncDesignTokens.spacing8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("\(count) items"))
        }
    }

    private var overallStatus: DomainStatus {
        domains.map(\.status).max { lhs, rhs in lhs.priority < rhs.priority } ?? .initializing
    }

    private var statusSummary: String {
        if domains.isEmpty { return "Ready to connect" }
        if attentionCount > 0 { return "Needs your attention" }
        if !tasks.isEmpty { return "Syncing your files" }
        return overallStatus.title
    }

    private var statusDetail: String {
        if domains.isEmpty { return "Connect a Cloudreve domain to get started." }
        if attentionCount > 0 { return "\(attentionCount) domain\(attentionCount == 1 ? "" : "s") need a review." }
        if !tasks.isEmpty { return "Changes are being processed in the background." }
        return switch overallStatus {
        case .healthy: "Your connected domains are ready in Finder."
        case .eventDegraded: "Live updates are unavailable; NimbusSync will reconcile when possible."
        case .appNotRunning: "NimbusSync is not running; launch it to resume live updates."
        case .syncing: "NimbusSync is processing changes in the background."
        case .reconciling, .initializing: "NimbusSync is checking your connected domains."
        case .removalPreflight: "A domain is being removed."
        default: "Your connected domains are being prepared."
        }
    }

    private var attentionCount: Int {
        domains.filter { domain in
            switch domain.status {
            case .healthy, .syncing, .reconciling, .initializing, .eventDegraded, .appNotRunning, .removalPreflight:
                return false
            case .offline, .authExpired, .rootUnavailable, .scopeConflict, .conflict, .permanentError, .repairRequired:
                return true
            }
        }.count
    }
}
