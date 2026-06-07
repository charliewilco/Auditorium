import Foundation
import SwiftUI

enum RepositoryProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
	case github
	case gitlab
	case bitbucket
	case azureDevOps
	case genericGit

	var id: String { rawValue }

	var title: String {
		switch self {
		case .github: "GitHub"
		case .gitlab: "GitLab"
		case .bitbucket: "Bitbucket"
		case .azureDevOps: "Azure DevOps"
		case .genericGit: "Generic Git"
		}
	}

	var symbol: String {
		switch self {
		case .genericGit: "terminal"
		default: "shippingbox"
		}
	}
}

enum IssueProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
	case linear
	case asana
	case githubIssues
	case gitlabIssues
	case azureBoards
	case imported

	var id: String { rawValue }

	var title: String {
		switch self {
		case .linear: "Linear"
		case .asana: "Asana"
		case .githubIssues: "GitHub Issues"
		case .gitlabIssues: "GitLab Issues"
		case .azureBoards: "Azure Boards"
		case .imported: "Imported Issues"
		}
	}

	var symbol: String {
		switch self {
		case .imported: "doc.text"
		default: "ticket"
		}
	}
}

enum RuntimeProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
	case localWorkspace
	case mockRuntime

	var id: String { rawValue }

	var title: String {
		switch self {
		case .localWorkspace: "Local Workspace"
		case .mockRuntime: "Mock Runtime"
		}
	}

	var symbol: String {
		switch self {
		case .localWorkspace: "folder"
		case .mockRuntime: "cpu"
		}
	}

	var runtimeHealthCheckID: String {
		switch self {
		case .localWorkspace: "git"
		case .mockRuntime: "mock-runtime"
		}
	}
}

enum AgentProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
	case codex
	case genericCLI
	case mockAgent

	var id: String { rawValue }

	var title: String {
		switch self {
		case .codex: "Codex"
		case .genericCLI: "Generic CLI Agent"
		case .mockAgent: "Mock Agent"
		}
	}

	var symbol: String {
		switch self {
		case .codex: "sparkles"
		case .genericCLI: "terminal"
		case .mockAgent: "wand.and.stars"
		}
	}

	var healthCheckID: String {
		switch self {
		case .codex: "codex"
		case .genericCLI: "generic-cli-agent"
		case .mockAgent: "mock-agent"
		}
	}
}

enum TicketStatus: String, CaseIterable, Codable, Identifiable, Sendable {
	case backlog
	case ready
	case queued
	case running
	case blocked
	case needsReview
	case completed
	case failed
	case canceled

	var id: String { rawValue }

	var title: String {
		switch self {
		case .backlog: "Backlog"
		case .ready: "Ready"
		case .queued: "Queued"
		case .running: "Running"
		case .blocked: "Blocked"
		case .needsReview: "Needs Review"
		case .completed: "Completed"
		case .failed: "Failed"
		case .canceled: "Canceled"
		}
	}

	var tint: Color {
		switch self {
		case .backlog: .secondary
		case .ready: .blue
		case .queued: .purple
		case .running: .orange
		case .blocked: .yellow
		case .needsReview: .indigo
		case .completed: .green
		case .failed: .red
		case .canceled: .gray
		}
	}
}

enum RunStatus: String, CaseIterable, Codable, Identifiable, Sendable {
	case pending
	case running
	case paused
	case completed
	case completedWithFailures
	case canceled
	case failed

	var id: String { rawValue }

	var title: String {
		switch self {
		case .pending: "Pending"
		case .running: "Running"
		case .paused: "Paused"
		case .completed: "Completed"
		case .completedWithFailures: "Completed with Failures"
		case .canceled: "Canceled"
		case .failed: "Failed"
		}
	}

	var tint: Color {
		switch self {
		case .pending: .secondary
		case .running: .orange
		case .paused: .yellow
		case .completed: .green
		case .completedWithFailures: .yellow
		case .canceled: .gray
		case .failed: .red
		}
	}
}

enum TicketRunStatus: String, CaseIterable, Codable, Identifiable, Sendable {
	case pending
	case preparing
	case running
	case blocked
	case needsReview
	case completed
	case failed
	case canceled

	var id: String { rawValue }

	var title: String {
		switch self {
		case .pending: "Pending"
		case .preparing: "Preparing"
		case .running: "Running"
		case .blocked: "Blocked"
		case .needsReview: "Needs Review"
		case .completed: "Completed"
		case .failed: "Failed"
		case .canceled: "Canceled"
		}
	}

	var tint: Color {
		switch self {
		case .pending: .secondary
		case .preparing: .blue
		case .running: .orange
		case .blocked: .yellow
		case .needsReview: .indigo
		case .completed: .green
		case .failed: .red
		case .canceled: .gray
		}
	}
}

enum EventLevel: String, CaseIterable, Codable, Identifiable, Sendable {
	case debug
	case info
	case warning
	case error
	case success

	var id: String { rawValue }

	var title: String { rawValue.capitalized }

	var tint: Color {
		switch self {
		case .debug: .secondary
		case .info: .blue
		case .warning: .yellow
		case .error: .red
		case .success: .green
		}
	}
}

enum EventCategory: String, CaseIterable, Codable, Identifiable, Sendable {
	case orchestration
	case provider
	case git
	case runtime
	case agent
	case tests
	case pullRequest
	case report
	case coordination

	var id: String { rawValue }
}

enum PriorityLevel: String, CaseIterable, Codable, Identifiable, Sendable {
	case low
	case medium
	case high
	case urgent

	var id: String { rawValue }

	var title: String { rawValue.capitalized }

	var sortWeight: Int {
		switch self {
		case .low: 1
		case .medium: 2
		case .high: 3
		case .urgent: 4
		}
	}
}

enum PullRequestStatus: String, CaseIterable, Codable, Identifiable, Sendable {
	case draft
	case open
	case merged
	case closed

	var id: String { rawValue }
	var title: String { rawValue.capitalized }
}

enum ChecksStatus: String, CaseIterable, Codable, Identifiable, Sendable {
	case pending
	case passed
	case failed
	case skipped

	var id: String { rawValue }
	var title: String { rawValue.capitalized }
}

enum RuntimeHealthState: String, CaseIterable, Codable, Identifiable, Sendable {
	case available
	case unavailable
	case needsSetup
	case unsupported
	case error

	var id: String { rawValue }

	var title: String {
		switch self {
		case .available: "Available"
		case .unavailable: "Unavailable"
		case .needsSetup: "Needs Setup"
		case .unsupported: "Unsupported"
		case .error: "Error"
		}
	}

	var tint: Color {
		switch self {
		case .available: .green
		case .unavailable: .orange
		case .needsSetup: .yellow
		case .unsupported: .secondary
		case .error: .red
		}
	}
}

enum SidebarDestination: String, CaseIterable, Identifiable {
	case dashboard
	case tickets
	case queue
	case runs
	case reports
	case settings

	var id: String { rawValue }

	var title: String {
		switch self {
		case .dashboard: "Dashboard"
		case .tickets: "Tickets"
		case .queue: "Queue"
		case .runs: "Runs"
		case .reports: "Reports"
		case .settings: "Settings"
		}
	}

	var symbol: String {
		switch self {
		case .dashboard: "rectangle.3.group"
		case .tickets: "ticket"
		case .queue: "text.line.first.and.arrowtriangle.forward"
		case .runs: "play.circle.fill"
		case .reports: "doc.text"
		case .settings: "gear"
		}
	}
}
