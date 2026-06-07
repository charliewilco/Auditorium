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

enum ProcessCommand {
	static func run(executable: String, arguments: [String], workingDirectory: URL? = nil) async throws -> ProcessResult {
		let cancellationBox = ProcessCancellationBox()
		return try await withTaskCancellationHandler {
			try await Task.detached {
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
				do {
					try process.run()
					cancellationBox.setProcess(process)
				} catch {
					throw ProcessCommandError.launchFailed(error.localizedDescription)
				}
				process.waitUntilExit()
				if cancellationBox.isCanceled {
					throw ProcessCommandError.canceled(executable: executable, arguments: arguments)
				}
				let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
				let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
				let output = String(data: outputData, encoding: .utf8) ?? ""
				let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
				let result = ProcessResult(exitCode: process.terminationStatus, standardOutput: output, standardError: errorOutput)
				guard result.exitCode == 0 else {
					throw ProcessCommandError.failed(executable: executable, arguments: arguments, exitCode: result.exitCode, stderr: errorOutput)
				}
				return result
			}.value
		} onCancel: {
			cancellationBox.cancel()
		}
	}
}
