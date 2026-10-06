//
//  PermissionsView.swift
//  AssetOnBoard
//
//  The first screen: what the app needs, why, and what happens if you say no.
//

import SwiftUI

struct PermissionsView: View {
    let coordinator: PermissionsCoordinator
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(spacing: 0) {
                        ForEach(Array(PermissionsCoordinator.Permission.allCases.enumerated()), id: \.element.id) { index, permission in
                            if index > 0 { Divider().padding(.leading, 52) }
                            PermissionRow(permission: permission,
                                          status: coordinator.statuses[permission] ?? .notDetermined,
                                          isInFlight: coordinator.inFlight == permission)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    footnote
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Before you start")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("AssetOnBoard inventories the network around you. It needs three permissions to do that, and it asks for all of them here rather than surprising you later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Nothing it finds leaves your device.")
                .font(.subheadline.weight(.semibold))
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You can decline any of these. The app will tell you what it cannot show rather than failing silently, and you can change your mind later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if coordinator.statuses.values.contains(.denied) {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    await coordinator.requestAll()
                    if coordinator.allDecided { onContinue() }
                }
            } label: {
                Group {
                    if coordinator.isRequesting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(verbatim: promptingLabel)
                        }
                    } else {
                        Text(coordinator.allDecided ? "Continue" : "Grant Permissions")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.isRequesting)

            if !coordinator.allDecided && !coordinator.isRequesting {
                Button("Skip for now", action: onContinue)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var promptingLabel: String {
        guard let inFlight = coordinator.inFlight else { return "Asking…" }
        return "Asking for \(inFlight.title)…"
    }
}

// MARK: - Row

private struct PermissionRow: View {
    let permission: PermissionsCoordinator.Permission
    let status: PermissionsCoordinator.Status
    let isInFlight: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbolName)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: permission.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    statusBadge
                }
                Text(verbatim: permission.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status == .denied {
                    Text(verbatim: permission.consequenceIfDenied)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .unavailable(let reason) = status {
                    Text(verbatim: reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isInFlight {
            ProgressView().controlSize(.mini)
        } else {
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .denied:
                Label("Declined", systemImage: "xmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            case .unavailable:
                Label("Unavailable", systemImage: "minus.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Text("Not asked")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
