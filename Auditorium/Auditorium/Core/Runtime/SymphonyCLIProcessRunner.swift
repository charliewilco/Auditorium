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
		   let json = String(data: data, encoding: .utf8) {
			metadataJSON = json
		} else {
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
			"--json"
		]
		if mock {
			arguments.append("--mock")
		}
		let result = try await ProcessCommand.runStreaming(executable: executablePath, arguments: arguments, onStandardOutputLine: { line in
			if let event = try? decodeEvent(line: line) {
				await onEvent?(event)
			}
		})
		return try decode(output: result.standardOutput)
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
			} else if let runSummary = try? decoder.decode(SymphonyRunSummary.self, from: data) {
				summary = runSummary
			}
		}
		return SymphonyRunResult(events: events, summary: summary)
	}
}
