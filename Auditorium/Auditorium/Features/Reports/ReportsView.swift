import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportsView: View {
	let project: Project?
	let reports: [ReportRecord]
	let reveal: (ReportRecord) -> Void
	@State private var selectedReportID: UUID?

	var selectedReport: ReportRecord? {
		guard let selectedReportID else { return reports.first }
		return reports.first { $0.id == selectedReportID }
	}

	var body: some View {
		NavigationSplitView {
			List(reports, selection: $selectedReportID) { report in
				VStack(alignment: .leading, spacing: 4) {
					Text(report.title)
					Text(report.createdAt, format: .dateTime.month().day().hour().minute())
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.tag(report.id)
			}
			.frame(minWidth: 240)
		} detail: {
			if let report = selectedReport {
				VStack(alignment: .leading, spacing: 12) {
					HStack {
						Text(report.title)
							.font(.largeTitle.weight(.semibold))
						Spacer()
						Button {
							copy(ReportActions.markdownForCopy(report))
						} label: {
							Label("Copy Markdown", systemImage: "doc.on.doc")
						}
						Button {
							export(report)
						} label: {
							Label("Export .md", systemImage: "square.and.arrow.up")
						}
						Button {
							reveal(report)
						} label: {
							Label("Reveal", systemImage: "finder")
						}
					}
					ScrollView {
						Text(report.markdown)
							.font(.system(.body, design: .monospaced))
							.frame(maxWidth: .infinity, alignment: .leading)
							.textSelection(.enabled)
					}
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
				}
				.padding()
			}
			else {
				EmptyStateView(
					symbol: "doc.text",
					title: "No Reports",
					message: "Run the queue to generate a detailed markdown report.",
					recoverySuggestion: "Completed runs save reports locally so they can be copied, exported, and revealed later."
				)
			}
		}
		.navigationTitle("Reports")
	}

	private func copy(_ markdown: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(markdown, forType: .string)
	}

	private func export(_ report: ReportRecord) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = ReportActions.suggestedExportFileName(for: report)
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			try? ReportActions.export(report, to: url)
		}
	}
}
