import AppKit
import SwiftUI

@MainActor
enum ScreenshotExporter {
	static func exportAndExit() {
		do {
			let directory = URL(
				fileURLWithPath: ProcessInfo.processInfo.environment["AUDITORIUM_SCREENSHOT_DIR"] ?? "/tmp/auditorium-screenshots",
				isDirectory: true
			)
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			let data = ScreenshotData.make()
			let state = AppState()
			state.selectProject(data.project.id)
			state.selectedTicketID = data.tickets.first?.id
			state.selectedRunID = data.run.id
			state.selectedReportID = data.report.id

			try render(
				WelcomeView(createProject: {}, openDemo: {})
					.frame(width: 1280, height: 800),
				name: "01-welcome.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .dashboard) {
					ScreenshotDashboard(data: data)
				},
				name: "02-dashboard.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .tickets) {
					ScreenshotTickets(data: data)
				},
				name: "03-tickets.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .queue) {
					ScreenshotQueue(data: data)
				},
				name: "04-queue.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .runs) {
					ScreenshotRunDetail(data: data)
				},
				name: "05-run-detail.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .reports) {
					ScreenshotReports(data: data)
				},
				name: "06-reports.png",
				to: directory
			)
			try render(
				ScreenshotShell(state: state, data: data, destination: .settings) {
					ScreenshotSettings(data: data)
				},
				name: "07-settings.png",
				to: directory
			)
			print("Wrote Auditorium screenshots to \(directory.path())")
			NSApp.terminate(nil)
		}
		catch {
			fputs("Screenshot export failed: \(error)\n", stderr)
			exit(1)
		}
	}

	private static func render<Content: View>(_ content: Content, name: String, to directory: URL) throws {
		let renderer = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)))
		renderer.scale = 2
		guard let image = renderer.nsImage,
			let tiff = image.tiffRepresentation,
			let representation = NSBitmapImageRep(data: tiff),
			let png = representation.representation(using: .png, properties: [:])
		else {
			throw ScreenshotExportError.renderFailed(name)
		}
		try png.write(to: directory.appending(path: name))
	}
}

private enum ScreenshotExportError: LocalizedError {
	case renderFailed(String)

	var errorDescription: String? {
		switch self {
		case .renderFailed(let name): "Could not render \(name)."
		}
	}
}

private struct ScreenshotShell<Content: View>: View {
	let state: AppState
	let data: ScreenshotData
	let destination: SidebarDestination
	let content: Content

	init(state: AppState, data: ScreenshotData, destination: SidebarDestination, @ViewBuilder content: () -> Content) {
		self.state = state
		self.data = data
		self.destination = destination
		self.content = content()
	}

	var body: some View {
		HStack(spacing: 0) {
			ScreenshotSidebar(project: data.project, selected: destination)
				.frame(width: 220, height: 800)
			Divider()
			content
				.environment(state)
				.frame(width: 720, height: 800)
			Divider()
			ScreenshotInspector(data: data.inspector, project: data.project)
				.frame(width: 340, height: 800)
		}
		.frame(width: 1280, height: 800)
		.onAppear {
			state.selectedDestination = destination
		}
	}
}

private struct ScreenshotSidebar: View {
	let project: Project
	let selected: SidebarDestination

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			Label("Auditorium", systemImage: "music.quarternote.3")
				.font(.title3.weight(.semibold))
				.padding(.top, 22)
			VStack(alignment: .leading, spacing: 8) {
				Text("Projects")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				Label(project.name, systemImage: "music.quarternote.3")
					.font(.callout.weight(.medium))
			}
			VStack(alignment: .leading, spacing: 6) {
				Text("Navigation")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				ForEach(SidebarDestination.allCases) { destination in
					HStack {
						Image(systemName: destination.symbol)
							.frame(width: 22)
						Text(destination.title)
						Spacer()
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 7)
					.background(
						destination == selected ? Color.accentColor.opacity(0.16) : .clear,
						in: RoundedRectangle(cornerRadius: 7)
					)
					.foregroundStyle(destination == selected ? Color.accentColor : Color.primary)
				}
			}
			Spacer()
		}
		.padding(.horizontal, 14)
		.background(Color(nsColor: .controlBackgroundColor))
	}
}

