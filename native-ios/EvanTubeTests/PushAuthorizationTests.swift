import XCTest
@testable import LovelyMusic

final class PushAuthorizationTests: XCTestCase {
    @MainActor func testMissingPushServiceReturnsWithoutRequestingSystemPermission() async {
        let returned = expectation(description: "No notification service needs no permission")
        Task {
            let granted = await APNsManager.shared.requestPushAuthorization(pushServiceURL: nil)
            XCTAssertFalse(granted)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
    }
}
