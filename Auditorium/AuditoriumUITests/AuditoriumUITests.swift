import AppKit
import Security
import XCTest

final class AuditoriumUITests: XCTestCase {
	private var app: XCUIApplication!
	private var keychainServiceName: String?

	private struct LiveGitHubFlowConfig: Decodable {
		let token: String
		let repository: String
		let issueTitle: String
		let symphonyDirectory: String
	}

	override func setUpWithError() throws {
		continueAfterFailure = false
		app = XCUIApplication()
		app.launchEnvironment["CI"] = "true"
	}

	override func tearDownWithError() throws {
		if let keychainServiceName {
			deleteKeychainItems(service: keychainServiceName)
		}
		keychainServiceName = nil
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

	@MainActor
	func testLiveGitHubIssueToPullRequestFlowWhenConfigured() throws {
		let environment = ProcessInfo.processInfo.environment
		let config = try liveGitHubFlowConfig(environment: environment)
		let token = config.token
		let repository = config.repository
		let issueTitle = config.issueTitle
		let symphonyDirectory = config.symphonyDirectory
		let testStartedAt = Date()
		let repoParts = repository.split(separator: "/", maxSplits: 1).map(String.init)
		XCTAssertEqual(repoParts.count, 2, "AUDITORIUM_LIVE_UI_REPO must use owner/name form.")
		let repositoryName = repoParts.last ?? repository
		let keychainService = "co.charliewil.Auditorium.ui-live.\(UUID().uuidString)"
		keychainServiceName = keychainService
		let tempDirectory = FileManager.default
			.homeDirectoryForCurrentUser
			.appendingPathComponent("Library")
			.appendingPathComponent("Application Support")
			.appendingPathComponent("Auditorium")
			.appendingPathComponent("UITestTools")
			.appendingPathComponent(UUID().uuidString)
		let binDirectory = tempDirectory.appendingPathComponent("bin")
		try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempDirectory) }
		try writeFakeCodex(to: binDirectory.appendingPathComponent("codex"))
		try writeSymphonyWrapper(
			to: binDirectory.appendingPathComponent("symphony"),
			fakeBinDirectory: binDirectory,
			symphonyDirectory: URL(fileURLWithPath: symphonyDirectory)
		)

		app.launchEnvironment["AUDITORIUM_KEYCHAIN_SERVICE"] = keychainService
		app.launchEnvironment["AUDITORIUM_SYMPHONY_BIN_DIRECTORY"] = binDirectory.path
		app.launchEnvironment["PATH"] = "\(binDirectory.path):\(symphonyDirectory):\(environment["PATH"] ?? "")"
		app.launchArguments = [
			"-allowNetworkAccess", "YES",
			"-requireRunConfirmation", "NO",
			"-requirePROpenConfirmation", "NO",
			"-symphonyBinDirectory", binDirectory.path,
			"-symphonyExecutablePath", binDirectory.appendingPathComponent("symphony").path,
		]
		app.launch()

		clickButton("Create Project", timeout: 5)
		clickButton("Next")
		setSecureField("GitHub OAuth access token", to: token)
		clickButton("Next")
		setTextField("Project Name", to: repositoryName)
		setTextField("Repository", to: repository)
		setTextField("Clone/Web URL", to: "https://github.com/\(repository)")
		setTextField("Default Branch", to: "main")
		clickButton("Next")
		clickStaticText("GitHub Issues")
		clickButton("Next")
		clickButton("Next")
		setTextField("Team / Project", to: repository)
		setTextField("Source Identifier", to: repository)
		setTextField("Filter", to: "state:open")
		setTextField("Issue Tracker URL", to: "https://github.com/\(repository)/issues")
		let importGitHubIssues = app.checkBoxes["Import open GitHub issues"]
		if importGitHubIssues.exists, importGitHubIssues.value as? String != "1" {
			importGitHubIssues.click()
		}
		let importDemoTickets = app.checkBoxes["Import demo tickets"]
		if importDemoTickets.exists, importDemoTickets.value as? String == "1" {
			importDemoTickets.click()
		}
		clickButton("Next")
		clickStaticText("Local Workspace")
		clickButton("Next")
		clickStaticText("Codex")
		clickButton("Next")
		setTextField("Branch Prefix", to: "auditorium-ui-smoke")
		clickButton("Next")
		clickSheetButton("Create Project")