private struct ScreenshotDashboard: View {
	let data: ScreenshotData

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			ScreenshotHeader(
				title: data.project.name,
				subtitle: "Visual agent orchestration for \(data.project.repositoryName)",
				badge: "Mock Runtime"
			)
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
				ScreenshotStat(title: "Open Tickets", value: "10", symbol: "ticket", tint: .blue)
				ScreenshotStat(
					title: "Queued Tickets",
					value: "6",
					symbol: "text.line.first.and.arrowtriangle.forward",
					tint: .purple
				)
				ScreenshotStat(title: "Running Agents", value: "0", symbol: "cpu", tint: .orange)
				ScreenshotStat(title: "Completed Today", value: "1", symbol: "checkmark.circle.fill", tint: .green)
				ScreenshotStat(title: "PRs Created", value: "3", symbol: "arrow.triangle.pull", tint: .indigo)
				ScreenshotStat(title: "Failed Runs", value: "1", symbol: "xmark.octagon.fill", tint: .red)
				ScreenshotStat(title: "Avg Completion", value: "6m", symbol: "clock", tint: .teal)
				ScreenshotStat(title: "Success Rate", value: "50%", symbol: "chart.line.uptrend.xyaxis", tint: .green)
			}
			HStack(alignment: .top, spacing: 12) {
				ScreenshotPanel(title: "Repository", symbol: "shippingbox") {
					ScreenshotField("Name", data.project.repositoryName)
					ScreenshotField("Provider", data.project.repositoryProviderKind.title)
					ScreenshotField("Default Branch", data.project.defaultBranch)
				}
				ScreenshotPanel(title: "Issue Source", symbol: "ticket") {
					ScreenshotField("Provider", data.project.issueProviderKind.title)
					ScreenshotField("Open Tickets", "10")
					ScreenshotField("Queued", "6")
				}
			}
			HStack(alignment: .top, spacing: 12) {
				ScreenshotPanel(title: "Runtime Health", symbol: "cpu") {
					ForEach(data.runtimeHealth.prefix(4)) { health in
						HStack {
							VStack(alignment: .leading) {
								Text(health.name)
								Text(health.detail)
									.font(.caption)
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}
							Spacer()
							StatusBadge(title: health.state.title, tint: health.state.tint)
						}
					}
				}
				ScreenshotPanel(title: "Recent Pull Requests", symbol: "arrow.triangle.pull") {
					ForEach(data.pullRequests.prefix(3)) { pr in
						Text(pr.title)
							.lineLimit(1)
					}
				}
			}
		}
		.padding(18)
	}
}

private struct ScreenshotTickets: View {
	let data: ScreenshotData

	var body: some View {
		VStack(spacing: 0) {
			ScreenshotToolbar(title: "Tickets", primary: "Add to Queue", secondary: "Search, filter, and sort imported issue work")
			ScreenshotTableHeader(columns: ["Ticket", "Status", "Priority", "Complexity"])
			ForEach(data.tickets) { ticket in
				HStack(spacing: 12) {
					VStack(alignment: .leading, spacing: 4) {
						Text("\(ticket.externalID) \(ticket.title)")
							.font(.callout.weight(.medium))
							.lineLimit(1)
						Text(ticket.labels.joined(separator: ", "))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
					StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
						.frame(width: 110)
					Text(ticket.priority.title)
						.frame(width: 78, alignment: .leading)
					Text("\(ticket.estimatedComplexity)")
						.frame(width: 72, alignment: .center)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 11)
				.background(ticket.externalID == "BUR-101" ? Color.accentColor.opacity(0.08) : Color.clear)
				Divider()
			}
			Spacer()
		}
	}
}

private struct ScreenshotQueue: View {
	let data: ScreenshotData

