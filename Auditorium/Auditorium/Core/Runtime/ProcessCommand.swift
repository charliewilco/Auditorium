import Darwin
import Foundation

struct ProcessResult: Sendable {
	let exitCode: Int32
	let standardOutput: String
	let standardError: String
}

final class ProcessCancellationToken: @unchecked Sendable {
	private let lock = NSLock()
	nonisolated(unsafe) private var canceled = false
	nonisolated(unsafe) private var handlers: [UUID: @Sendable () -> Void] = [:]

	nonisolated func cancel() {
		let handlersToCall: [@Sendable () -> Void] = lock.withLock {
			canceled = true
			let handlersToCall = Array(handlers.values)
			handlers.removeAll()
			return handlersToCall
		}
		for handler in handlersToCall {
			handler()
		}
	}

	nonisolated var isCanceled: Bool {
		lock.withLock { canceled }
	}

	nonisolated fileprivate func register(_ handler: @escaping @Sendable () -> Void) -> UUID {
		let id = UUID()
		let shouldCallImmediately = lock.withLock {
			if canceled {
				return true
			}
			handlers[id] = handler
			return false
		}
		if shouldCallImmediately {
			handler()
		}
		return id
	}

	nonisolated fileprivate func unregister(_ id: UUID) {
		lock.withLock {
			handlers[id] = nil
		}
	}
}

enum ProcessCommandError: LocalizedError {
	case launchFailed(String)
	case canceled(executable: String, arguments: [String])
	case failed(executable: String, arguments: [String], exitCode: Int32, stderr: String)

	var errorDescription: String? {
		switch self {
		case .launchFailed(let detail):
			detail
		case .canceled(let executable, let arguments):
			"\(executable) \(arguments.joined(separator: " ")) was canceled."
		case .failed(let executable, let arguments, let exitCode, let stderr):
			"\(executable) \(arguments.joined(separator: " ")) exited with \(exitCode): \(stderr)"
		}
	}
}

private final class ProcessCancellationBox: @unchecked Sendable {
	private let lock = NSLock()
	nonisolated(unsafe) private var processID: pid_t?
	nonisolated(unsafe) private var processGroupID: pid_t?
	nonisolated(unsafe) private var canceled = false

	nonisolated func setProcessID(_ processID: pid_t, processGroupID: pid_t) {
		let processToTerminate: (processID: pid_t, processGroupID: pid_t)? = lock.withLock {
			self.processID = processID
			self.processGroupID = processGroupID
			return canceled ? (processID, processGroupID) : nil
		}
		if let processToTerminate {
			terminate(processID: processToTerminate.processID, processGroupID: processToTerminate.processGroupID)
		}
	}

	nonisolated func cancel() {
		let processToTerminate: (processID: pid_t, processGroupID: pid_t)? = lock.withLock {
			canceled = true
			guard let processID, let processGroupID else { return nil }
			return (processID, processGroupID)
		}
		if let processToTerminate {
			terminate(processID: processToTerminate.processID, processGroupID: processToTerminate.processGroupID)
		}
	}

	nonisolated var isCanceled: Bool {
		lock.withLock { canceled }
	}

	nonisolated private func terminate(processID: pid_t, processGroupID: pid_t) {
		if processID > 0 {
			terminateProcessTree(rootPID: processID, processGroupID: processGroupID, signal: SIGTERM)
			usleep(100_000)
			terminateProcessTree(rootPID: processID, processGroupID: processGroupID, signal: SIGKILL)
		}
	}

	nonisolated private func terminateProcessTree(rootPID: pid_t, processGroupID: pid_t, signal: Int32) {
		if processGroupID > 0, processGroupID != Darwin.getpgrp() {
			Darwin.kill(-processGroupID, signal)
		}
		for childPID in descendantProcessIDs(of: rootPID).reversed() {
			Darwin.kill(childPID, signal)
		}
		Darwin.kill(-rootPID, signal)
		Darwin.kill(rootPID, signal)
	}

	nonisolated private func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
		var descendants: [pid_t] = []
		var frontier = [rootPID]
		var seen = Set<pid_t>([rootPID])
		while let parentPID = frontier.popLast() {
			for childPID in childProcessIDs(of: parentPID) where seen.contains(childPID) == false {
				seen.insert(childPID)
				descendants.append(childPID)
				frontier.append(childPID)
			}
		}
		return descendants
	}

	nonisolated private func childProcessIDs(of parentPID: pid_t) -> [pid_t] {
		let process = Process()
		let stdout = Pipe()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
		process.arguments = ["-P", "\(parentPID)"]
		process.standardOutput = stdout
		do {
			try process.run()
			stdout.fileHandleForWriting.closeFile()
			let data = stdout.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			guard process.terminationStatus == 0 else { return [] }
			let output = String(data: data, encoding: .utf8) ?? ""
			return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
		}
		catch {
			return []
		}
	}
}

