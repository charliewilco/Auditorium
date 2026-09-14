import Foundation

struct RuntimeCommandResult: Sendable {
	let exitCode: Int32
	let output: String
}

struct RuntimeDetectionService {
	private let staticChecks: [RuntimeHealthCheck]?
	private let commandRunner: @Sendable (String, [String]) async -> RuntimeCommandResult?

	init(
		staticChecks: [RuntimeHealthCheck]? = nil,
		commandRunner: (@Sendable (String, [String]) async -> RuntimeCommandResult?)? = nil
	) {
		self.staticChecks = staticChecks
		self.commandRunner =
			commandRunner
			?? { launchPath, arguments in
				await Self.runCommand(launchPath, arguments: arguments)
			}
	}

	func detect() async -> [RuntimeHealthCheck] {
		if let staticChecks {
			return staticChecks
		}

		let gitPath = await findExecutable(named: "git")
		let containerPath = await findExecutable(named: "container")
		let codexPath = await findExecutable(named: "codex")
		let ghPath = await findExecutable(named: "gh")

		var checks: [RuntimeHealthCheck] = []
		checks.append(check(for: "git", displayName: "Git", path: gitPath))
		checks.append(await containerReadiness(path: containerPath))
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

	func onboardingChecks() async -> [RuntimeHealthCheck] {
		if let staticChecks {
			return staticChecks
		}

		let containerPath = await findExecutable(named: "container")
		let codexPath = await findExecutable(named: "codex")
		let ghPath = await findExecutable(named: "gh")

		return [
			await containerReadiness(path: containerPath),
			await codexAuthentication(path: codexPath),
			await githubAuthentication(path: ghPath),
		]
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
		guard let result = await commandRunner(launchPath, arguments), result.exitCode == 0 else {
			return nil
		}
		return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func commandResult(_ launchPath: String, arguments: [String]) async -> RuntimeCommandResult? {
		await commandRunner(launchPath, arguments)
	}

	private func containerReadiness(path: String?) async -> RuntimeHealthCheck {
		guard let path else {
			return RuntimeHealthCheck(
				id: "container",
				name: "Container CLI",
				state: .needsSetup,
				detail: "container was not found.",
				version: nil
			)
		}

		let version = await commandOutput(path, arguments: ["--version"])
		let status = await commandResult(path, arguments: ["system", "status"])
		if status?.exitCode == 0 {
			return RuntimeHealthCheck(
				id: "container",
				name: "Container CLI",
				state: .available,
				detail: "Container CLI is installed and the container system is running.",
				version: version
			)
		}

		return RuntimeHealthCheck(
			id: "container",
			name: "Container CLI",
			state: .unavailable,
			detail: containerUnavailableDetail(path: path, output: status?.output),
			version: version
		)
	}

	private func codexAuthentication(path: String?) async -> RuntimeHealthCheck {
		guard let path else {
			return RuntimeHealthCheck(
				id: "codex-auth",
				name: "Codex",
				state: .needsSetup,
				detail: "Codex CLI was not found.",
				version: nil
			)
		}

		let version = await commandOutput(path, arguments: ["--version"])
		let status = await commandResult(path, arguments: ["login", "status"])
		if status?.exitCode == 0 {
			let output = status?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			return RuntimeHealthCheck(
				id: "codex-auth",
				name: "Codex",
				state: .available,
				detail: output.isEmpty ? "Codex CLI is authenticated." : output,
				version: version
			)
		}

		return RuntimeHealthCheck(
			id: "codex-auth",
			name: "Codex",
			state: .needsSetup,
			detail: "Codex CLI is installed at \(path), but no authenticated session was found.",
			version: version
		)
	}

	private func githubAuthentication(path: String?) async -> RuntimeHealthCheck {
		guard let path else {
			return RuntimeHealthCheck(
				id: "github-auth",
				name: "GitHub",
				state: .needsSetup,
				detail: "GitHub CLI was not found.",
				version: nil
			)
		}

		let version = await commandOutput(path, arguments: ["--version"])?.components(separatedBy: .newlines).first
		let status = await commandResult(path, arguments: ["auth", "status", "--hostname", "github.com"])
		if status?.exitCode == 0 {
			return RuntimeHealthCheck(
				id: "github-auth",
				name: "GitHub",
				state: .available,
				detail: githubAuthenticatedDetail(output: status?.output),
				version: version
			)
		}

		return RuntimeHealthCheck(
			id: "github-auth",
			name: "GitHub",
			state: .needsSetup,
			detail: "GitHub CLI is installed at \(path), but github.com authentication is missing or invalid.",
			version: version
		)
	}

	private func containerUnavailableDetail(path: String, output: String?) -> String {
		let trimmedOutput = output?.trimmingCharacters(in: .whitespacesAndNewlines)
		if let trimmedOutput, trimmedOutput.isEmpty == false {
			return "Container CLI is installed at \(path), but \(trimmedOutput)."
		}
		return "Container CLI is installed at \(path), but the container system is not running."
	}

	private func githubAuthenticatedDetail(output: String?) -> String {
		guard let account = githubAccountName(from: output) else {
			return "GitHub CLI is authenticated for github.com."
		}
		return "GitHub CLI is authenticated for github.com as \(account)."
	}

	private func githubAccountName(from output: String?) -> String? {
		guard let output else { return nil }
		for line in output.components(separatedBy: .newlines) where line.contains("Logged in to github.com account ") {
			guard let accountRange = line.range(of: "account ") else { continue }
			let suffix = line[accountRange.upperBound...]
			if let end = suffix.firstIndex(where: { $0 == " " || $0 == "(" }) {
				return String(suffix[..<end])
			}
			return String(suffix)
		}
		return nil
	}

	private static func runCommand(_ launchPath: String, arguments: [String]) async -> RuntimeCommandResult? {
		await Task.detached {
			let process = Process()
			let pipe = Pipe()
			process.executableURL = URL(fileURLWithPath: launchPath)
			process.arguments = arguments
			process.standardOutput = pipe
			process.standardError = pipe
			do {
				try process.run()
				process.waitUntilExit()
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
				return RuntimeCommandResult(exitCode: process.terminationStatus, output: output)
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
		case .localWorkspace, .containerWorkspace, .mockRuntime:
			.implemented
		}
	}

	private static func implementationDetail(for kind: RuntimeProviderKind) -> String {
		switch kind {
		case .localWorkspace:
			"Implemented with local clone, branch, process, and file workspace execution."
		case .containerWorkspace:
			"Implemented with Apple container workspaces, ephemeral Codex auth mounts, and runtime environment injection."
		case .mockRuntime:
			"Implemented as an offline mock runtime."
		}
	}

}
