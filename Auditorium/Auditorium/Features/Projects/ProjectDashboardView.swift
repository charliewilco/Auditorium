import SwiftUI

struct ProjectDashboardView: View {
	let project: Project?
	let tickets: [TicketRecord]
	let queueItems: [QueueItemRecord]
	let runs: [RunRecord]
	let ticketRuns: [TicketRunRecord]
	let pullRequests: [PullRequestRecord]
	let runtimeHealth: [RuntimeHealthCheck]
	let symphonyDoctorStatus: SymphonyDoctorStatus?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				header
				statsGrid
				HStack(alignment: .top, spacing: 16) {
					summaryPanel("Repository", symbol: "shippingbox", rows: [
						("Name", project?.repositoryName ?? "No project"),
						("Provider", project?.repositoryProviderKind.title ?? "Unknown"),
						("Default Branch", project?.defaultBranch ?? "Unknown")
					])
					summaryPanel("Issue Source", symbol: "ticket", rows: [
						("Provider", project?.issueProviderKind.title ?? "Unknown"),
						("Open Tickets", "\(tickets.filter { $0.status != .completed }.count)"),
						("Queued", "\(queueItems.count)")
					])
				}
				HStack(alignment: .top, spacing: 16) {
					runtimePanel
					recentRunsPanel
				}
				recentPullRequests
			}
			.padding()
		}
		.navigationTitle("Dashboard")
	}

	private var header: some View {
		HStack {
			VStack(alignment: .leading, spacing: 5) {
				Text(project?.name ?? "No Project")
					.font(.largeTitle.weight(.semibold))
				Text("Visual agent orchestration for \(project?.repositoryName ?? "a repository")")
					.foregroundStyle(.secondary)
			}
			Spacer()
			StatusBadge(title: project?.runtimeProviderKind.title ?? "Mock Runtime", tint: .green)
		}
	}

	private var statsGrid: some View {
		let completedToday = runs.filter { Calendar.current.isDateInToday($0.startedAt) && ($0.status == .completed || $0.status == .completedWithFailures) }.count
		let successRate = runs.isEmpty ? "0%" : "\(Int((Double(runs.filter { $0.status == .completed }.count) / Double(runs.count)) * 100))%"
		return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
			StatCard(title: "Open Tickets", value: "\(tickets.filter { $0.status != .completed }.count)", symbol: "ticket", tint: .blue)
			StatCard(title: "Queued Tickets", value: "\(queueItems.count)", symbol: "text.line.first.and.arrowtriangle.forward", tint: .purple)
			StatCard(title: "Running Agents", value: "\(ticketRuns.filter { $0.status == .running }.count)", symbol: "cpu", tint: .orange)
			StatCard(title: "Completed Today", value: "\(completedToday)", symbol: "checkmark.circle.fill", tint: .green)
			StatCard(title: "PRs Created", value: "\(pullRequests.count)", symbol: "arrow.triangle.pull", tint: .indigo)
			StatCard(title: "Failed Runs", value: "\(runs.filter { $0.status == .failed || $0.status == .completedWithFailures }.count)", symbol: "xmark.octagon.fill", tint: .red)
			StatCard(title: "Avg Completion", value: "6m", symbol: "clock", tint: .teal)
			StatCard(title: "Success Rate", value: successRate, symbol: "chart.line.uptrend.xyaxis", tint: .green)
		}
	}

	private func summaryPanel(_ title: String, symbol: String, rows: [(String, String)]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(title, systemImage: symbol)
				.font(.headline)
			ForEach(rows, id: \.0) { row in
				LabeledContent(row.0, value: row.1)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var runtimePanel: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Runtime Health", systemImage: "cpu")
				.font(.headline)
			SymphonyDoctorStatusView(status: symphonyDoctorStatus)
			ForEach(runtimeHealth) { health in
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
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var recentRunsPanel: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Recent Runs", systemImage: "play.circle.fill")
				.font(.headline)
			ForEach(runs.prefix(5)) { run in
				HStack {
					Text(run.startedAt, format: .dateTime.month().day().hour().minute())
					Spacer()
					StatusBadge(title: run.status.title, tint: run.status.tint)
				}
			}
			if runs.isEmpty {
				Text("No runs yet.")
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}

	private var recentPullRequests: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Recent Pull Requests", systemImage: "arrow.triangle.pull")
				.font(.headline)
			ForEach(pullRequests.prefix(5)) { pr in
				HStack {
					Text(pr.title)
					Spacer()
					Link("Open", destination: URL(string: pr.url) ?? URL(fileURLWithPath: "/"))
				}
			}
			if pullRequests.isEmpty {
				Text("Completed demo tickets will create fake pull request links.")
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}
