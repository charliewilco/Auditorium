import Darwin
import Foundation

struct ProcessResult: Sendable {
	let exitCode: Int32
	let standardOutput: String
	let standardError: String
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
	nonisolated(unsafe) private var process: Process?
	nonisolated(unsafe) private var canceled = false

	nonisolated func setProcess(_ process: Process) {
		lock.withLock {
			self.process = process
			if canceled, process.isRunning {
				process.terminate()
			}
		}
	}

	nonisolated func cancel() {
		lock.withLock {
			canceled = true
			if let process, process.isRunning {
				process.terminate()
			}
		}
	}

	nonisolated var isCanceled: Bool {
		lock.withLock { canceled }
	}
}

private final class ProcessExitBox: @unchecked Sendable {
	private let lock = NSLock()
	nonisolated(unsafe) private var status: Int32?
	nonisolated(unsafe) private var continuation: CheckedContinuation<Int32, Never>?

	nonisolated func observe(_ process: Process) {
		process.terminationHandler = { [weak self] process in
			self?.finish(process.terminationStatus)
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

	nonisolated private func finish(_ status: Int32) {
		let continuation: CheckedContinuation<Int32, Never>? = lock.withLock {
			self.status = status
			let continuation = self.continuation
			self.continuation = nil
			return continuation
		}
		continuation?.resume(returning: status)
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
		onStandardOutputLine: (@MainActor (String) async -> Void)? = nil,
		onStandardErrorLine: (@MainActor (String) async -> Void)? = nil,
		allowsNonZeroExit: Bool = false
	) async throws -> ProcessResult {
		let cancellationBox = ProcessCancellationBox()
		let exitBox = ProcessExitBox()
		return try await withTaskCancellationHandler {
			let process = Process()
			let stdout = Pipe()
			let stderr = Pipe()
			process.executableURL = URL(fileURLWithPath: executable)
			process.arguments = arguments
			process.standardOutput = stdout
			process.standardError = stderr
			if let workingDirectory {
				process.currentDirectoryURL = workingDirectory
			}
			if let environment {
				var mergedEnvironment = ProcessInfo.processInfo.environment
				for (key, value) in environment {
					mergedEnvironment[key] = value
				}
				process.environment = mergedEnvironment
			}
			exitBox.observe(process)
			do {
				try process.run()
				stdout.fileHandleForWriting.closeFile()
				stderr.fileHandleForWriting.closeFile()
				cancellationBox.setProcess(process)
			}
			catch {
				throw ProcessCommandError.launchFailed(error.localizedDescription)
			}

			let outputTask = Task {
				try await readLines(from: stdout.fileHandleForReading, onLine: onStandardOutputLine)
			}
			let errorOutputTask = Task {
				try await readLines(from: stderr.fileHandleForReading, onLine: onStandardErrorLine)
			}
			let exitCode = await exitBox.value()
			async let output = collectOutput(from: outputTask, closing: stdout.fileHandleForReading)
			async let errorOutput = collectOutput(from: errorOutputTask, closing: stderr.fileHandleForReading)
			let result = try await ProcessResult(exitCode: exitCode, standardOutput: output, standardError: errorOutput)

			if cancellationBox.isCanceled {
				throw ProcessCommandError.canceled(executable: executable, arguments: arguments)
			}
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
