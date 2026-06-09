import Foundation

struct SymphonyCLIEvent: Decodable, Sendable, Equatable {
	let level: String
	let category: String
	let message: String
	let timestamp: Date
	let metadataJSON: String
	let runID: String?
	let ticketRunID: String?
	let issue: Int?
	let coordinationMessageID: String?

	enum CodingKeys: String, CodingKey {
		case level
		case category
		case message
		case timestamp
		case metadata
		case runID
		case ticketRunID
		case issue
		case coordinationMessageID
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		level = try container.decode(String.self, forKey: .level)
		category = try container.decode(String.self, forKey: .category)
		message = try container.decode(String.self, forKey: .message)
		timestamp = try container.decode(Date.self, forKey: .timestamp)
		if let metadata = try? container.decode([String: String].self, forKey: .metadata),
			let data = try? JSONEncoder().encode(metadata),
			let json = String(data: data, encoding: .utf8)
		{
			metadataJSON = json
		}
		else {
			metadataJSON = "{}"
		}
		runID = try container.decodeIfPresent(String.self, forKey: .runID)
		ticketRunID = try container.decodeIfPresent(String.self, forKey: .ticketRunID)
		issue = try container.decodeIfPresent(Int.self, forKey: .issue)
		coordinationMessageID = try container.decodeIfPresent(String.self, forKey: .coordinationMessageID)
	}
}

struct SymphonyRunSummary: Decodable, Sendable, Equatable {
	let runID: String
	let repo: String
	let issueNumber: Int?
	let workspacePath: String
	let branchName: String
	let status: String
	let pullRequestURL: String?
	let reportPath: String

	enum CodingKeys: String, CodingKey {
		case runID = "run_id"
		case repo
		case issue
		case workspacePath = "workspace_path"
		case branchName = "branch_name"
		case status
		case pullRequestURL = "pull_request_url"
		case reportPath = "report_path"
	}

	private struct IssuePayload: Decodable {
		let number: Int
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		runID = try container.decode(String.self, forKey: .runID)
		repo = try container.decode(String.self, forKey: .repo)
		issueNumber = try container.decodeIfPresent(IssuePayload.self, forKey: .issue)?.number
		workspacePath = try container.decode(String.self, forKey: .workspacePath)
		branchName = try container.decode(String.self, forKey: .branchName)
		status = try container.decode(String.self, forKey: .status)
		pullRequestURL = try container.decodeIfPresent(String.self, forKey: .pullRequestURL)
		reportPath = try container.decode(String.self, forKey: .reportPath)
	}
}

struct SymphonyRunResult: Sendable {
	let events: [SymphonyCLIEvent]
	let summary: SymphonyRunSummary?
}

struct SymphonyCoordinationMessage: Decodable, Sendable, Equatable {
	let recordType: String
	let coordinationMessageID: String
	let runID: String
	let ticketRunID: String
	let issue: Int
	let sourceIssue: Int
	let targetIssue: Int?
	let kind: String
	let summary: String
	let changedFiles: [String]
	let labels: [String]
	let keywords: [String]
	let workspacePath: String?
	let branchName: String?
	let createdAt: Date

	enum CodingKeys: String, CodingKey {
		case recordType = "type"
		case coordinationMessageID
		case runID
		case ticketRunID
		case issue
		case sourceIssue
		case targetIssue
		case kind
		case summary
		case changedFiles
		case labels
		case keywords
		case workspacePath
		case branchName
		case createdAt
	}
}

struct SymphonyQueueRunResult: Sendable {
	let events: [SymphonyCLIEvent]
	let summaries: [SymphonyRunSummary]
	let coordinationMessages: [SymphonyCoordinationMessage]
}

struct SymphonyDoctorCheck: Sendable, Equatable, Identifiable {
	let id: String
	let name: String
	let isOK: Bool
	let detail: String
	let code: String?
}

struct SymphonyDoctorStatus: Sendable, Equatable {
	let state: RuntimeHealthState
	let detail: String
	let workflowDetail: String
	let checks: [SymphonyDoctorCheck]

