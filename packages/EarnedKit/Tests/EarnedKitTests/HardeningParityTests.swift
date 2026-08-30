import Foundation
import XCTest
@testable import EarnedKit

/// Hardening, checked against the fixtures the backend is checked against.
///
/// `Commitment.hardensAt` is no longer the only implementation of this rule.
/// The server computes it too, because it decides independently whether an
/// override request is against a hardened contract and must not be able to be
/// told the answer by an adversarial client (docs/accountability-architecture.md
/// §4.2). Two implementations of one rule drift silently unless something holds
/// them together; `fixtures/hardening-cases.json` is that something, and this is
/// one of its two readers.
///
/// The expected values in the fixture were produced by neither implementation,
/// so a bug present in both Swift and SQL still fails here.
final class HardeningParityTests: XCTestCase {

    private struct Fixture: Decodable {
        let hardeningFraction: Double
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let createdAt: String
            let deadline: String
            let correctionWindow: TimeInterval
            let expectedHardensAt: String
        }
    }

    /// Postgres stores timestamps to the microsecond, so that is the finest
    /// resolution at which the two implementations can be asked to agree.
    /// Anything coarser would let a real divergence hide; anything finer would
    /// fail on representation, not on the rule.
    private static let tolerance: TimeInterval = 1e-6

    /// The fixture lives at the repository root because it belongs to neither
    /// side. Located relative to this file rather than bundled, so the same
    /// bytes are read by the SQL test in `backend/tests/`.
    private static var fixtureURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // …/packages/EarnedKit/Tests/EarnedKitTests/<file>
        return url.appendingPathComponent("fixtures/hardening-cases.json")
    }

    private static func date(_ string: String) throws -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = withFraction.date(from: string) ?? plain.date(from: string) { return date }
        throw XCTSkip("Unparseable fixture timestamp: \(string)")
    }

    private func loadFixture() throws -> Fixture {
        let url = Self.fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Shared fixture missing at \(url.path). It is the only thing keeping "
                    + "Commitment.hardensAt and public.earned_hardens_at in agreement.")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testHardeningMatchesTheSharedFixtures() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty, "an empty fixture proves nothing")

        for testCase in fixture.cases {
            let createdAt = try Self.date(testCase.createdAt)
            let commitment = makeCommitment(deadline: try Self.date(testCase.deadline),
                                            createdAt: createdAt,
                                            correctionWindow: testCase.correctionWindow)
            let expected = try Self.date(testCase.expectedHardensAt)
            XCTAssertEqual(commitment.hardensAt.timeIntervalSince1970,
                           expected.timeIntervalSince1970,
                           accuracy: Self.tolerance,
                           "\(testCase.name) — the backend expects \(testCase.expectedHardensAt)")
        }
    }

    /// The constant itself, so a change to it cannot pass by quietly agreeing
    /// with a fixture that was regenerated from the same changed constant.
    func testHardeningFractionMatchesTheFixture() throws {
        XCTAssertEqual(Commitment.hardeningFraction, try loadFixture().hardeningFraction)
    }

    /// `isHardened` is inclusive of the instant itself, which is the boundary
    /// the server's `is_late` check reproduces.
    func testHardeningBoundaryIsInclusive() throws {
        let createdAt = d(24, 8)
        let commitment = makeCommitment(deadline: d(24, 10), createdAt: createdAt,
                                        correctionWindow: 7200)
        let hardensAt = commitment.hardensAt
        XCTAssertEqual(hardensAt, createdAt.addingTimeInterval(900))
        XCTAssertFalse(commitment.isHardened(at: hardensAt.addingTimeInterval(-0.001)))
        XCTAssertTrue(commitment.isHardened(at: hardensAt))
        XCTAssertTrue(commitment.isHardened(at: hardensAt.addingTimeInterval(0.001)))
    }
}
