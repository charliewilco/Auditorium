import Foundation

enum ProjectDashboardPreviewData {
	static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
	static let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
	static let firstTicketID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
	static let secondTicketID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

	static var project: Project {
		Project(
			id: projectID,
			name: "Burton Demo",
			repositoryProviderKind: .github,
			repositoryName: "charlie/burton-ios",
			repositoryURL: "https://github.com/charlie/burton-ios",
			defaultBranch: "next",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
	}

	static var tickets: [TicketRecord] {
		[
			TicketRecord(
				id: firstTicketID,
				provider: .githubIssues,
				externalID: "BUR-103",
				title: "Improve low-connectivity timeline cache",
				body: "Timeline loading should reuse the last successful cache snapshot.",
				status: .needsReview,
				labels: ["timeline", "offline"],
				assignee: "Charlie",
				priority: .high,
				webURL: "https://github.com/charlie/burton-ios/issues/103",
				createdAt: .now,
				updatedAt: .now,
				estimatedComplexity: 9,
				sourceProjectID: projectID
			),
			TicketRecord(
				id: secondTicketID,
				provider: .githubIssues,
				externalID: "BUR-104",
				title: "Audit media upload cancellation",
				body: "Cancellation should stop pending uploads and clean temporary files.",
				status: .queued,
				labels: ["media"],
				assignee: nil,
				priority: .medium,
				webURL: "https://github.com/charlie/burton-ios/issues/104",
				createdAt: .now,
				updatedAt: .now,
				estimatedComplexity: 5,
				sourceProjectID: projectID
			),
		]
	}

	static var queueItems: [QueueItemRecord] {
		[
			QueueItemRecord(ticketID: firstTicketID, projectID: projectID, position: 0, priority: .high),
			QueueItemRecord(ticketID: secondTicketID, projectID: projectID, position: 1, priority: .medium),
		]
	}

	static var run: RunRecord {
		RunRecord(
			id: runID,
			projectID: projectID,
			startedAt: Date(timeIntervalSince1970: 1_800),
			status: .running,
			totalTickets: 2,
			completedTickets: 0,
			failedTickets: 0,
			blockedTickets: 0,
			summary: "Running 2 tickets with mock runtime."
		)
	}

	static var ticketRuns: [TicketRunRecord] {
		[
			TicketRunRecord(
				runID: runID,
				ticketID: firstTicketID,
				workspacePath: "/tmp/auditorium/workspaces/bur-103",
				runtimeID: "mock-runtime",
				branchName: "auditorium/bur-103",
				status: .needsReview,
				startedAt: Date(timeIntervalSince1970: 1_810),
				pullRequestURL: "https://github.com/charlie/burton-ios/pull/103",
				summary: "PR ready for review.",
				confidence: 0.86
			),
			TicketRunRecord(
				runID: runID,
				ticketID: secondTicketID,
				workspacePath: "/tmp/auditorium/workspaces/bur-104",
				runtimeID: "mock-runtime",
				branchName: "auditorium/bur-104",
				status: .running,
				startedAt: Date(timeIntervalSince1970: 1_820),
				summary: "Inspecting upload code.",
				confidence: 0.42
			),
		]
	}

	static var events: [RuntimeEventRecord] {
		[
			RuntimeEventRecord(
				runID: runID,
				ticketRunID: firstTicketID,
				timestamp: Date(timeIntervalSince1970: 1_840),
				level: .success,
				category: .pullRequest,
				message: "Opened pull request for BUR-103."
			),
			RuntimeEventRecord(
				runID: runID,
				ticketRunID: secondTicketID,
				timestamp: Date(timeIntervalSince1970: 1_850),
				level: .info,
				category: .agent,
				message: "Agent is inspecting upload cancellation paths."
			),
		]
	}

	static var pullRequests: [PullRequestRecord] {
		[
			PullRequestRecord(
				provider: .github,
				ticketRunID: ticketRuns[0].id,
				title: "BUR-103: Improve low-connectivity timeline cache",
				url: "https://github.com/charlie/burton-ios/pull/103",
				branchName: "auditorium/bur-103",
				targetBranch: "next",
				status: .open,
				checksStatus: .pending
			)
		]
	}

	static var reports: [ReportRecord] {
		[
			ReportRecord(
				projectID: projectID,
				runID: runID,
				title: "Run Report",
				markdown: "Report preview",
				filePath: "/tmp/auditorium/reports/run.md"
			)
		]
	}

	static var preflightSummary: RunPreflightSummary {
		RunPreflightSummary(
			repositoryName: "charlie/burton-ios",
			issueCount: 2,
			enabledIssueCount: 2,
			branchPrefix: "auditorium",
			validationCommand: "xcodebuild test",
			opensPullRequests: true,
			workspaceRoot: "/tmp/auditorium/workspaces",
			accountTitle: "Mock GitHub",
			scopeSummary: "repo, read:user",
			checks: [
				.init(id: "queue", title: "Enabled Tickets", detail: "2 tickets will run.", state: .passed),
				.init(id: "tools", title: "Local Tools", detail: "Mock runtime is available.", state: .passed),
			]
		)
	}

	static var state: ProjectDashboardState {
		ProjectDashboardState(
			project: project,
			tickets: tickets,
			queueItems: queueItems,
			runs: [run],
			ticketRuns: ticketRuns,
			pullRequests: pullRequests,
			reports: reports,
			events: events,
			preflightSummary: preflightSummary,
			now: Date(timeIntervalSince1970: 1_900)
		)
	}
}
