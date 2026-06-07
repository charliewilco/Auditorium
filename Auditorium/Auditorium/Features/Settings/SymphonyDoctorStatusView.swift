import SwiftUI

struct SymphonyDoctorStatusView: View {
	let status: SymphonyDoctorStatus?

	var body: some View {
		let resolvedStatus = status ?? .notChecked
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text("symphony doctor")
						.font(.subheadline.weight(.semibold))
					Text(resolvedStatus.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				StatusBadge(title: resolvedStatus.state.title, tint: resolvedStatus.state.tint)
			}
			Text(resolvedStatus.workflowDetail)
				.font(.caption)
				.foregroundStyle(.secondary)
			if resolvedStatus.checks.isEmpty == false {
				ForEach(resolvedStatus.checks) { check in
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text(check.name)
								.font(.caption.weight(.semibold))
							Text(check.detail)
								.font(.caption2)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
						Spacer()
						StatusBadge(title: check.isOK ? "OK" : "Fail", tint: check.isOK ? .green : .red)
					}
				}
			}
		}
	}
}

#Preview {
	SymphonyDoctorStatusView(
		status: SymphonyDoctorStatus(
			state: .available,
			detail: "symphony doctor passed 4 checks.",
			workflowDetail: "Workflow is valid for github; workspace /tmp/work; max agents 3.",
			checks: [
				SymphonyDoctorCheck(id: "git --version", name: "git --version", isOK: true, detail: "git version 2.50.0", code: nil)
			]
		)
	)
	.padding()
}
