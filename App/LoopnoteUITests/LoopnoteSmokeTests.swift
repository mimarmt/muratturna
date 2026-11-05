import XCTest

/// Smoke tests run on every TestFlight build: a build that crashes in a core flow is never uploaded.
final class LoopnoteSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    func testCreateNoteAndBrowse() {
        let write = app.buttons["action.write"]
        XCTAssertTrue(write.waitForExistence(timeout: 20), "Main screen did not appear")
        write.tap()

        let field = app.descendants(matching: .any)["editor.details"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Note editor did not open")
        field.tap()
        field.typeText("Check the scaffolding at the site tomorrow at ten")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'scaffolding'"))
            .firstMatch.waitForExistence(timeout: 30), "Saved note is not listed")

        // Settings
        app.buttons["toolbar.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 10), "Settings did not close")

        // Meetings tab and recorder. The Liquid Glass tab bar is not always reported as a
        // TabBar element, so look for the tab button anywhere.
        let tabBarButton = app.tabBars.buttons["Meetings"]
        let meetingsTab = tabBarButton.exists ? tabBarButton : app.buttons["Meetings"].firstMatch
        XCTAssertTrue(meetingsTab.waitForExistence(timeout: 10), "Meetings tab is missing")
        meetingsTab.tap()
        XCTAssertTrue(app.navigationBars["Meetings"].waitForExistence(timeout: 10), "Meetings tab did not open")
        app.buttons["Start recording"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Record a meeting"].waitForExistence(timeout: 10), "Recorder did not open")
        app.buttons["Cancel"].tap()
    }
}
