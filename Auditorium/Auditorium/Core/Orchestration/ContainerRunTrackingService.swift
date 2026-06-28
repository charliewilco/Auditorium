import Foundation
import SwiftData

@MainActor
struct ContainerRunTrackingService {
	@discardableResult
	func recordRunningContainer(
		projectID: UUID,
		runID: UUID,
		ticketRun: TicketRunRecord,
		context: ModelContext,
		imageName: String = "",
		environmentVariableNames: [String] = [],
		now: Date = .now
	) throws -> ContainerRunRecord? {
		guard let containerName = Self.containerName(for: ticketRun) else {
			return nil
		}
		let record: ContainerRunRecord
		if let existing = try existingRecord(ticketRunID: ticketRun.id, context: context) {
			record = existing
		}
		else {
			let created = ContainerRunRecord(
				projectID: projectID,
				runID: runID,
				ticketRunID: ticketRun.id,
				runtimeID: ticketRun.runtimeID,
				containerName: containerName,
				status: .running,
				imageName: imageName,
				environmentVariableNames: Self.validEnvironmentNames(environmentVariableNames),
				workspacePath: ticketRun.workspacePath,
				logPath: ticketRun.logPath,
				startedAt: ticketRun.startedAt ?? now,
				lastSeenAt: now,
				cleanupEligibility: .notEligible,
				reconciliationState: .active
			)
			context.insert(created)
			record = created
		}
		record.runtimeID = ticketRun.runtimeID
		record.containerName = containerName
		record.imageName = imageName
		record.environmentVariableNames = Self.validEnvironmentNames(environmentVariableNames)
		record.workspacePath = ticketRun.workspacePath
		record.logPath = ticketRun.logPath
		record.status = .running
		record.cleanupEligibility = .notEligible
		record.reconciliationState = .active
		record.lastSeenAt = now
		return record
	}

	func recordAgentEvent(
		ticketRun: TicketRunRecord,
		event: AgentEvent,
		context: ModelContext,
		now: Date = .now
	) throws {
		guard let record = try existingRecord(ticketRunID: ticketRun.id, context: context) else {
			return
		}
		record.lastSeenAt = now
		if let logPath = event.logPath, logPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
			record.logPath = logPath
			ticketRun.logPath = logPath
		}
		if let exitCode = Self.exitCode(from: event.metadataJSON) {
			record.exitCode = exitCode
		}
	}

	func markTerminal(
		ticketRun: TicketRunRecord,
		context: ModelContext,
		now: Date = .now
	) throws {
		guard let record = try existingRecord(ticketRunID: ticketRun.id, context: context) else {
			return
		}
		record.status = Self.containerStatus(for: ticketRun.status)
		record.logPath = ticketRun.logPath
		record.workspacePath = ticketRun.workspacePath
		record.failureReason = ticketRun.failureReason
		record.endedAt = ticketRun.endedAt ?? now
		record.lastSeenAt = now
		record.cleanupEligibility = Self.cleanupEligibility(for: ticketRun)
		record.reconciliationState = .terminal
	}

	func markKilled(containerName: String, context: ModelContext, now: Date = .now) throws {
		for record in try context.fetch(FetchDescriptor<ContainerRunRecord>()) where record.containerName == containerName {
			record.status = .killed
			record.endedAt = now
			record.lastSeenAt = now
			record.cleanupEligibility = .eligible
			record.reconciliationState = .killed
		}
	}

	func markMissingActiveContainersAsOrphaned(
		context: ModelContext,
		inspectContainer: @MainActor (String) -> Bool,
		now: Date = .now
	) throws -> [String] {
		var orphaned: [String] = []
		for record in try context.fetch(FetchDescriptor<ContainerRunRecord>()) where Self.isActive(record.status) {
			if inspectContainer(record.containerName) == false {
				record.status = .orphaned
				record.endedAt = now
				record.lastSeenAt = now
				record.cleanupEligibility = .eligible
				record.reconciliationState = .orphaned
				orphaned.append(record.containerName)
			}
		}
		return orphaned
	}

	func logTail(for record: ContainerRunRecord, maximumBytes: Int = 8_192) -> String {
		let path = record.logPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard path.isEmpty == false, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
			return ""
		}
		defer { try? handle.close() }
		let length = (try? handle.seekToEnd()) ?? 0
		let offset = length > UInt64(maximumBytes) ? length - UInt64(maximumBytes) : 0
		try? handle.seek(toOffset: offset)
		let data = (try? handle.readToEnd()) ?? Data()
		return String(decoding: data, as: UTF8.self)
	}

	static func containerName(for ticketRun: TicketRunRecord) -> String? {
		guard ticketRun.runtimeID.hasPrefix("container-") else {
			return nil
		}
		return ContainerRuntimeControl.containerName(forRuntimeID: ticketRun.runtimeID)
	}

	private func existingRecord(ticketRunID: UUID, context: ModelContext) throws -> ContainerRunRecord? {
		try context.fetch(FetchDescriptor<ContainerRunRecord>()).first { $0.ticketRunID == ticketRunID }
	}

	private static func validEnvironmentNames(_ names: [String]) -> [String] {
		Array(
			Set(
				names
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter(isValidEnvironmentName)
			)
		)
		.sorted()
	}

	private static func isValidEnvironmentName(_ name: String) -> Bool {
		name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
	}

	private static func exitCode(from metadataJSON: String?) -> Int? {
		guard let metadataJSON,
			let data = metadataJSON.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return nil
		}
		return object["exitCode"] as? Int
	}

	private static func containerStatus(for status: TicketRunStatus) -> ContainerRunStatus {
		switch status {
		case .pending, .preparing:
			return .starting
		case .running:
			return .running
		case .needsReview, .completed:
			return .completed
		case .blocked, .failed, .canceled:
			return .failed
		}
	}

	private static func cleanupEligibility(for ticketRun: TicketRunRecord) -> ContainerCleanupEligibility {
		switch ticketRun.status {
		case .pending, .preparing, .running:
			return .notEligible
		case .needsReview:
			return .preserveWorkspace
		case .completed:
			return ticketRun.pullRequestURL == nil ? .eligible : .preserveWorkspace
		case .blocked:
			return .preserveWorkspace
		case .failed, .canceled:
			return .eligible
		}
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
