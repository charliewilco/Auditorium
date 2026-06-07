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

		let os = ProcessInfo.processInfo.operatingSystemVersion
		let isAppleSilicon = RuntimeDetectionService.isAppleSilicon
		let containerPath = await findExecutable(named: "container", extraPath: "/usr/local/bin/container")
		let containerVersionOutput =
			containerPath == nil ? nil : await commandOutput(containerPath!, arguments: ["system", "version", "--format", "json"])
		let containerVersion = containerVersionOutput.flatMap(Self.containerCLIVersion(from:))
		let containerStatus =
			containerPath == nil ? nil : await commandOutput(containerPath!, arguments: ["system", "status", "--format", "json"])
		let gitPath = await findExecutable(named: "git")
		let codexPath = await findExecutable(named: "codex")
		let ghPath = await findExecutable(named: "gh")

		var checks: [RuntimeHealthCheck] = []
		let appleState: RuntimeHealthState
		let appleDetail: String
		if !isAppleSilicon {
			appleState = .unsupported
			appleDetail = "Apple Container requires Apple silicon."
		}
		else if os.majorVersion < 26 {
			appleState = .unsupported
			appleDetail = "Apple Container is gated until macOS 26+."
		}
		else if containerPath == nil {
			appleState = .needsSetup
			appleDetail = "container CLI was not found."
		}
		else if containerVersionOutput == nil {
			appleState = .unavailable
			appleDetail = "container CLI exists at \(containerPath!), but `container system version --format json` did not respond."
		}
		else if containerStatus == nil {
			appleState = .unavailable
			appleDetail = Self.appleContainerServiceUnavailableDetail(path: containerPath!)
		}
		else {
			appleState = .available
			appleDetail = "container system service is running at \(containerPath!)."
		}
		checks.append(
			RuntimeHealthCheck(
				id: "apple-container",
				name: "Apple Container",
				state: appleState,
				detail: appleDetail,
				version: containerVersion
			)
		)

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

	static func containerCLIVersion(from json: String) -> String? {
		struct Component: Decodable {
			let appName: String
			let version: String
		}

		guard let data = json.data(using: .utf8),
			let components = try? JSONDecoder().decode([Component].self, from: data)
		else {
			return nil
		}

		return components.first(where: { $0.appName == "container" })?.version
	}

	static func appleContainerServiceUnavailableDetail(path: String) -> String {
		"container CLI exists at \(path), but the system service did not respond. Start it manually with `container system start`; Auditorium will not start it automatically."
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
		case .appleContainer:
			.unavailable
		}
	}

	private static func implementationDetail(for kind: RuntimeProviderKind) -> String {
		switch kind {
		case .appleContainer:
			"Apple Container execution is not implemented in v0."
		case .localWorkspace:
			"Implemented with local clone, branch, process, and file workspace execution."
		case .mockRuntime:
			"Implemented as an offline mock runtime."
		}
	}

	static var isAppleSilicon: Bool {
		#if arch(arm64)
			return true
		#else
			return false
		#endif
	}
}
