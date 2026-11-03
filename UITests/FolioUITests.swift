import XCTest
import UIKit

final class FolioUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        // No private decks or revision history are used by the public build job.
        app.launchEnvironment["FOLIO_UI_TEST_HTML"] = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>html,body{margin:0;background:#14201c;color:white;font:18px system-ui}
        main{padding:24px}button{font:inherit;padding:16px}
        nav{position:fixed;bottom:0;left:0;right:0;background:#1f3028;padding:8px 12px calc(8px + env(safe-area-inset-bottom))}
        </style></head><body><main><h1 id="status">Session active</h1>
        <button onclick="if(confirm('End this session and keep all recorded work?'))document.getElementById('status').textContent='Session saved'">End early</button>
        <button onclick="const name=prompt('Enter a note','Draft');if(name!==null)document.getElementById('status').textContent=name">Edit note</button>
        <button onclick="alert('Your work is saved')">Show message</button></main>
        <nav><button>Study desk</button></nav></body></html>
        """
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.buttons["End early"].waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testEndEarlyCancelAndConfirm() {
        app.webViews.buttons["End early"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Session active"].exists)
        XCTAssertFalse(app.webViews.staticTexts["Session saved"].exists)
        app.webViews.buttons["End early"].tap()
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Session saved"].waitForExistence(timeout: 5))
    }

    func testTextInputAndMessageDialogs() {
        app.webViews.buttons["Edit note"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Session active"].exists)
        app.webViews.buttons["Edit note"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Draft")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Draft"].waitForExistence(timeout: 5))
        app.webViews.buttons["Show message"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Your work is saved"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.webViews.buttons["End early"].isHittable)
    }

    func testWebViewFillsBottomAndNavigationAvoidsHomeIndicator() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let web = app.webViews.firstMatch
            let reachesBottom = NSPredicate { _, _ in
                abs(web.frame.maxY - self.app.windows.firstMatch.frame.maxY) < 2
            }
            expectation(for: reachesBottom, evaluatedWith: web)
            waitForExpectations(timeout: 10)
            let navigation = app.webViews.buttons["Study desk"]
            XCTAssertTrue(navigation.isHittable)
            XCTAssertLessThan(navigation.frame.maxY, app.windows.firstMatch.frame.maxY - 15)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = orientation == .portrait ? "portrait-bottom-layout" : "landscape-bottom-layout"
            image.lifetime = .keepAlways
            add(image)
        }
    }
}
