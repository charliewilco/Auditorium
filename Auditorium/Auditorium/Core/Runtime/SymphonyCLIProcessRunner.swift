import Foundation

struct SymphonyCLIEvent: Decodable, Sendable, Equatable {
	let level: String
	let category: String
	let message: String
	let timestamp: Date
	let metadataJSON: String

	enum CodingKeys: String, CodingKey {
		case level
		case category
		case message
		case timestamp
		case metadata
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
	}
}

struct SymphonyRunSummary: Decodable, Sendable, Equatable {
	let runID: String
	let repo: String
	let workspacePath: String
	let branchName: String
	let status: String
	let pullRequestURL: String?
	let reportPath: String

	enum CodingKeys: String, CodingKey {
		case runID = "run_id"
		case repo
		case workspacePath = "workspace_path"
		case branchName = "branch_name"
		case status
		case pullRequestURL = "pull_request_url"
		case reportPath = "report_path"
	}
}

struct SymphonyRunResult: Sendable {
	let events: [SymphonyCLIEvent]
	let summary: SymphonyRunSummary?
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

	nonisolated init(executablePath: String = "/usr/bin/env") {
		self.executablePath = executablePath
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
			environment: environment.isEmpty ? nil : environment,
			onStandardOutputLine: { line in
				if let event = try? decodeEvent(line: line) {
					await onEvent?(event)
				}
			}
		)
		return try decode(output: result.standardOutput)
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
}
