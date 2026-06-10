import Foundation

struct RunReviewPacket: Equatable {
	struct TicketSummary: Identifiable, Equatable {
		let id: UUID
		let externalID: String
		let title: String
		let status: TicketRunStatus
		let failureReason: String?
	}

	let pullRequests: [RunDetailState.PullRequestRow]
	let reportTitle: String?
	let reportPath: String?
	let changedFiles: [String]
	let validationSummary: String
	let failedTickets: [TicketSummary]
	let blockedTickets: [TicketSummary]
	let nextAction: String

	static func make(
		run: RunRecord,
		ticketRuns: [TicketRunRecord],
		tickets: [TicketRecord],
		events: [RuntimeEventRecord],
		coordinationMessages: [CoordinationMessageRecord],
		pullRequests: [PullRequestRecord],
		reports: [ReportRecord]
	) -> RunReviewPacket {
		let detailState = RunDetailState(ticketRuns: ticketRuns, tickets: tickets, pullRequests: pullRequests)
		let latestReport =
			reports
			.filter { $0.runID == run.id }
			.sorted { $0.createdAt > $1.createdAt }
			.first
		let changedFiles = changedFiles(
			from: events,
			coordinationMessages: coordinationMessages,
			reportMarkdown: latestReport?.markdown ?? run.reportMarkdown
		)
		let validationSummary = validationSummary(from: events, reportMarkdown: latestReport?.markdown ?? run.reportMarkdown)
		let ticketSummaries = summaries(ticketRuns: ticketRuns, tickets: tickets)
		let failedTickets = ticketSummaries.filter { $0.status == .failed }
		let blockedTickets = ticketSummaries.filter { $0.status == .blocked }
		return RunReviewPacket(
			pullRequests: detailState.pullRequestRows,
			reportTitle: latestReport?.title,
			reportPath: latestReport?.filePath,
			changedFiles: changedFiles,
			validationSummary: validationSummary,
			failedTickets: failedTickets,
			blockedTickets: blockedTickets,
			nextAction: nextAction(
				run: run,
				pullRequestCount: detailState.pullRequestRows.count,
				failedCount: failedTickets.count,
				blockedCount: blockedTickets.count
			)
		)
	}

	private static func summaries(ticketRuns: [TicketRunRecord], tickets: [TicketRecord]) -> [TicketSummary] {
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		return ticketRuns.map { ticketRun in
			let ticket = ticketsByID[ticketRun.ticketID]
			return TicketSummary(
				id: ticketRun.id,
				externalID: ticket?.externalID ?? "Unknown",
				title: ticket?.title ?? "Unknown Ticket",
				status: ticketRun.status,
				failureReason: ticketRun.failureReason
			)
		}
	}

	private static func changedFiles(
		from events: [RuntimeEventRecord],
		coordinationMessages: [CoordinationMessageRecord],
		reportMarkdown: String
	) -> [String] {
		var files: [String] = []
		for event in events {
			files.append(contentsOf: stringListMetadata(event.metadataJSON, keys: ["changedFiles", "changed_files"]))
		}
		for message in coordinationMessages {
			files.append(contentsOf: message.changedFiles)
		}
		if files.isEmpty {
			files.append(contentsOf: changedFilesFromReport(reportMarkdown))
		}
		return Array(NSOrderedSet(array: files).compactMap { $0 as? String })
	}

	private static func validationSummary(from events: [RuntimeEventRecord], reportMarkdown: String) -> String {
		let validationEvents =
			events
			.filter { $0.category == .tests || $0.message.localizedCaseInsensitiveContains("validation") }
			.sorted { $0.timestamp < $1.timestamp }
		if let failed = validationEvents.last(where: { $0.level == .error || $0.message.localizedCaseInsensitiveContains("failed") }) {
			return failed.message
		}
		if validationEvents.contains(where: { $0.message.localizedCaseInsensitiveContains("passed") }) {
			return "Validation passed."
		}
		if let reportValidation = section("Validation", in: reportMarkdown), reportValidation.isEmpty == false {
			return reportValidation
		}
		return "No validation result recorded."
	}

	private static func nextAction(run: RunRecord, pullRequestCount: Int, failedCount: Int, blockedCount: Int) -> String {
		if failedCount > 0 {
			return "Review failed tickets, copy the failure summary, then retry only the affected tickets."
		}
		if blockedCount > 0 {
			return "Resolve blocked tickets before rerunning them."
		}
		if pullRequestCount > 0 {
			return "Review the pull requests and merge only after human approval."
		}
		if run.status == .running {
			return "Monitor live events until the run completes."
		}
		return "Review the generated report and changed files."
	}

	private static func stringListMetadata(_ metadataJSON: String, keys: [String]) -> [String] {
		guard let data = metadataJSON.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return []
		}
		for key in keys {
			if let values = object[key] as? [String] {
				return values
			}
			if let values = object[key] as? [Any] {
				return values.compactMap { $0 as? String }
			}
		}
		return []
	}

	private static func changedFilesFromReport(_ markdown: String) -> [String] {
		guard let changedFiles = section("Changed Files", in: markdown),
			changedFiles.localizedCaseInsensitiveContains("No changed files") == false
		else {
			return []
		}
		return
			changedFiles
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-* `").union(.whitespacesAndNewlines)) }
			.filter { $0.isEmpty == false }
	}

	private static func section(_ title: String, in markdown: String) -> String? {
		let marker = "## \(title)"
		guard let start = markdown.range(of: marker) else {
			return nil
		}
		let rest = markdown[start.upperBound...]
		let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
		return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
