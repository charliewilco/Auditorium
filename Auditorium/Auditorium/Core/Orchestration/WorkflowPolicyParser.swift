import Foundation

struct ParsedWorkflowPolicy: Sendable, Equatable {
	let concurrency: Int
	let maxRetries: Int
	let branchPrefix: String
	let runTests: Bool
	let openPullRequest: Bool
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
		let branchPrefix = values["branch_prefix"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? "auditorium"
		let runTests = boolValue(values["run_tests"], defaultValue: true)
		let openPullRequest = boolValue(values["open_pull_request"], defaultValue: true)
		return ParsedWorkflowPolicy(
			concurrency: concurrency,
			maxRetries: maxRetries,
			branchPrefix: branchPrefix,
			runTests: runTests,
			openPullRequest: openPullRequest,
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
			} else {
				body.append(line)
			}
		}
		return (frontMatter.joined(separator: "\n"), body.joined(separator: "\n"))
	}

	private func parseFrontMatter(_ frontMatter: String) -> [String: String] {
		var values: [String: String] = [:]
		for line in frontMatter.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false, let separator = trimmed.firstIndex(of: ":") else {
				continue
			}
			let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
			let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
			values[key] = value
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

	private func boolValue(_ rawValue: String?, defaultValue: Bool) -> Bool {
		guard let rawValue else {
			return defaultValue
		}
		return ["true", "yes", "1"].contains(rawValue.lowercased())
	}
}
