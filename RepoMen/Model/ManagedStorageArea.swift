import Foundation

/// Storage whose owner must decide what to remove. Never a CleanableItem: these
/// measurements cannot enter reclaim totals, checkboxes or watch automation.
struct ManagedStorageArea: Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case unmeasured
        case missing
        case measured(Int64)
        case partial(Int64, String)
        case failed(String)
    }

    let id: String
    let title: String
    let path: String
    let instructions: String
    let documentationURL: URL
    let applicationBundleIDs: [String]
    var command: String? = nil
    var state: State = .unmeasured
}