	static let notChecked = SymphonyDoctorStatus(
		state: .needsSetup,
		detail: "symphony doctor has not run yet.",
		workflowDetail: "No workflow validation result is available.",
		checks: []
	)
}

private struct SymphonyDoctorPayload: Decodable {
	let ok: Bool
	let workflow: SymphonyDoctorWorkflowPayload
	let checks: [SymphonyDoctorCheckPayload]
}

private struct SymphonyDoctorWorkflowPayload: Decodable {
	let ok: Bool
	let workspaceRoot: String?
	let trackerKind: String?
	let maxConcurrentAgents: Int?
	let code: String?
	let message: String?
}

private struct SymphonyDoctorCheckPayload: Decodable {
	let name: String
	let ok: Bool
	let detail: String
	let code: String?
}

struct SymphonyCLIProcessRunner {
	let executablePath: String
	let bundledBinDirectory: String?

	nonisolated init(
		executablePath: String = "/usr/bin/env",
		bundledBinDirectory: String? = Bundle.main.resourceURL?.appending(path: "bin").path()
	) {
		self.executablePath = executablePath
		self.bundledBinDirectory = bundledBinDirectory
	}

	func run(
		repository: String,
		issueNumber: Int,
		workflowPath: URL,
		workspaceRoot: URL,
		mock: Bool = false,
		environment: [String: String] = [:],
		onEvent: (@MainActor (SymphonyCLIEvent) async -> Void)? = nil
	) async throws -> SymphonyRunResult {
		var arguments = [
			"symphony",
			"run",
			"--repo",
			repository,
			"--issue",
			String(issueNumber),
			"--workflow",
			workflowPath.path(),
			"--workspace-root",
			workspaceRoot.path(),
			"--json",
		]
		if mock {
			arguments.append("--mock")
		}
		let result = try await ProcessCommand.runStreaming(
			executable: executablePath,
			arguments: arguments,
			environment: processEnvironment(overrides: environment),
			onStandardOutputLine: { line in
				if let event = try? decodeEvent(line: line) {
					await onEvent?(event)
				}
			}
		)
		return try decode(output: result.standardOutput)
	}

	func runQueue(
		repository: String,
		issueNumbers: [Int],
		workflowPath: URL,
		workspaceRoot: URL,
		mock: Bool = false,
		environment: [String: String] = [:],
		onEvent: (@MainActor (SymphonyCLIEvent) async -> Void)? = nil,
		onCoordinationMessage: (@MainActor (SymphonyCoordinationMessage) async -> Void)? = nil
	) async throws -> SymphonyQueueRunResult {
		var arguments = [
			"symphony",
			"run-queue",
			"--repo",
			repository,
			"--issues",
			issueNumbers.map(String.init).joined(separator: ","),
			"--workflow",
			workflowPath.path(),
			"--workspace-root",
			workspaceRoot.path(),
			"--json",
		]
		if mock {
			arguments.append("--mock")
		}
		let result = try await ProcessCommand.runStreaming(
			executable: executablePath,
			arguments: arguments,
			environment: processEnvironment(overrides: environment),
			onStandardOutputLine: { line in
				if let event = try? decodeEvent(line: line) {
					await onEvent?(event)
				}
				else if let message = try? decodeCoordinationMessage(line: line) {
					await onCoordinationMessage?(message)
				}
			}
		)
		return try decodeQueue(output: result.standardOutput)
	}

	func doctor(workflowPath: URL? = nil) async -> SymphonyDoctorStatus {
		var arguments = [
			"symphony",
			"doctor",
			"--json",
		]
		if let workflowPath {
			arguments.append(contentsOf: ["--workflow", workflowPath.path()])
		}

		do {
			let result = try await ProcessCommand.runStreaming(
				executable: executablePath,
				arguments: arguments,
				environment: processEnvironment(),
				allowsNonZeroExit: true
			)
			return decodeDoctor(output: result.standardOutput, exitCode: result.exitCode, stderr: result.standardError)
		}
		catch {
			return SymphonyDoctorStatus(
				state: .error,
				detail: "Unable to launch symphony doctor: \(error.localizedDescription)",
				workflowDetail: "Workflow validation did not run.",
				checks: []
			)
		}
	}

