import Foundation
import Observation

/// The Clutter screen: two tools under one roof.
@Observable
@MainActor
final class ClutterModel {
    enum Tab: Hashable, Sendable {
        case largeOld, duplicates

        var title: String {
            switch self {
            case .largeOld: "Large & old"
            case .duplicates: "Duplicates"
            }
        }
    }

    var tab: Tab = .largeOld
    let largeOld: LargeOldModel
    let duplicates: DuplicatesModel

    init(largeOld: LargeOldModel, duplicates: DuplicatesModel) {
        self.largeOld = largeOld
        self.duplicates = duplicates
    }
}
