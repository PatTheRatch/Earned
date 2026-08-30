import Foundation
import EarnedKit

/// The accountability terms of one commitment, as sent to the server.
///
/// This is the whole of what the backend is told about a commitment
/// (docs/accountability-architecture.md §4.1). Everything absent from this type
/// is absent on purpose: no requirement, no restriction profile, no workout, no
/// progress, no reward eligibility. The server learns that an obligation
/// exists, when it hardened and when it is due — not what the user does.
///
/// Built from a `Commitment` in one place so that adding a field to the
/// commitment cannot quietly start sending it.
struct ContractEnvelope: Equatable, Sendable {
    let commitmentID: UUID
    let planID: UUID?
    let title: String
    let createdAt: Date
    let eligibleFrom: Date
    let deadline: Date
    let correctionWindow: TimeInterval
    let approvalsRequired: Int
    let accountabilityWindow: TimeInterval
    /// Empty until the consent flow exists. An envelope with no reachable
    /// roster registers fine and simply has no accountability route.
    let partnerIDs: [UUID]
    let version: Int

    init(_ commitment: Commitment, partnerIDs: [UUID] = [], version: Int = 1) {
        self.commitmentID = commitment.id
        self.planID = commitment.planID
        self.title = commitment.title
        self.createdAt = commitment.createdAt
        self.eligibleFrom = commitment.eligibleFrom
        self.deadline = commitment.deadline
        self.correctionWindow = commitment.configuredCorrectionWindow
        self.approvalsRequired = commitment.overridePolicy.approvalsRequired
        self.accountabilityWindow = commitment.overridePolicy.accountabilityWindow
        self.partnerIDs = partnerIDs
        self.version = version
    }

    /// The fields the server enforces. Used to notice that a commitment has
    /// been edited into terms the server has not been told about yet — an
    /// unregistered *change* is as much a gap as an unregistered commitment.
    var termsSignature: String {
        let stamps = [createdAt, eligibleFrom, deadline]
            .map { String(format: "%.6f", $0.timeIntervalSince1970) }
        return (stamps + [
            String(format: "%.6f", correctionWindow),
            String(approvalsRequired),
            String(format: "%.6f", accountabilityWindow),
            partnerIDs.map(\.uuidString).sorted().joined(separator: ","),
        ]).joined(separator: "|")
    }
}

/// What the server says back about an envelope it now holds.
///
/// `hardensAt` and `isLate` are the server's answers, not echoes of ours. They
/// are stored and displayed as such — if the two ever disagree, the server is
/// right by construction and the difference is worth seeing.
struct EnvelopeReceipt: Equatable, Sendable {
    let commitmentID: UUID
    let version: Int
    let hardensAt: Date?
    let isLate: Bool
    let partnerCount: Int
    let approvalsRequired: Int
    let accountabilityAvailable: Bool
    let registeredAt: Date?

    init(json: [String: Any]) throws {
        guard let idString = json["commitment_id"] as? String,
              let id = UUID(uuidString: idString) else {
            throw BackendClient.Failure.refused(
                status: 200, message: "The server did not say which commitment it registered.")
        }
        self.commitmentID = id
        self.version = json["version"] as? Int ?? 1
        self.hardensAt = Self.date(json["hardens_at"])
        self.isLate = json["is_late"] as? Bool ?? false
        self.partnerCount = json["partner_count"] as? Int ?? 0
        self.approvalsRequired = json["approvals_required"] as? Int ?? 0
        self.accountabilityAvailable = json["accountability_available"] as? Bool ?? false
        self.registeredAt = Self.date(json["registered_at"])
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: string) ?? plain.date(from: string)
    }
}
