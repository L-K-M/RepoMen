import SwiftUI

/// An explicit scan action outside the table's noninteractive empty overlay.
struct SystemScanHeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title
                    Spacer(minLength: 8)
                    scanButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    scanButton
                }
            }
            captionText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.red)
            Text("System (root)")
                .font(.headline)
        }
    }

    private var captionText: some View {
        Text("Find root-owned logs and caches with administrator access. macOS may ask for your password.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var scanButton: some View {
        Button {
            model.scanSystemAreas()
        } label: {
            if model.isSystemScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                }
            } else {
                Label("Scan System Areas…", systemImage: "lock.shield")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isBusy || model.isReclaiming || model.isSystemScanning)
    }
}
