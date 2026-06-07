import Foundation

struct GitHubIssueFilterOption: Identifiable, Equatable, Sendable {
	let id: String
	let title: String
	let subtitle: String
	let rawValue: String

	nonisolated init(title: String, subtitle: String, rawValue: String) {
		self.id = rawValue
		self.title = title
		self.subtitle = subtitle
		self.rawValue = rawValue
	}

	nonisolated static func options(from tickets: [TicketDescriptor]) -> [GitHubIssueFilterOption] {
		var options = [
			GitHubIssueFilterOption(title: "Open issues", subtitle: "All open GitHub issues", rawValue: "state:open"),
			GitHubIssueFilterOption(title: "All issues", subtitle: "Open and closed GitHub issues", rawValue: "state:all"),
		]

		let labels = countedValues(tickets.flatMap(\.labels))
		for label in labels {
			options.append(
				GitHubIssueFilterOption(
					title: label.value,
					subtitle: "\(label.count) issue\(label.count == 1 ? "" : "s") with this label",
					rawValue: #"state:open label:"\#(escaped(label.value))""#
				)
			)
		}

		let assignees = countedValues(tickets.compactMap(\.assignee))
		for assignee in assignees {
			options.append(
				GitHubIssueFilterOption(
					title: "@\(assignee.value)",
					subtitle: "\(assignee.count) assigned issue\(assignee.count == 1 ? "" : "s")",
					rawValue: "state:open assignee:\(assignee.value)"
				)
			)
		}

		return options
	}

	nonisolated private static func countedValues(_ values: [String]) -> [(value: String, count: Int)] {
		var counts: [String: (display: String, count: Int)] = [:]
		for value in values {
			let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
			guard display.isEmpty == false else {
				continue
			}
			let key = display.lowercased()
			let current = counts[key] ?? (display, 0)
			counts[key] = (current.display, current.count + 1)
		}
		return counts
			.values
			.sorted {
				if $0.count == $1.count {
					return $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
				}
				return $0.count > $1.count
			}
			.map { ($0.display, $0.count) }
	}

	nonisolated private static func escaped(_ value: String) -> String {
		value.replacingOccurrences(of: #"""#, with: #"\""#)
	}
}

struct GitHubIssueFilter: Equatable, Sendable {
	var state: String
	var labels: [String]
	var assignee: String?
	var mentioned: String?
	var sort: String?
	var direction: String?
	var since: String?

	nonisolated init(
		state: String = "open",
		labels: [String] = [],
		assignee: String? = nil,
		mentioned: String? = nil,
		sort: String? = nil,
		direction: String? = nil,
		since: String? = nil
	) {
		self.state = state
		self.labels = labels
		self.assignee = assignee
		self.mentioned = mentioned
		self.sort = sort
		self.direction = direction
		self.since = since
	}

	nonisolated init(rawValue: String?) {
		let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard trimmed.isEmpty == false else {
			self.init()
			return
		}
		guard trimmed.contains(":") else {
			self.init(
				labels: trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
					$0.isEmpty == false
				}
			)
			return
		}

		var filter = GitHubIssueFilter()
		for token in Self.tokens(from: trimmed) {
			let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
			guard parts.count == 2 else { continue }
			let key = parts[0].lowercased()
			let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
			guard value.isEmpty == false else { continue }
			switch key {
			case "state" where ["open", "closed", "all"].contains(value.lowercased()):
				filter.state = value.lowercased()
			case "label", "labels":
				filter.labels.append(
					contentsOf: value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
						.filter { $0.isEmpty == false }
				)
			case "assignee":
				filter.assignee = value
			case "mentioned":
				filter.mentioned = value
			case "sort" where ["created", "updated", "comments"].contains(value.lowercased()):
				filter.sort = value.lowercased()
			case "direction" where ["asc", "desc"].contains(value.lowercased()):
				filter.direction = value.lowercased()
			case "since":
				filter.since = value
			default:
				continue
			}
		}
		self = filter
	}

	nonisolated var queryItems: [URLQueryItem] {
		var items = [URLQueryItem(name: "state", value: state)]
		if labels.isEmpty == false {
			items.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
		}
		if let assignee {
			items.append(URLQueryItem(name: "assignee", value: assignee))
		}
		if let mentioned {
			items.append(URLQueryItem(name: "mentioned", value: mentioned))
		}
		if let sort {
			items.append(URLQueryItem(name: "sort", value: sort))
		}
		if let direction {
			items.append(URLQueryItem(name: "direction", value: direction))
		}
		if let since {
			items.append(URLQueryItem(name: "since", value: since))
		}
		return items
	}

	nonisolated private static func tokens(from value: String) -> [String] {
		var tokens: [String] = []
		var current = ""
		var quote: Character?
		for character in value {
			if character == "\"" || character == "'" {
				if quote == character {
					quote = nil
				}
				else if quote == nil {
					quote = character
				}
				current.append(character)
			}
			else if character.isWhitespace && quote == nil {
				if current.isEmpty == false {
					tokens.append(current)
					current = ""
				}
			}
			else {
				current.append(character)
			}
		}
		if current.isEmpty == false {
			tokens.append(current)
		}
		return tokens
	}
}
