import Foundation

struct RuntimeDetectionService {
	private let staticChecks: [RuntimeHealthCheck]?

	init(staticChecks: [RuntimeHealthCheck]? = nil) {
		self.staticChecks = staticChecks
	}

	func detect() async -> [RuntimeHealthCheck] {
		if let staticChecks {
			return staticChecks
		}

		let gitPath = await findExecutable(named: "git")
		let codexPath = await findExecutable(named: "codex")
		let ghPath = await findExecutable(named: "gh")

		var checks: [RuntimeHealthCheck] = []
		checks.append(check(for: "git", displayName: "Git", path: gitPath))
		checks.append(check(for: "codex", displayName: "Codex CLI", path: codexPath))
		checks.append(check(for: "gh", displayName: "GitHub CLI", path: ghPath))
		return checks
	}

	func health(for runtimeProviderKind: RuntimeProviderKind) async -> RuntimeHealthCheck {
		if runtimeProviderKind == .mockRuntime {
			return RuntimeHealthCheck(
				id: runtimeProviderKind.runtimeHealthCheckID,
				name: runtimeProviderKind.title,
				state: .available,
				detail: "Mock runtime runs fully offline.",
				version: nil
			)
		}

		let checks = await detect()
		if let check = checks.first(where: { $0.id == runtimeProviderKind.runtimeHealthCheckID }) {
			return check
		}

		return RuntimeHealthCheck(
			id: runtimeProviderKind.runtimeHealthCheckID,
			name: runtimeProviderKind.title,
			state: .error,
			detail: "No runtime health check was registered.",
			version: nil
		)
	}

	func requireAvailableRuntime(for runtimeProviderKind: RuntimeProviderKind) async throws {
		if runtimeProviderKind == .mockRuntime {
			return
		}

		let check = await health(for: runtimeProviderKind)
		guard check.state == .available else {
			throw ProviderError.unavailable("\(runtimeProviderKind.title) is \(check.state.title.lowercased()): \(check.detail)")
		}
	}

	func runtimeProviderStatuses() async -> [RuntimeProviderStatus] {
		Self.runtimeProviderStatuses(from: await detect())
	}

	func health(for agentProviderKind: AgentProviderKind) async -> RuntimeHealthCheck {
		switch agentProviderKind {
		case .mockAgent:
			return RuntimeHealthCheck(
				id: agentProviderKind.healthCheckID,
				name: agentProviderKind.title,
				state: .available,
				detail: "Mock agent runs fully offline.",
				version: nil
			)
		case .genericCLI:
			return RuntimeHealthCheck(
				id: agentProviderKind.healthCheckID,
				name: agentProviderKind.title,
				state: .needsSetup,
				detail: "No generic CLI agent command has been configured.",
				version: nil
			)
		case .codex:
			let checks = await detect()
			if let check = checks.first(where: { $0.id == agentProviderKind.healthCheckID }) {
				return check
			}
			return RuntimeHealthCheck(
				id: agentProviderKind.healthCheckID,
				name: agentProviderKind.title,
				state: .error,
				detail: "No Codex CLI health check was registered.",
				version: nil
			)
		}
	}

	func requireAvailableAgent(for agentProviderKind: AgentProviderKind) async throws {
		let check = await health(for: agentProviderKind)
		guard check.state == .available else {
			throw ProviderError.unavailable("\(agentProviderKind.title) is \(check.state.title.lowercased()): \(check.detail)")
		}
	}

	private func check(for id: String, displayName: String, path: String?) -> RuntimeHealthCheck {
		guard let path else {
			return RuntimeHealthCheck(
				id: id,
				name: displayName,
				state: .needsSetup,
				detail: "\(displayName) was not found.",
				version: nil
			)
		}
		return RuntimeHealthCheck(id: id, name: displayName, state: .available, detail: path, version: nil)
	}

	private func findExecutable(named name: String, extraPath: String? = nil) async -> String? {
		if let extraPath, FileManager.default.isExecutableFile(atPath: extraPath) {
			return extraPath
		}
		return await commandOutput("/usr/bin/which", arguments: [name]).flatMap { output in
			output.isEmpty ? nil : output
		}
	}

	private func commandOutput(_ launchPath: String, arguments: [String]) async -> String? {
		await Task.detached {
			let process = Process()
			let pipe = Pipe()
			process.executableURL = URL(fileURLWithPath: launchPath)
			process.arguments = arguments
			process.standardOutput = pipe
			process.standardError = Pipe()
			do {
				try process.run()
				process.waitUntilExit()
				guard process.terminationStatus == 0 else {
					return nil
				}
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			catch {
				return nil
			}
		}.value
	}

	static func runtimeProviderStatuses(from checks: [RuntimeHealthCheck]) -> [RuntimeProviderStatus] {
		RuntimeProviderKind.allCases.map { kind in
			let detection = runtimeDetection(for: kind, checks: checks)
			return RuntimeProviderStatus(
				id: kind.id,
				kind: kind,
				detection: detection,
				implementationState: implementationState(for: kind),
				implementationDetail: implementationDetail(for: kind)
			)
		}
	}

	private static func runtimeDetection(for kind: RuntimeProviderKind, checks: [RuntimeHealthCheck]) -> RuntimeHealthCheck {
		if kind == .mockRuntime {
			return RuntimeHealthCheck(
				id: kind.runtimeHealthCheckID,
				name: kind.title,
				state: .available,
				detail: "Mock runtime runs fully offline.",
				version: nil
			)
		}
		return checks.first(where: { $0.id == kind.runtimeHealthCheckID })
			?? RuntimeHealthCheck(
				id: kind.runtimeHealthCheckID,
				name: kind.title,
				state: .error,
				detail: "No runtime health check was registered.",
				version: nil
			)
	}

	private static func implementationState(for kind: RuntimeProviderKind) -> ProviderImplementationState {
		switch kind {
		case .localWorkspace, .mockRuntime:
			.implemented
		}
	}

	private static func implementationDetail(for kind: RuntimeProviderKind) -> String {
		switch kind {
		case .localWorkspace:
			"Implemented with local clone, branch, process, and file workspace execution."
		case .mockRuntime:
			"Implemented as an offline mock runtime."
		}
	}

}