		XCTAssertTrue(app.staticTexts[repositoryName].waitForExistence(timeout: 20))
		clickSidebarItem("Tickets")
		searchTickets(issueTitle)
		waitForStaticText(containing: issueTitle, timeout: 20)
		clickScrollButton("Add to Queue")
		clickSidebarItem("Queue")
		waitForStaticText(containing: issueTitle, timeout: 10)
		clickButton("Run Queue")
		let openPR = app.links["Open PR"]
		if openPR.waitForExistence(timeout: 120) == false {
			XCTFail(liveGitHubFlowDiagnostics(issueTitle: issueTitle, since: testStartedAt))
			return
		}
		XCTAssertTrue(app.staticTexts["Needs Review"].waitForExistence(timeout: 10))
	}

	private func liveGitHubFlowConfig(environment: [String: String]) throws -> LiveGitHubFlowConfig {
		if environment["AUDITORIUM_LIVE_UI_GITHUB_FLOW"] == "1",
			let token = environment["AUDITORIUM_LIVE_UI_GITHUB_TOKEN"],
			let repository = environment["AUDITORIUM_LIVE_UI_REPO"],
			let issueTitle = environment["AUDITORIUM_LIVE_UI_ISSUE_TITLE"],
			let symphonyDirectory = environment["AUDITORIUM_LIVE_UI_SYMPHONY_DIR"]
		{
			return LiveGitHubFlowConfig(
				token: token,
				repository: repository,
				issueTitle: issueTitle,
				symphonyDirectory: symphonyDirectory
			)
		}
		let configURL = URL(fileURLWithPath: "/tmp/auditorium-live-ui-github-flow.json")
		if FileManager.default.fileExists(atPath: configURL.path) {
			let data = try Data(contentsOf: configURL)
			return try JSONDecoder().decode(LiveGitHubFlowConfig.self, from: data)
		}
		throw XCTSkip("Set AUDITORIUM_LIVE_UI_GITHUB_FLOW=1 or /tmp/auditorium-live-ui-github-flow.json.")
	}

	private func clickButton(_ label: String, timeout: TimeInterval = 10) {
		let button = app.buttons[label]
		XCTAssertTrue(button.waitForExistence(timeout: timeout), "Missing button \(label).")
		button.click()
	}

	private func clickScrollButton(_ label: String, timeout: TimeInterval = 10) {
		let button = app.scrollViews.buttons[label].firstMatch
		XCTAssertTrue(button.waitForExistence(timeout: timeout), "Missing scroll button \(label).")
		button.click()
	}

	private func clickSheetButton(_ label: String, timeout: TimeInterval = 10) {
		let button = app.sheets.buttons[label]
		XCTAssertTrue(button.waitForExistence(timeout: timeout), "Missing sheet button \(label).")
		button.click()
	}

	private func clickStaticText(_ label: String, timeout: TimeInterval = 10) {
		let text = app.staticTexts[label]
		XCTAssertTrue(text.waitForExistence(timeout: timeout), "Missing text \(label).")
		text.click()
	}

	private func clickSidebarItem(_ label: String, timeout: TimeInterval = 10) {
		let item = app.outlines["Sidebar"].staticTexts[label]
		XCTAssertTrue(item.waitForExistence(timeout: timeout), "Missing sidebar item \(label).")
		item.click()
	}

	private func waitForStaticText(containing text: String, timeout: TimeInterval) {
		let predicate = NSPredicate(format: "value CONTAINS %@", text)
		let element = app.staticTexts.containing(predicate).firstMatch
		XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing static text containing \(text).")
	}

	private func setSecureField(_ label: String, to value: String) {
		let field = app.secureTextFields[label]
		XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing secure field \(label).")
		field.click()
		field.typeText(value)
	}

	private func setTextField(_ label: String, to value: String) {
		let field = app.textFields[label]
		XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing text field \(label).")
		field.click()
		field.typeKey("a", modifierFlags: .command)
		field.typeText(value)
	}

	private func searchTickets(_ text: String) {
		app.typeKey("f", modifierFlags: .command)
		let field = app.searchFields.firstMatch
		XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing ticket search field.")
		field.typeText(text)
	}

	private func liveGitHubFlowDiagnostics(issueTitle: String, since startDate: Date) -> String {
		let reports = recentReportMarkdown(since: startDate)
		let reportText =
			reports.isEmpty ? "No report markdown files were created after the test started." : reports.joined(separator: "\n\n---\n\n")
		return """
			Open PR did not appear for \(issueTitle).

			Recent app report markdown:
			\(reportText)
			"""
	}

	private func recentReportMarkdown(since startDate: Date) -> [String] {
		let projectsRoot = FileManager.default
			.homeDirectoryForCurrentUser
			.appendingPathComponent("Library")
			.appendingPathComponent("Application Support")
			.appendingPathComponent("Auditorium")
			.appendingPathComponent("Projects")
		guard
			let enumerator = FileManager.default.enumerator(
				at: projectsRoot,
				includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
				options: [.skipsHiddenFiles]
			)
		else {
			return []
		}
		var reportURLs: [(url: URL, modifiedAt: Date)] = []
		for case let url as URL in enumerator where url.pathExtension == "md" {
			guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
				values.isRegularFile == true,
				let modifiedAt = values.contentModificationDate,
				modifiedAt >= startDate
			else {
				continue
			}
			reportURLs.append((url, modifiedAt))
		}
		return
			reportURLs
			.sorted { $0.modifiedAt > $1.modifiedAt }
			.prefix(3)
			.compactMap { item in
				guard let markdown = try? String(contentsOf: item.url, encoding: .utf8) else {
					return nil
				}
				return "\(item.url.path)\n\(markdown)"
			}
	}

	private func writeFakeCodex(to url: URL) throws {
		try """
		#!/bin/sh
		set -eu
		if [ "${1:-}" = "--version" ]; then
			printf 'codex 999.0.0-ui-smoke\\n'
			exit 0
		fi
		mkdir -p auditorium-ui-smoke
		printf 'Auditorium UI smoke completed at %s\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > auditorium-ui-smoke/result.txt
		printf '%s\\n' "$@" > auditorium-ui-smoke/prompt.txt
		printf 'fake codex wrote auditorium-ui-smoke/result.txt\\n'
		""".write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
	}

	private func writeSymphonyWrapper(to url: URL, fakeBinDirectory: URL, symphonyDirectory: URL) throws {
		try """
		#!/bin/sh
		set -eu
		export PATH="\(fakeBinDirectory.path):$PATH"
		exec "\(symphonyDirectory.appendingPathComponent("symphony").path)" "$@"
		""".write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
	}

	private func deleteKeychainItems(service: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
		]
		SecItemDelete(query as CFDictionary)
	}
}
