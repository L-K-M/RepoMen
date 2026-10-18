import AppKit
import SwiftUI
import XCTest
@testable import RepoMen

final class ManagedStorageLayoutTests: XCTestCase {
    @MainActor
    func testLongCatalogFitsTheMinimumSplitWindow() throws {
        let documentation = try XCTUnwrap(URL(string: "https://example.com/cleanup"))
        let instructions = String(repeating: "Keep needed data and follow the owning application's cleanup instructions. ", count: 8)
        let areas = (0..<24).map { index in
            ManagedStorageArea(
                id: String(index), title: "Managed storage location \(index)",
                path: "/Users/fixture/Library/Caches/a-long-application-name/\(index)",
                instructions: instructions, documentationURL: documentation,
                applicationBundleIDs: ["com.example.fixture"], command: "tool cache prune")
        }
        let storage = ManagedStorageModel(areasProvider: { areas }, measurement: { _ in
            XCTFail("Layout must not start measurement")
            return .unmeasured
        })
        let root = NavigationSplitView {
            List { Text("Managed cleanup") }
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            ManagedStorageView(storage: storage)
        }
        .frame(minWidth: 780, minHeight: 460)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 460)
        hosting.layoutSubtreeIfNeeded()

        // Content must scroll inside the detail pane, rather than forcing the
        // entire split view (including the sidebar) above the window's bounds.
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, 460)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 780)
        XCTAssertFalse(storage.isMeasuring)
        XCTAssertTrue(storage.areas.allSatisfy { $0.state == .unmeasured })
    }
}