	func decodeEvent(line: String) throws -> SymphonyCLIEvent {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(SymphonyCLIEvent.self, from: Data(line.utf8))
	}

	func decodeCoordinationMessage(line: String) throws -> SymphonyCoordinationMessage {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(SymphonyCoordinationMessage.self, from: Data(line.utf8))
	}

	func decode(output: String) throws -> SymphonyRunResult {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		var events: [SymphonyCLIEvent] = []
		var summary: SymphonyRunSummary?
		for line in output.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			let data = Data(line.utf8)
			if let event = try? decoder.decode(SymphonyCLIEvent.self, from: data) {
				events.append(event)
			}
			else if let runSummary = try? decoder.decode(SymphonyRunSummary.self, from: data) {
				summary = runSummary
			}
		}
		return SymphonyRunResult(events: events, summary: summary)
	}

	func decodeQueue(output: String) throws -> SymphonyQueueRunResult {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		var events: [SymphonyCLIEvent] = []
		var summaries: [SymphonyRunSummary] = []
		var coordinationMessages: [SymphonyCoordinationMessage] = []
		for line in output.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			let data = Data(line.utf8)
			if let event = try? decoder.decode(SymphonyCLIEvent.self, from: data) {
				events.append(event)
			}
			else if let message = try? decoder.decode(SymphonyCoordinationMessage.self, from: data) {
				coordinationMessages.append(message)
			}
			else if let runSummary = try? decoder.decode(SymphonyRunSummary.self, from: data) {
				summaries.append(runSummary)
			}
		}
		return SymphonyQueueRunResult(events: events, summaries: summaries, coordinationMessages: coordinationMessages)
	}

	func decodeDoctor(output: String, exitCode: Int32, stderr: String) -> SymphonyDoctorStatus {
		guard let data = output.data(using: .utf8),
			let payload = try? JSONDecoder().decode(SymphonyDoctorPayload.self, from: data)
		else {
			return SymphonyDoctorStatus(
				state: .error,
				detail: "symphony doctor returned unreadable output\(exitCode == 0 ? "." : " and exited with \(exitCode).")",
				workflowDetail: stderr.isEmpty ? "No workflow validation details were emitted." : stderr,
				checks: []
			)
		}

		let checks = payload.checks.map { check in
			SymphonyDoctorCheck(
				id: check.name,
				name: check.name,
				isOK: check.ok,
				detail: check.detail,
				code: check.code
			)
		}
		let state: RuntimeHealthState = payload.ok && exitCode == 0 ? .available : .unavailable
		let failingChecks = checks.filter { $0.isOK == false }
		let detail: String
		if state == .available {
			detail = "symphony doctor passed \(checks.count) checks."
		}
		else if failingChecks.isEmpty {
			detail = "symphony doctor exited with \(exitCode)."
		}
		else {
			detail = "symphony doctor found \(failingChecks.count) failing checks."
		}

		return SymphonyDoctorStatus(
			state: state,
			detail: detail,
			workflowDetail: workflowDetail(from: payload.workflow),
			checks: checks
		)
	}

	private func workflowDetail(from workflow: SymphonyDoctorWorkflowPayload) -> String {
		if workflow.ok {
			let trackerKind = workflow.trackerKind ?? "unknown"
			let workspaceRoot = workflow.workspaceRoot ?? "unknown workspace"
			let maxConcurrentAgents = workflow.maxConcurrentAgents.map(String.init) ?? "unknown"
			return "Workflow is valid for \(trackerKind); workspace \(workspaceRoot); max agents \(maxConcurrentAgents)."
		}
		let code = workflow.code.map { "\($0): " } ?? ""
		return "\(code)\(workflow.message ?? "Workflow validation failed.")"
	}

	private func processEnvironment(overrides: [String: String] = [:]) -> [String: String]? {
		var environment = overrides
		if let bundledBinDirectory, FileManager.default.isExecutableFile(atPath: "\(bundledBinDirectory)/symphony") {
			let inheritedPath = overrides["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
			environment["PATH"] = "\(bundledBinDirectory):\(inheritedPath)"
		}
		return environment.isEmpty ? nil : environment
	}
}
