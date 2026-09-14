import Foundation

struct ContainerCleanupPolicy: Equatable, Sendable {
	static let preserveActive = ContainerCleanupPolicy(allowsActiveContainerStop: false)

	let allowsActiveContainerStop: Bool

	init(allowsActiveContainerStop: Bool = false) {
		self.allowsActiveContainerStop = allowsActiveContainerStop
	}
}

struct ContainerCleanupPlan: Equatable, Sendable {
	struct Action: Identifiable, Equatable, Sendable {
		enum Kind: Equatable, Sendable {
			case stopContainer
			case removeTerminalContainer
			case preserve
			case skip
		}

		let id: UUID
		let containerName: String
		let ticketRunID: UUID
		let kind: Kind
		let reason: String
		let workspacePath: String
	}

	let scannedCount: Int
	let actions: [Action]

	var actionableCount: Int {
		actions.filter { $0.kind == .stopContainer || $0.kind == .removeTerminalContainer }.count
	}

	var preservedCount: Int {
		actions.filter { $0.kind == .preserve }.count
	}

	var skippedCount: Int {
		actions.filter { $0.kind == .skip }.count
	}

	var actionableContainerNames: [String] {
		actions
			.filter { $0.kind == .stopContainer || $0.kind == .removeTerminalContainer }
			.map(\.containerName)
	}
}

struct ContainerCleanupPlanningService {
	func makePlan(
		containers: [ContainerRunRecord],
		projectID: UUID,
		policy: ContainerCleanupPolicy = .preserveActive
	) -> ContainerCleanupPlan {
		let actions =
			containers
			.filter { $0.projectID == projectID }
			.sorted { lhs, rhs in
				(lhs.lastSeenAt, lhs.containerName, lhs.id.uuidString) < (rhs.lastSeenAt, rhs.containerName, rhs.id.uuidString)
			}
			.map { action(for: $0, policy: policy) }
		return ContainerCleanupPlan(scannedCount: actions.count, actions: actions)
	}

	private func action(for record: ContainerRunRecord, policy: ContainerCleanupPolicy) -> ContainerCleanupPlan.Action {
		switch record.cleanupEligibility {
		case .eligible:
			if Self.isActive(record.status) {
				if policy.allowsActiveContainerStop {
					return makeAction(
						for: record,
						kind: .stopContainer,
						reason: "Container is active and policy allows explicit stop."
					)
				}
				return makeAction(
					for: record,
					kind: .skip,
					reason: "Container is active; cleanup must be driven by stop or reconciliation first."
				)
			}
			return makeAction(
				for: record,
				kind: .removeTerminalContainer,
				reason: "Container is terminal and eligible for explicit cleanup."
			)
		case .preserveWorkspace:
			return makeAction(
				for: record,
				kind: .preserve,
				reason: "Container artifacts are preserved with the review workspace."
			)
		case .notEligible:
			return makeAction(
				for: record,
				kind: .skip,
				reason: "Container is not eligible for cleanup."
			)
		}
	}

	private func makeAction(
		for record: ContainerRunRecord,
		kind: ContainerCleanupPlan.Action.Kind,
		reason: String
	) -> ContainerCleanupPlan.Action {
		ContainerCleanupPlan.Action(
			id: record.id,
			containerName: record.containerName,
			ticketRunID: record.ticketRunID,
			kind: kind,
			reason: reason,
			workspacePath: record.workspacePath
		)
	}

	private static func isActive(_ status: ContainerRunStatus) -> Bool {
		switch status {
		case .starting, .running:
			return true
		case .completed, .failed, .killed, .orphaned:
			return false
		}
	}
}
