import Foundation

struct QueueRunSnapshot: Codable, Equatable, Sendable, Identifiable {
	let id: UUID
	let ticketID: UUID
	let position: Int
	let priority: PriorityLevel
	let concurrencyGroup: String
}

struct OrchestrationRunPlan: Equatable, Sendable {
	let concurrency: Int
	let workflowPolicyMarkdown: String
	let retryPolicy: RetryPolicy
	let queueSnapshot: [QueueRunSnapshot]

	var batches: [[QueueRunSnapshot]] {
		stride(from: 0, to: queueSnapshot.count, by: concurrency).map { start in
			Array(queueSnapshot[start..<min(start + concurrency, queueSnapshot.count)])
		}
	}

	static func make(queueItems: [QueueItemRecord], requestedConcurrency: Int, workflowPolicyMarkdown: String) -> OrchestrationRunPlan {
		let parsedPolicy = try? WorkflowPolicyParser().parse(workflowPolicyMarkdown)
		let concurrency = max(1, requestedConcurrency > 0 ? requestedConcurrency : parsedPolicy?.concurrency ?? 1)
		let snapshot = queueItems
			.filter(\.isEnabled)
			.sorted { $0.position < $1.position }
			.map {
				QueueRunSnapshot(
					id: $0.id,
					ticketID: $0.ticketID,
					position: $0.position,
					priority: $0.priority,
					concurrencyGroup: $0.concurrencyGroup
				)
			}
		return OrchestrationRunPlan(
			concurrency: concurrency,
			workflowPolicyMarkdown: workflowPolicyMarkdown,
			retryPolicy: parsedPolicy.map(RetryPolicy.init(parsedPolicy:)) ?? RetryPolicy(maxRetries: 0, maxRetryBackoffMilliseconds: 300_000),
			queueSnapshot: snapshot
		)
	}
}

struct RetryPolicy: Equatable, Sendable {
	let maxRetries: Int
	let maxRetryBackoffMilliseconds: Int

	nonisolated init(maxRetries: Int, maxRetryBackoffMilliseconds: Int) {
		self.maxRetries = max(0, maxRetries)
		self.maxRetryBackoffMilliseconds = max(0, maxRetryBackoffMilliseconds)
	}

	nonisolated init(parsedPolicy: ParsedWorkflowPolicy) {
		self.init(
			maxRetries: parsedPolicy.maxRetries,
			maxRetryBackoffMilliseconds: parsedPolicy.maxRetryBackoffMilliseconds
		)
	}

	func shouldRetry(status: TicketRunStatus, retryCount: Int) -> Bool {
		status == .failed && retryCount < maxRetries
	}

	func backoffMilliseconds(for retryCount: Int) -> Int {
		guard maxRetryBackoffMilliseconds > 0 else { return 0 }
		let attempt = max(0, retryCount)
		let uncapped = 1_000 * (1 << min(attempt, 10))
		return min(uncapped, maxRetryBackoffMilliseconds)
	}
}
