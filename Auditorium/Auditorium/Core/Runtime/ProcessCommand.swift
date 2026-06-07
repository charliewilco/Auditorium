import Foundation

struct ProcessResult: Sendable {
	let exitCode: Int32
	let standardOutput: String
	let standardError: String
}

enum ProcessCommandError: LocalizedError {
	case launchFailed(String)
	case failed(executable: String, arguments: [String], exitCode: Int32, stderr: String)

	var errorDescription: String? {
		switch self {
		case .launchFailed(let detail):
			detail
		case .failed(let executable, let arguments, let exitCode, let stderr):
			"\(executable) \(arguments.joined(separator: " ")) exited with \(exitCode): \(stderr)"
		}
	}
}

enum ProcessCommand {
	static func run(executable: String, arguments: [String], workingDirectory: URL? = nil) async throws -> ProcessResult {
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
			} catch {
				throw ProcessCommandError.launchFailed(error.localizedDescription)
			}
			process.waitUntilExit()
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
	}
}
