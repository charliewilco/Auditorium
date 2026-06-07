import XCTest

final class AuditoriumUITests: XCTestCase {
	private var app: XCUIApplication!

	override func setUpWithError() throws {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launchEnvironment["CI"] = "true"
	}

	override func tearDownWithError() throws {
		app = nil
	}

	@MainActor
	func testFirstLaunchShowsWelcomeActions() throws {
		app.launch()

		XCTAssertTrue(app.staticTexts["Auditorium"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["Create Project"].exists)
		XCTAssertTrue(app.buttons["Open Demo Project"].exists)
		XCTAssertTrue(app.staticTexts["Queue the work. Hit play. Review the pull requests."].exists)
	}

	@MainActor
	func testOpenDemoProjectShowsDashboardSmokeState() throws {
		app.launch()

		let openDemo = app.buttons["Open Demo Project"]
		XCTAssertTrue(openDemo.waitForExistence(timeout: 5))
		openDemo.click()

		XCTAssertTrue(app.staticTexts["Burton Demo"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["Open Tickets"].exists)
		XCTAssertTrue(app.staticTexts["Queued Tickets"].exists)
		XCTAssertTrue(app.staticTexts["Local Paths"].exists)
		XCTAssertTrue(app.staticTexts["Runtime Health"].exists)
		XCTAssertTrue(app.staticTexts["Offline"].exists)
	}
}