private final class ProcessExitBox: @unchecked Sendable {
	private let lock = NSLock()
	nonisolated(unsafe) private var status: Int32?
	nonisolated(unsafe) private var continuation: CheckedContinuation<Int32, Never>?

	nonisolated func observe(processID: pid_t) {
		Task.detached { [weak self] in
			var status: Int32 = 0
			_ = Darwin.waitpid(processID, &status, 0)
			self?.finish(Self.exitCode(from: status))
		}
	}

	nonisolated func value() async -> Int32 {
		await withCheckedContinuation { continuation in
			lock.withLock {
				if let status {
					continuation.resume(returning: status)
				}
				else {
					self.continuation = continuation
				}
			}
		}
	}

	nonisolated var currentStatus: Int32? {
		lock.withLock { status }
	}

	nonisolated private func finish(_ status: Int32) {
		let continuation: CheckedContinuation<Int32, Never>? = lock.withLock {
			self.status = status
			let continuation = self.continuation
			self.continuation = nil
			return continuation
		}
		continuation?.resume(returning: status)
	}

	nonisolated private static func exitCode(from waitStatus: Int32) -> Int32 {
		if waitStatus & 0x7f == 0 {
			return (waitStatus >> 8) & 0xff
		}
		return waitStatus & 0x7f
	}
}

enum ProcessCommand {
	private static let outputDrainNanoseconds: UInt64 = 500_000_000

	static func run(executable: String, arguments: [String], workingDirectory: URL? = nil) async throws -> ProcessResult {
		try await runStreaming(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
	}

	static func runStreaming(
		executable: String,
		arguments: [String],
		workingDirectory: URL? = nil,
		environment: [String: String]? = nil,
		cancellationToken: ProcessCancellationToken? = nil,
		onStandardOutputLine: (@MainActor @Sendable (String) async -> Void)? = nil,
		onStandardErrorLine: (@MainActor @Sendable (String) async -> Void)? = nil,
		allowsNonZeroExit: Bool = false
	) async throws -> ProcessResult {
		let cancellationBox = ProcessCancellationBox()
		let exitBox = ProcessExitBox()
		let currentTask = withUnsafeCurrentTask { $0 }
		let tokenRegistration = cancellationToken?.register {
			cancellationBox.cancel()
		}
		defer {
			if let tokenRegistration {
				cancellationToken?.unregister(tokenRegistration)
			}
		}
		return try await withTaskCancellationHandler {
			let stdout = Pipe()
			let stderr = Pipe()
			do {
				let processID = try spawnProcess(
					executable: executable,
					arguments: arguments,
					workingDirectory: workingDirectory,
					environment: environment,
					stdout: stdout,
					stderr: stderr
				)
				stdout.fileHandleForWriting.closeFile()
				stderr.fileHandleForWriting.closeFile()
				exitBox.observe(processID: processID)
				cancellationBox.setProcessID(processID, processGroupID: processID)
			}
			catch {
				throw ProcessCommandError.launchFailed(error.localizedDescription)
			}

			let cancellationWatcher = Task.detached {
				while exitBox.currentStatus == nil {
					if currentTask?.isCancelled == true {
						cancellationBox.cancel()
						return
					}
					try? await Task.sleep(nanoseconds: 10_000_000)
				}
			}
			defer { cancellationWatcher.cancel() }
			let outputTask = Task {
				try await readLines(from: stdout.fileHandleForReading, onLine: onStandardOutputLine)
			}
			let errorOutputTask = Task {
				try await readLines(from: stderr.fileHandleForReading, onLine: onStandardErrorLine)
			}
			let exitCode = await waitForExit(
				exitBox: exitBox,
				cancellationBox: cancellationBox,
				cancellationToken: cancellationToken
			)
			if cancellationBox.isCanceled || cancellationToken?.isCanceled == true {
				outputTask.cancel()
				errorOutputTask.cancel()
				try? stdout.fileHandleForReading.close()
				try? stderr.fileHandleForReading.close()
				throw ProcessCommandError.canceled(executable: executable, arguments: arguments)
			}
			async let output = collectOutput(from: outputTask, closing: stdout.fileHandleForReading)
			async let errorOutput = collectOutput(from: errorOutputTask, closing: stderr.fileHandleForReading)
			let result = try await ProcessResult(exitCode: exitCode, standardOutput: output, standardError: errorOutput)

			guard allowsNonZeroExit || result.exitCode == 0 else {
				throw ProcessCommandError.failed(
					executable: executable,
					arguments: arguments,
					exitCode: result.exitCode,
					stderr: result.standardError
				)
			}
			return result
		} onCancel: {
			cancellationBox.cancel()
		}
	}

	private static func spawnProcess(
		executable: String,
		arguments: [String],
		workingDirectory: URL?,
		environment: [String: String]?,
		stdout: Pipe,
		stderr: Pipe
	) throws -> pid_t {
		var fileActions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&fileActions)
		defer { posix_spawn_file_actions_destroy(&fileActions) }
		posix_spawn_file_actions_adddup2(&fileActions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&fileActions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
		posix_spawn_file_actions_addclose(&fileActions, stdout.fileHandleForReading.fileDescriptor)
		posix_spawn_file_actions_addclose(&fileActions, stderr.fileHandleForReading.fileDescriptor)
		if let workingDirectory {
			posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
		}

		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		let flags = Int16(POSIX_SPAWN_SETPGROUP)
		posix_spawnattr_setflags(&attributes, flags)
		posix_spawnattr_setpgroup(&attributes, 0)

		let argvValues = [executable] + arguments
		var argv = argvValues.map { strdup($0) }
		argv.append(nil)
		defer {
			for pointer in argv {
				free(pointer)
			}
		}

		var mergedEnvironment = ProcessInfo.processInfo.environment
		if let environment {
			for (key, value) in environment {
				mergedEnvironment[key] = value
			}
		}
		var env = mergedEnvironment.map { key, value in strdup("\(key)=\(value)") }
		env.append(nil)
		defer {
			for pointer in env {
				free(pointer)
			}
		}

		var processID: pid_t = 0
		let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
			env.withUnsafeMutableBufferPointer { envBuffer in
				posix_spawnp(&processID, executable, &fileActions, &attributes, argvBuffer.baseAddress, envBuffer.baseAddress)
			}
		}
		guard result == 0 else {
			throw ProcessCommandError.launchFailed(String(cString: strerror(result)))
		}
		return processID
	}

