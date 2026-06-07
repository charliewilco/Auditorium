import Foundation

struct ParsedWorkflowPolicy: Sendable, Equatable {
	let concurrency: Int
	let maxRetries: Int
	let maxRetryBackoffMilliseconds: Int
	let branchPrefix: String
	let runTests: Bool
	let openPullRequest: Bool
	let handoffStatus: String?
	let updateIssueLabels: Bool
	let validationCommand: String?
	let prompt: String
}

enum WorkflowPolicyParserError: LocalizedError {
	case invalidValue(String)

	var errorDescription: String? {
		switch self {
		case .invalidValue(let detail):
			detail
		}
	}
}

struct WorkflowPolicyParser {
	func parse(_ markdown: String) throws -> ParsedWorkflowPolicy {
		let parts = split(markdown)
		let values = parseFrontMatter(parts.frontMatter)
		let concurrency = try intValue(values["concurrency"], defaultValue: 1, name: "concurrency", range: 1...16)
		let maxRetries = try intValue(values["max_retries"], defaultValue: 0, name: "max_retries", range: 0...10)
		let maxRetryBackoffMilliseconds = try intValue(
			values["max_retry_backoff_ms"],
			defaultValue: 300_000,
			name: "max_retry_backoff_ms",
			range: 0...600_000
		)
		let branchPrefix = try stringValue(values["branch_prefix"], defaultValue: "auditorium", name: "branch_prefix")
		let runTests = try boolValue(values["run_tests"], defaultValue: true, name: "run_tests")
		let openPullRequest = try boolValue(values["open_pull_request"], defaultValue: true, name: "open_pull_request")
		let handoffStatus = optionalString(values["handoff_status"])
		let updateIssueLabels = try boolValue(values["update_issue_labels"], defaultValue: false, name: "update_issue_labels")
		let validationCommand = optionalString(values["validation.command"])
		return ParsedWorkflowPolicy(
			concurrency: concurrency,
			maxRetries: maxRetries,
			maxRetryBackoffMilliseconds: maxRetryBackoffMilliseconds,
			branchPrefix: branchPrefix,
			runTests: runTests,
			openPullRequest: openPullRequest,
			handoffStatus: handoffStatus,
			updateIssueLabels: updateIssueLabels,
			validationCommand: validationCommand,
			prompt: parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
		)
	}

	private func split(_ markdown: String) -> (frontMatter: String, body: String) {
		guard markdown.hasPrefix("---") else {
			return ("", markdown)
		}
		let lines = markdown.components(separatedBy: .newlines)
		var frontMatter: [String] = []
		var body: [String] = []
		var inFrontMatter = true
		for (index, line) in lines.enumerated() {
			if index == 0 {
				continue
			}
			if inFrontMatter, line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
				inFrontMatter = false
				continue
			}
			if inFrontMatter {
				frontMatter.append(line)
			}
			else {
				body.append(line)
			}
		}
		return (frontMatter.joined(separator: "\n"), body.joined(separator: "\n"))
	}

	private func parseFrontMatter(_ frontMatter: String) -> [String: String] {
		var values: [String: String] = [:]
		var section: String?
		for line in frontMatter.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false, let separator = trimmed.firstIndex(of: ":") else {
				continue
			}
			let isNested = line.first?.isWhitespace == true
			let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
			let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
			if isNested, let section {
				values["\(section).\(key)"] = value
			}
			else {
				values[key] = value
				section = value.isEmpty ? key : nil
			}
		}
		return values
	}

	private func intValue(_ rawValue: String?, defaultValue: Int, name: String, range: ClosedRange<Int>) throws -> Int {
		guard let rawValue else {
			return defaultValue
		}
		guard let value = Int(rawValue), range.contains(value) else {
			throw WorkflowPolicyParserError.invalidValue("\(name) must be between \(range.lowerBound) and \(range.upperBound).")
		}
		return value
	}

	private func stringValue(_ rawValue: String?, defaultValue: String, name: String) throws -> String {
		guard let rawValue else {
			return defaultValue
		}
		let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines))
		guard value.isEmpty == false else {
			throw WorkflowPolicyParserError.invalidValue("\(name) must not be empty.")
		}
		return value
	}

	private func boolValue(_ rawValue: String?, defaultValue: Bool, name: String) throws -> Bool {
		guard let rawValue else {
			return defaultValue
		}
		switch rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)).lowercased() {
		case "true", "yes", "1":
			return true
		case "false", "no", "0":
			return false
		default:
			throw WorkflowPolicyParserError.invalidValue("\(name) must be a boolean.")
		}
	}

	private func optionalString(_ rawValue: String?) -> String? {
		let value = rawValue?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)) ?? ""
		return value.isEmpty ? nil : value
	}
}