	var body: some View {
		VStack(spacing: 0) {
			ScreenshotToolbar(title: "Queue", primary: "Run Queue", secondary: "Dry Run   Clear Queue   Concurrency 3")
			ForEach(data.queueItems) { item in
				if let ticket = data.tickets.first(where: { $0.id == item.ticketID }) {
					HStack(spacing: 12) {
						Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle")
							.foregroundStyle(item.isEnabled ? .green : .secondary)
						VStack(alignment: .leading, spacing: 5) {
							Text("\(ticket.externalID) \(ticket.title)")
								.font(.headline)
								.lineLimit(1)
							Text(ticket.labels.joined(separator: ", "))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						StatusBadge(title: ticket.status.title, tint: ticket.status.tint)
						Text(ticket.priority.title)
							.frame(width: 72, alignment: .leading)
					}
					.padding(14)
					.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
					.padding(.horizontal, 16)
					.padding(.top, 10)
				}
			}
			Spacer()
		}
	}
}

private struct ScreenshotRunDetail: View {
	let data: ScreenshotData

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			ScreenshotHeader(title: "Run \(data.run.id.uuidString.prefix(8))", subtitle: data.run.summary, badge: data.run.status.title)
			ScreenshotProgress(
				value: Double(data.run.completedTickets + data.run.failedTickets + data.run.blockedTickets)
					/ Double(data.run.totalTickets)
			)
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
				ScreenshotStat(title: "Total", value: "\(data.run.totalTickets)", symbol: "ticket", tint: .blue)
				ScreenshotStat(
					title: "Completed",
					value: "\(data.run.completedTickets)",
					symbol: "checkmark.circle.fill",
					tint: .green
				)
				ScreenshotStat(title: "Failed", value: "\(data.run.failedTickets)", symbol: "xmark.octagon.fill", tint: .red)
				ScreenshotStat(title: "Blocked", value: "\(data.run.blockedTickets)", symbol: "hand.raised.fill", tint: .yellow)
			}
			ScreenshotPanel(title: "Ticket Executions", symbol: "list.bullet.rectangle") {
				ForEach(data.ticketRuns.prefix(5)) { ticketRun in
					let ticket = data.tickets.first { $0.id == ticketRun.ticketID }
					HStack {
						VStack(alignment: .leading) {
							Text(ticket?.title ?? "Unknown Ticket")
								.font(.callout.weight(.medium))
							Text(ticketRun.branchName)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						Spacer()
						Text("\(Int(ticketRun.confidence * 100))%")
						StatusBadge(title: ticketRun.status.title, tint: ticketRun.status.tint)
					}
				}
			}
			ScreenshotPanel(title: "Timeline", symbol: "clock") {
				ForEach(data.events.prefix(7)) { event in
					TimelineRow(event: event)
				}
			}
		}
		.padding(18)
	}
}

private struct ScreenshotReports: View {
	let data: ScreenshotData

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			ScreenshotToolbar(title: "Reports", primary: "Copy Markdown", secondary: "Export .md   Reveal")
			Text(data.report.markdown)
				.font(.system(size: 12, design: .monospaced))
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.padding(14)
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
				.padding(.horizontal, 16)
				.padding(.bottom, 16)
		}
	}
}

private struct ScreenshotSettings: View {
	let data: ScreenshotData

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			ScreenshotHeader(
				title: "Settings",
				subtitle: "Accounts, providers, runtime health, security, reports, and logs",
				badge: "Local-first"
			)
			ScreenshotPanel(title: "Runtime Providers", symbol: "cpu") {
				ForEach(data.runtimeHealth) { health in
					HStack {
						VStack(alignment: .leading) {
							Text(health.name)
							Text(health.detail)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						StatusBadge(title: health.state.title, tint: health.state.tint)
					}
				}
			}
			ScreenshotPanel(title: "Security", symbol: "lock") {
				ScreenshotToggle(title: "Require confirmation before starting runs", isOn: true)
				ScreenshotToggle(title: "Require confirmation before opening PRs", isOn: true)
				ScreenshotToggle(title: "Allow network access", isOn: false)
				ScreenshotToggle(title: "Allow filesystem write", isOn: true)
				ScreenshotField("Runtime isolation", "Mock isolated workspace")
			}
			ScreenshotPanel(title: "Accounts", symbol: "key") {
				Text("Secret values are stored in Keychain under co.charliewil.Auditorium.")
					.foregroundStyle(.secondary)
			}
		}
		.padding(18)
	}
}

private struct ScreenshotInspector: View {
	let data: ScreenshotInspectorData
	let project: Project

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				Label(data.ticket.externalID, systemImage: "ticket")
					.font(.headline)
				Spacer()
				StatusBadge(title: data.ticket.status.title, tint: data.ticket.status.tint)
			}
			Text(data.ticket.title)
				.font(.title3.weight(.semibold))
			Text(data.ticket.body)
				.font(.callout)
				.foregroundStyle(.secondary)
			ScreenshotPanel(title: "Current State", symbol: "sidebar.right") {
				ScreenshotField("Queue", "Position \(data.queueItem.position + 1)")
				ScreenshotField("Latest Run", data.ticketRun.status.title)
				ScreenshotField("Branch", data.ticketRun.branchName)
				ScreenshotField("Pull Request", data.ticketRun.pullRequestURL ?? "None")
				ScreenshotField("Confidence", "\(Int(data.ticketRun.confidence * 100))%")
			}
			ScreenshotPanel(title: "Next Action", symbol: "sparkles") {
				Text("Review the pull request and merge if acceptable.")
					.font(.callout.weight(.medium))
			}
			ScreenshotPanel(title: "Timeline Events", symbol: "clock") {
				ForEach(data.events.prefix(4)) { event in
					TimelineRow(event: event)
				}
			}
			Spacer()
		}
		.padding(16)
		.background(Color(nsColor: .controlBackgroundColor))
	}
}

