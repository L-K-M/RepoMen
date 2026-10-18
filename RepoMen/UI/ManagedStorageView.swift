import AppKit
import SwiftUI

/// Read-only measurements and instructions for storage managed by its owning tool.
struct ManagedStorageView: View {
    @StateObject private var storage = ManagedStorageModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            cardsList
        }
        .onDisappear { storage.cancel() }
        .alert(
            "Could not open item",
            isPresented: Binding(
                get: { storage.actionError != nil },
                set: { if !$0 { storage.actionError = nil } })
        ) {
            Button("OK") { storage.actionError = nil }
        } message: {
            Text(storage.actionError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Managed cleanup")
                    .font(.title2)
                    .bold()
                Spacer()
                measureButton
            }
            Text("""
                Measure these locations, then follow the owning tool's cleanup instructions. \
                Measurement is read-only. Sizes describe storage footprints, not guaranteed recovered space.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var measureButton: some View {
        if storage.isMeasuring {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Button("Stop") { storage.cancel() }
                    .controlSize(.small)
            }
        } else {
            Button {
                storage.measure()
            } label: {
                Label("Measure", systemImage: "ruler")
            }
            .controlSize(.small)
        }
    }

    // MARK: Cards

    private var cardsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(storage.areas) { area in
                    areaCard(area)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func areaCard(_ area: ManagedStorageArea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(area.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(area.path)

            sizeBadge(for: area)

            Text(area.instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions(for: area)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func actions(for area: ManagedStorageArea) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                documentationLink(for: area)
                commandButton(for: area)
                openApplicationButton(for: area)
                revealButton(for: area)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    documentationLink(for: area)
                    commandButton(for: area)
                }
                HStack(spacing: 8) {
                    openApplicationButton(for: area)
                    revealButton(for: area)
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    private func documentationLink(for area: ManagedStorageArea) -> some View {
        Link(destination: area.documentationURL) {
            Label("Documentation", systemImage: "doc.badge.gear")
        }
    }

    @ViewBuilder
    private func commandButton(for area: ManagedStorageArea) -> some View {
        if area.command != nil {
            Button {
                storage.copyCommand(for: area)
            } label: {
                Label("Copy Command", systemImage: "doc.on.clipboard")
            }
        }
    }

    @ViewBuilder
    private func openApplicationButton(for area: ManagedStorageArea) -> some View {
        if !area.applicationBundleIDs.isEmpty {
            Button {
                storage.openApplication(for: area)
            } label: {
                Label("Open App", systemImage: "app.badge.fill")
            }
        }
    }

    private func revealButton(for area: ManagedStorageArea) -> some View {
        Button {
            storage.reveal(area)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
    }

    private func sizeBadge(for area: ManagedStorageArea) -> some View {
        Group {
            switch area.state {
            case .unmeasured:
                Text("Not measured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case .missing:
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .measured(let bytes):
                Text(Format.bytes(bytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)

            case .partial(let bytes, let detail):
                VStack(alignment: .leading, spacing: 1) {
                    Text("At least \(Format.bytes(bytes))")
                        .font(.caption)
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
