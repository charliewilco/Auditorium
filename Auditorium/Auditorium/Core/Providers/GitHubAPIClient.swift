import Foundation

protocol GitHubAPITransport: Sendable {
	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: GitHubAPITransport {
	func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		let (data, response) = try await data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw ProviderError.unavailable("GitHub returned a non-HTTP response.")
		}
		return (data, httpResponse)
	}
}

struct GitHubAPIClient: Sendable {
	let token: String
	let baseURL: URL
	let transport: any GitHubAPITransport

	init(token: String, baseURL: URL = URL(string: "https://api.github.com")!, transport: any GitHubAPITransport = URLSession.shared) {
		self.token = token
		self.baseURL = baseURL
		self.transport = transport
	}

	func listRepositories() async throws -> [RepositoryDescriptor] {
		let repositories: [GitHubRepositoryPayload] = try await get(path: "/user/repos?per_page=100&sort=pushed")
		return repositories.map(\.descriptor)
	}

	func listIssues(repositoryFullName: String) async throws -> [TicketDescriptor] {
		let issues: [GitHubIssuePayload] = try await get(path: "/repos/\(repositoryFullName)/issues?state=open&per_page=100")
		return issues.filter { $0.pullRequest == nil }.map { $0.descriptor(repositoryFullName: repositoryFullName) }
	}

	func addComment(repositoryFullName: String, issueNumber: String, body: String) async throws {
		let payload = ["body": body]
		_ = try await send(path: "/repos/\(repositoryFullName)/issues/\(issueNumber)/comments", method: "POST", body: payload) as GitHubCommentPayload
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		let payload = [
			"title": request.title,
			"body": request.body,
			"head": request.branchName,
			"base": request.targetBranch
		]
		let response: GitHubPullRequestPayload = try await send(path: "/repos/\(request.repository.fullName)/pulls", method: "POST", body: payload)
		return PullRequestDescriptor(
			title: response.title,
			url: response.htmlURL,
			branchName: request.branchName,
			targetBranch: request.targetBranch,
			status: .open,
			checksStatus: .pending
		)
	}

	func validateScopes(requiredScopes: Set<String> = ["repo", "read:user"]) async throws -> Set<String> {
		let request = try makeRequest(path: "/user", method: "GET")
		let (_, response) = try await transport.send(request)
		try validate(response: response)
		let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? ""
		let granted = Set(scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
		guard requiredScopes.isSubset(of: granted) else {
			throw ProviderError.unavailable("GitHub credentials are missing required scopes: \(requiredScopes.subtracting(granted).sorted().joined(separator: ", ")).")
		}
		return granted
	}

	private func get<Value: Decodable>(path: String) async throws -> Value {
		try await send(path: path, method: "GET", body: Optional<String>.none)
	}

	private func send<Body: Encodable, Value: Decodable>(path: String, method: String, body: Body?) async throws -> Value {
		var request = try makeRequest(path: path, method: method)
		if let body {
			request.httpBody = try JSONEncoder().encode(body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let (data, response) = try await transport.send(request)
		try validate(response: response)
		return try JSONDecoder.github.decode(Value.self, from: data)
	}

	private func makeRequest(path: String, method: String) throws -> URLRequest {
		guard let url = URL(string: path, relativeTo: baseURL) else {
			throw ProviderError.unavailable("Invalid GitHub API path: \(path)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		return request
	}

	private func validate(response: HTTPURLResponse) throws {
		guard (200..<300).contains(response.statusCode) else {
			if response.statusCode == 401 || response.statusCode == 403 {
				throw ProviderError.unavailable("GitHub credentials are missing, expired, or unauthorized.")
			}
			throw ProviderError.unavailable("GitHub API request failed with HTTP \(response.statusCode).")
		}
	}
}

private extension JSONDecoder {
	static var github: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}
}

struct GitHubRepositoryPayload: Decodable {
	let name: String
	let fullName: String
	let cloneURL: URL
	let htmlURL: URL
	let defaultBranch: String
	let owner: GitHubOwnerPayload

	enum CodingKeys: String, CodingKey {
		case name
		case fullName = "full_name"
		case cloneURL = "clone_url"
		case htmlURL = "html_url"
		case defaultBranch = "default_branch"
		case owner
	}

	var descriptor: RepositoryDescriptor {
		RepositoryDescriptor(
			provider: .github,
			owner: owner.login,
			name: name,
			fullName: fullName,
			cloneURL: cloneURL,
			webURL: htmlURL,
			defaultBranch: defaultBranch
		)
	}
}

struct GitHubOwnerPayload: Decodable {
	let login: String
}

struct GitHubIssuePayload: Decodable {
	let id: Int64
	let nodeID: String?
	let number: Int
	let title: String
	let body: String?
	let htmlURL: URL
	let state: String
	let labels: [GitHubLabelPayload]
	let assignees: [GitHubAssigneePayload]
	let createdAt: Date
	let updatedAt: Date
	let pullRequest: GitHubPullRequestMarker?

	enum CodingKeys: String, CodingKey {
		case id
		case nodeID = "node_id"
		case number
		case title
		case body
		case htmlURL = "html_url"
		case state
		case labels
		case assignees
		case createdAt = "created_at"
		case updatedAt = "updated_at"
		case pullRequest = "pull_request"
	}

	func descriptor(repositoryFullName: String) -> TicketDescriptor {
		TicketDescriptor(
			provider: .githubIssues,
			externalID: String(number),
			title: title,
			body: body ?? "",
			status: state == "open" ? .ready : .completed,
			labels: labels.map(\.name),
			assignee: assignees.first?.login,
			priority: .medium,
			webURL: htmlURL,
			createdAt: createdAt,
			updatedAt: updatedAt,
			estimatedComplexity: 3,
			blockedBy: []
		)
	}
}

struct GitHubLabelPayload: Decodable {
	let name: String
}

struct GitHubAssigneePayload: Decodable {
	let login: String
}

struct GitHubPullRequestMarker: Decodable {}

struct GitHubCommentPayload: Decodable {
	let id: Int64
}

struct GitHubPullRequestPayload: Decodable {
	let title: String
	let htmlURL: URL

	enum CodingKeys: String, CodingKey {
		case title
		case htmlURL = "html_url"
	}
}