private struct ScreenshotHeader: View {
	let title: String
	let subtitle: String
	let badge: String

	var body: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading, spacing: 6) {
				Text(title)
					.font(.largeTitle.weight(.semibold))
				Text(subtitle)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			Spacer()
			StatusBadge(title: badge, tint: .green)
		}
	}
}

private struct ScreenshotToolbar: View {
	let title: String
	let primary: String
	let secondary: String

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.largeTitle.weight(.semibold))
				Text(secondary)
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Text(primary)
				.font(.callout.weight(.semibold))
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
				.foregroundStyle(.white)
		}
		.padding(16)
	}
}

private struct ScreenshotPanel<Content: View>: View {
	let title: String
	let symbol: String
	let content: Content

	init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
		self.title = title
		self.symbol = symbol
		self.content = content()
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label(title, systemImage: symbol)
				.font(.headline)
			content
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
	}
}

private struct ScreenshotStat: View {
	let title: String
	let value: String
	let symbol: String
	let tint: Color

	var body: some View {
		VStack(alignment: .leading, spacing: 9) {
			Image(systemName: symbol)
				.foregroundStyle(tint)
			Text(value)
				.font(.title2.weight(.semibold))
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(12)
		.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
		.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
	}
}

private struct ScreenshotField: View {
	let label: String
	let value: String

	init(_ label: String, _ value: String) {
		self.label = label
		self.value = value
	}

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(label)
				.foregroundStyle(.secondary)
			Spacer()
			Text(value)
				.multilineTextAlignment(.trailing)
				.lineLimit(2)
		}
	}
}

private struct ScreenshotToggle: View {
	let title: String
	let isOn: Bool

	var body: some View {
		HStack {
			Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
				.foregroundStyle(isOn ? .green : .secondary)
			Text(title)
			Spacer()
		}
	}
}

private struct ScreenshotProgress: View {
	let value: Double

	var body: some View {
		GeometryReader { proxy in
			ZStack(alignment: .leading) {
				RoundedRectangle(cornerRadius: 4)
					.fill(Color.secondary.opacity(0.12))
				RoundedRectangle(cornerRadius: 4)
					.fill(Color.accentColor)
					.frame(width: proxy.size.width * max(0, min(value, 1)))
			}
		}
		.frame(height: 10)
	}
}

private struct ScreenshotTableHeader: View {
	let columns: [String]

	var body: some View {
		HStack {
			Text(columns[0])
			Spacer()
			ForEach(columns.dropFirst(), id: \.self) { column in
				Text(column)
					.frame(width: column == "Status" ? 110 : 78)
			}
		}
		.font(.caption.weight(.semibold))
		.foregroundStyle(.secondary)
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.background(Color(nsColor: .controlBackgroundColor))
	}
}

private struct ScreenshotData {
	let project: Project
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let run: RunRecord
	let ticketRuns: [TicketRunRecord]
	let events: [RuntimeEventRecord]
	let pullRequests: [PullRequestRecord]
	let report: ReportRecord
	let runtimeHealth: [RuntimeHealthCheck]

	var inspector: ScreenshotInspectorData {
		ScreenshotInspectorData(
			ticket: tickets[0],
			queueItem: queueItems[0],
			ticketRun: ticketRuns[0],
			events: events.filter { $0.ticketRunID == ticketRuns[0].id }
		)
	}

