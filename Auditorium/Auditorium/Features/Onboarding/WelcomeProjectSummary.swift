import Foundation

struct WelcomeProjectSummary: Identifiable, Equatable {
	let id: UUID
	let name: String
	let subtitle: String
	let pullRequestCount: Int
	let repositorySymbol: String
	let issueSymbol: String
	let latestActivityAt: Date

	static let previewRows = [
		WelcomeProjectSummary(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
			name: "Burton",
			subtitle: "last run 3 days ago",
			pullRequestCount: 34,
			repositorySymbol: "shippingbox",
			issueSymbol: "chevron.left.forwardslash.chevron.right",
			latestActivityAt: .now
		),
		WelcomeProjectSummary(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID(),
			name: "Weave Monorepo",
			subtitle: "last run 3 days ago",
			pullRequestCount: 4,
			repositorySymbol: "shippingbox",
			issueSymbol: "chevron.left.forwardslash.chevron.right",
			latestActivityAt: .now
		),
		WelcomeProjectSummary(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000003") ?? UUID(),
			name: "Personal Site",
			subtitle: "last run 3 days ago",
			pullRequestCount: 200,
			repositorySymbol: "shippingbox",
			issueSymbol: "chevron.left.forwardslash.chevron.right",
			latestActivityAt: .now
		),
	]
}
