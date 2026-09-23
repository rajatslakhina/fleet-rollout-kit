import XCTest
@testable import FleetRollout

final class AcceptancePolicyTests: XCTestCase {

    func testMonotonicPolicyPassesTheCheck() {
        XCTAssertTrue(VersionFloorCheck.violations(of: MonotonicVersionFloorPolicy()).isEmpty)
    }

    /// The paired negative case. `VersionFloorCheck` would be theatre if it
    /// accepted every implementation, so the broken policy — "whatever the
    /// server sent last wins", which is what most hand-rolled config clients
    /// actually do — is asserted to fail it.
    func testCheckRejectsTheNaiveNewestResponseWinsPolicy() {
        let violations = VersionFloorCheck.violations(of: NewestResponseWinsPolicy())
        XCTAssertFalse(violations.isEmpty)
        XCTAssertTrue(violations.contains { $0.offeredVersion == 6 && $0.acceptedFloor == 7 })

        let rollback = violations.first { $0.offeredVersion == 6 && $0.acceptedFloor == 7 }
        XCTAssertEqual(
            rollback?.description,
            "offered v6 against floor v7: accepted=true, expected=false")
    }

    func testCheckRejectsAStrictlyGreaterPolicyThatDropsEqualVersions() {
        struct StrictlyGreater: DocumentAcceptancePolicy {
            func shouldAccept(offeredVersion: Int, acceptedFloor: Int) -> Bool {
                offeredVersion > acceptedFloor
            }
        }
        let violations = VersionFloorCheck.violations(of: StrictlyGreater())
        XCTAssertFalse(violations.isEmpty)
        XCTAssertTrue(violations.contains { $0.offeredVersion == $0.acceptedFloor })
    }

    func testExtremesDoNotTrap() {
        let policy = MonotonicVersionFloorPolicy()
        XCTAssertTrue(policy.shouldAccept(offeredVersion: Int.max, acceptedFloor: Int.min))
        XCTAssertFalse(policy.shouldAccept(offeredVersion: Int.min, acceptedFloor: Int.max))
    }
}