	static func make() -> ScreenshotData {
		let project = Project(
			name: "Burton Demo",
			repositoryProviderKind: .github,
			repositoryName: "charlie/burton-ios",
			repositoryURL: "https://github.com/charlie/burton-ios",
			defaultBranch: "next",
			issueProviderKind: .githubIssues,
			runtimeProviderKind: .mockRuntime,
			agentProviderKind: .mockAgent
		)
		let now = Date()
		let tickets = DemoTickets.all.enumerated().map { index, seed in
			TicketRecord(
				provider: .githubIssues,
				externalID: seed.externalID,
				title: seed.title,
				body: seed.body,
				status: index == 0 ? .needsReview : index == 2 ? .blocked : index == 3 ? .failed : .queued,
				labels: seed.labels,
				assignee: "Charlie",
				priority: seed.priority,
				webURL: "https://github.com/charlie/burton-ios/issues/\(seed.externalID.replacingOccurrences(of: "BUR-", with: ""))",
				createdAt: now.addingTimeInterval(-86_400 * 10),
				updatedAt: now.addingTimeInterval(Double(-index * 1_800)),
				estimatedComplexity: seed.complexity,
				sourceProjectID: project.id
			)
		}
		let queueItems = tickets.prefix(6).enumerated().map { index, ticket in
			QueueItemRecord(ticketID: ticket.id, projectID: project.id, position: index, priority: ticket.priority, isEnabled: index != 4)
		}
		let run = RunRecord(
			projectID: project.id,
			startedAt: now.addingTimeInterval(-720),
			endedAt: now,
			status: .completedWithFailures,
			totalTickets: 6,
			completedTickets: 3,
			failedTickets: 1,
			blockedTickets: 1,
			pullRequestsCreated: 3,
			summary: "Processed 6 queued tickets with 3 pull requests, 1 blocked ticket, and 1 validation failure."
		)
		let ticketRuns = tickets.prefix(6).enumerated().map { index, ticket in
			TicketRunRecord(
				runID: run.id,
				ticketID: ticket.id,
				workspacePath:
					"~/Library/Application Support/Auditorium/Projects/\(project.id.uuidString)/Workspaces/\(ticket.externalID.lowercased())",
				runtimeID: "mock-\(ticket.externalID.lowercased())",
				branchName:
					"auditorium/\(ticket.externalID.lowercased())-\(ticket.title.lowercased().replacingOccurrences(of: " ", with: "-"))",
				status: index == 2 ? .blocked : index == 3 ? .failed : .needsReview,
				startedAt: now.addingTimeInterval(Double(-650 + index * 45)),
				endedAt: now.addingTimeInterval(Double(-420 + index * 55)),
				retryCount: index == 3 ? 1 : 0,
				logPath: "~/Library/Application Support/Auditorium/Projects/\(project.id.uuidString)/Logs/\(ticket.externalID).log",
				pullRequestURL: [0, 1, 5].contains(index) ? "https://example.com/charlie/burton-ios/pull/\(123 + index)" : nil,
				summary: index == 3
					? "Validation failed while exercising SessionStore refresh coverage."
					: "Implementation completed and is ready for review.",
				failureReason: index == 2
					? "Needs product confirmation for cache expiration behavior."
					: index == 3 ? "Swift Testing assertion failed for stale token replacement." : nil,
				confidence: index == 3 ? 0.42 : index == 2 ? 0.54 : 0.88
			)
		}
		let events = makeEvents(run: run, ticketRuns: ticketRuns, tickets: Array(tickets.prefix(6)), now: now)
		let pullRequests = ticketRuns.compactMap { ticketRun -> PullRequestRecord? in
			guard let url = ticketRun.pullRequestURL, let ticket = tickets.first(where: { $0.id == ticketRun.ticketID }) else {
				return nil
			}
			return PullRequestRecord(
				provider: .github,
				ticketRunID: ticketRun.id,
				title: "\(ticket.externalID): \(ticket.title)",
				url: url,
				branchName: ticketRun.branchName,
				targetBranch: "next",
				status: .open,
				checksStatus: .passed
			)
		}
		let markdown = makeReportMarkdown(project: project, run: run, tickets: tickets, ticketRuns: ticketRuns, pullRequests: pullRequests)
		run.reportMarkdown = markdown
		let report = ReportRecord(
			projectID: project.id,
			runID: run.id,
			title: "Auditorium Run Report",
			markdown: markdown,
			filePath: "~/Library/Application Support/Auditorium/Projects/\(project.id.uuidString)/Reports/run-\(run.id.uuidString).md"
		)
		let runtimeHealth = [
			RuntimeHealthCheck(id: "git", name: "Git", state: .available, detail: "/usr/bin/git", version: nil),
			RuntimeHealthCheck(id: "codex", name: "Codex CLI", state: .available, detail: "/opt/homebrew/bin/codex", version: nil),
			RuntimeHealthCheck(id: "gh", name: "GitHub CLI", state: .available, detail: "/opt/homebrew/bin/gh", version: nil),
		]
		return ScreenshotData(
			project: project,
			tickets: tickets,
			queueItems: queueItems,
			run: run,
			ticketRuns: ticketRuns,
			events: events,
			pullRequests: pullRequests,
			report: report,
			runtimeHealth: runtimeHealth
		)
	}

