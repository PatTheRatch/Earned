import Foundation
import EarnedKit

/// A recurring plan as Today needs to show it: the whole thing in one line.
struct PlanSummary: Identifiable {
    let plan: CommitmentPlan
    /// The soonest occurrence still outstanding — what the row is actually about.
    let next: CommitmentRecord
    let completed: Int
    let total: Int

    var id: UUID { plan.id }

    /// "Mon/Wed/Fri · 3 of 12 done"
    var scheduleLine: String {
        "\(Format.weekdays(plan.weekdays)) · \(completed) of \(total) done"
    }
}

/// One row in Today's upcoming list.
///
/// Plans collapse to a single entry and standalone commitments stand alone,
/// so twelve occurrences of one decision read as one decision.
enum UpcomingEntry: Identifiable {
    case commitment(CommitmentRecord)
    case plan(PlanSummary)

    var id: UUID {
        switch self {
        case .commitment(let record): return record.commitment.id
        case .plan(let summary): return summary.id
        }
    }
}
