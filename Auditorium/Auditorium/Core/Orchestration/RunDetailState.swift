import Foundation

struct RunDetailState: Equatable {
	struct PullRequestRow: Identifiable, Equatable {
		let id: UUID
		let ticketExternalID: String
		let ticketTitle: String
		let pullRequestTitle: String
		let url: String
		let branchName: String
		let targetBranch: String
		let status: PullRequestStatus
		let checksStatus: ChecksStatus

		var statusText: String { status.title }
		var checksStatusText: String { checksStatus.title }
		var routeText: String { "\(branchName) -> \(targetBranch)" }
	}

	let pullRequestRows: [PullRequestRow]

	init(ticketRuns: [TicketRunRecord], tickets: [TicketRecord], pullRequests: [PullRequestRecord]) {
		let ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
		let pullRequestsByTicketRunID = pullRequests.reduce(into: [UUID: PullRequestRecord]()) { result, pullRequest in
			result[pullRequest.ticketRunID] = result[pullRequest.ticketRunID] ?? pullRequest
		}
		pullRequestRows = ticketRuns.compactMap { ticketRun in
			guard let pullRequest = pullRequestsByTicketRunID[ticketRun.id] else {
				return nil
			}
			let ticket = ticketsByID[ticketRun.ticketID]
			return PullRequestRow(
				id: pullRequest.id,
				ticketExternalID: ticket?.externalID ?? "Unknown",
				ticketTitle: ticket?.title ?? "Unknown Ticket",
				pullRequestTitle: pullRequest.title,
				url: pullRequest.url,
				branchName: pullRequest.branchName,
				targetBranch: pullRequest.targetBranch,
				status: pullRequest.status,
				checksStatus: pullRequest.checksStatus
			)
		}
	}
}