	private static func makeEvents(run: RunRecord, ticketRuns: [TicketRunRecord], tickets: [TicketRecord], now: Date) -> [RuntimeEventRecord] {
		var events = [
			RuntimeEventRecord(
				runID: run.id,
				timestamp: now.addingTimeInterval(-700),
				level: .info,
				category: .orchestration,
				message: "Run started with concurrency 3."
			),
			RuntimeEventRecord(
				runID: run.id,
				timestamp: now.addingTimeInterval(-680),
				level: .info,
				category: .provider,
				message: "Loaded 6 enabled queue items from GitHub Issues."
			),
		]
		for (index, ticketRun) in ticketRuns.enumerated() {
			let ticket = tickets[index]
			events.append(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now.addingTimeInterval(Double(-640 + index * 50)),
					level: .info,
					category: .runtime,
					message: "Created workspace for \(ticket.externalID)."
				)
			)
			events.append(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now.addingTimeInterval(Double(-620 + index * 50)),
					level: .info,
					category: .agent,
					message: "Agent planned implementation for \(ticket.externalID)."
				)
			)
			events.append(
				RuntimeEventRecord(
					runID: run.id,
					ticketRunID: ticketRun.id,
					timestamp: now.addingTimeInterval(Double(-590 + index * 50)),
					level: ticketRun.status == .failed ? .error : .success,
					category: ticketRun.status == .failed ? .tests : .pullRequest,
					message: ticketRun.status == .failed
						? "Validation failed for \(ticket.externalID)." : "Pull request ready for \(ticket.externalID)."
				)
			)
		}
		events.append(
			RuntimeEventRecord(
				runID: run.id,
				timestamp: now.addingTimeInterval(-60),
				level: .success,
				category: .report,
				message: "Generated markdown run report."
			)
		)
		return events
	}

	private static func makeReportMarkdown(
		project: Project,
		run: RunRecord,
		tickets: [TicketRecord],
		ticketRuns: [TicketRunRecord],
		pullRequests: [PullRequestRecord]
	) -> String {
		"""
		# Auditorium Run Report
		Project: \(project.name)
		Repository: \(project.repositoryName)
		Issue Source: \(project.issueProviderKind.title)
		Run ID: \(run.id.uuidString)
		Started: \(run.startedAt)
		Ended: \(run.endedAt ?? Date())
		Duration: 12m

		## Summary
		Queued Tickets: \(run.totalTickets)
		Completed: \(run.completedTickets)
		Failed: \(run.failedTickets)
		Blocked: \(run.blockedTickets)
		Canceled: 0
		Pull Requests Created: \(run.pullRequestsCreated)
		Success Rate: 50%

		## Pull Requests
		| Ticket | PR | Status | Confidence |
		|---|---|---|---|
		\(pullRequests.map { pr in "| \(tickets.first { ticket in ticketRuns.first { $0.id == pr.ticketRunID }?.ticketID == ticket.id }?.externalID ?? "Ticket") | \(pr.url) | \(pr.status.title) | 88% |" }.joined(separator: "\n"))

		## Completed Tickets
		### BUR-101: Fix OAuth refresh race condition
		Status: Needs Review
		Branch: auditorium/bur-101-fix-oauth-refresh-race-condition
		Pull Request: https://example.com/charlie/burton-ios/pull/123
		Duration: 4m
		Confidence: 88%

		#### What changed
		- Serialized refresh token writes in SessionStore.
		- Added regression coverage around launch hydration.

		#### Validation
		- Swift Testing: passed
		- Local runtime checks: passed

		## Failed Tickets
		### BUR-104: Add empty state for muted accounts
		Failure reason: Swift Testing assertion failed for stale token replacement.
		Where it failed: tests
		Retry count: 1
		Suggested next action: Inspect validation failure and retry.

		## Blocked Tickets
		### BUR-103: Improve low-connectivity timeline cache
		Blocked because: Needs product confirmation for cache expiration behavior.
		Suggested next action: Resolve the missing context, then retry.

		## Timeline
		Chronological event timeline is available in the Run Detail screen.
		"""
	}
}

private struct ScreenshotInspectorData {
	let ticket: TicketRecord
	let queueItem: QueueItemRecord
	let ticketRun: TicketRunRecord
	let events: [RuntimeEventRecord]
}
