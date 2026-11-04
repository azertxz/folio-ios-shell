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
        <button onclick="fetch('/api/status').then(r=>document.getElementById('status').textContent='PC response '+r.status).catch(()=>document.getElementById('status').textContent='Unreadable connection failure')">Check PC connection</button>
        <button onclick="window.webkit.messageHandlers.folioNative.postMessage({action:'paper',url:'https://example.invalid/exam.pdf'});setTimeout(()=>window.webkit.messageHandlers.folioNative.postMessage({action:'break',until:Date.now()+12000}),5000)">Open paper then take break</button>
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

    func testConnectionFailureIsReadableWithoutLosingTheStudyPage() {
        app.webViews.buttons["Check PC connection"].tap()
        XCTAssertTrue(app.webViews.staticTexts["PC response 503"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.buttons["End early"].isHittable)
    }

    func testMandatoryBreakClosesPaperAndLocksTheWholeApp() {
        app.webViews.buttons["Open paper then take break"].tap()
        XCTAssertTrue(app.buttons["Back to my answer"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Take a five-minute break"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Back to my answer"].exists)
        XCTAssertFalse(app.buttons["Connection"].isEnabled)
        let finished = NSPredicate { _, _ in !self.app.staticTexts["Take a five-minute break"].exists }
        expectation(for: finished, evaluatedWith: app)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.buttons["Connection"].isEnabled)
        XCTAssertTrue(app.webViews.buttons["End early"].isHittable)
    }

    func testWebViewFillsBottomAndNavigationAvoidsHomeIndicator() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            // The old portrait geometry can still satisfy the bottom-edge
            // assertion while a rotation is starting. Wait for the new bounds.
            let landscape = orientation == .landscapeLeft
            let rotated = NSPredicate { _, _ in
                let bounds = self.app.windows.firstMatch.frame
                return landscape ? bounds.width > bounds.height : bounds.height > bounds.width
            }
            expectation(for: rotated, evaluatedWith: app.windows.firstMatch)
            waitForExpectations(timeout: 10)
            let web = app.webViews.firstMatch
            let reachesBottom = NSPredicate { _, _ in
                abs(web.frame.maxY - self.app.windows.firstMatch.frame.maxY) < 2
            }
            expectation(for: reachesBottom, evaluatedWith: web)
            waitForExpectations(timeout: 10)
            let navigation = app.webViews.buttons["Study desk"]
            XCTAssertTrue(navigation.isHittable)
            XCTAssertLessThan(navigation.frame.maxY, app.windows.firstMatch.frame.maxY - 15)
            let screenshot = XCUIScreen.main.screenshot()
            XCTAssertEqual(screenshot.image.size.width > screenshot.image.size.height, landscape)
            let image = XCTAttachment(screenshot: screenshot)
            image.name = orientation == .portrait ? "portrait-bottom-layout" : "landscape-bottom-layout"
            image.lifetime = .keepAlways
            add(image)
        }
    }
}
