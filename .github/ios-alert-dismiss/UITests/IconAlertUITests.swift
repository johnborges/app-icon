import XCTest

final class IconAlertUITests: XCTestCase {
    func testDismissAlternateIconAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        let alert = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS %@", "changed the icon")
        ).firstMatch
        if alert.waitForExistence(timeout: 20) {
            let ok = alert.buttons["OK"]
            if ok.exists {
                ok.tap()
            } else if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
            }
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: alert
            )
            let result = XCTWaiter.wait(for: [gone], timeout: 8)
            if result != .completed {
                XCTFail("ALERT_STILL_PRESENT \(alert.label)")
                return
            }
            print("ALERT_DISMISSED")
        } else {
            print("ALERT_ABSENT")
        }
    }
}