	private static func waitForExit(
		exitBox: ProcessExitBox,
		cancellationBox: ProcessCancellationBox,
		cancellationToken: ProcessCancellationToken?
	) async -> Int32 {
		while true {
			if Task.isCancelled || cancellationToken?.isCanceled == true {
				cancellationBox.cancel()
			}
			if cancellationBox.isCanceled {
				return SIGTERM
			}
			if let status = exitBox.currentStatus {
				return status
			}
			await sleepIgnoringCancellation(nanoseconds: 10_000_000)
		}
	}

	private static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
		await Task.detached {
			try? await Task.sleep(nanoseconds: nanoseconds)
		}.value
	}

	private static func readLines(from fileHandle: FileHandle, onLine: (@MainActor (String) async -> Void)?) async throws -> String {
		var output = Data()
		var lineBuffer = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		let fileDescriptor = fileHandle.fileDescriptor
		while Task.isCancelled == false {
			let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
				Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
			}
			if byteCount > 0 {
				for byte in buffer.prefix(byteCount) {
					output.append(byte)
					if byte == 10 {
						try await emitLine(lineBuffer, onLine: onLine)
						lineBuffer.removeAll(keepingCapacity: true)
					}
					else {
						lineBuffer.append(byte)
					}
				}
			}
			else if byteCount == 0 {
				break
			}
			else if errno != EINTR {
				break
			}
		}
		if lineBuffer.isEmpty == false {
			try await emitLine(lineBuffer, onLine: onLine)
		}
		return String(data: output, encoding: .utf8) ?? ""
	}

	private static func collectOutput(from task: Task<String, Error>, closing fileHandle: FileHandle) async throws -> String {
		let closer = Task {
			try? await Task.sleep(nanoseconds: outputDrainNanoseconds)
			fileHandle.closeFile()
		}
		defer { closer.cancel() }
		return try await task.value
	}

	private static func emitLine(_ data: Data, onLine: (@MainActor (String) async -> Void)?) async throws {
		guard let onLine else { return }
		let line = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
		if line.isEmpty == false {
			await onLine(line)
		}
	}
}
