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
		let repositories: [GitHubRepositoryPayload] = try await get(path: "/user/repos", queryItems: [
			URLQueryItem(name: "per_page", value: "100"),
			URLQueryItem(name: "sort", value: "pushed")
		])
		return repositories.map(\.descriptor)
	}

	func listIssues(repositoryFullName: String, filter: GitHubIssueFilter = GitHubIssueFilter()) async throws -> [TicketDescriptor] {
		var page = 1
		var issues: [GitHubIssuePayload] = []
		var hasNextPage = true
		while hasNextPage {
			let pageItems = filter.queryItems + [
				URLQueryItem(name: "per_page", value: "100"),
				URLQueryItem(name: "page", value: String(page))
			]
			let response: ([GitHubIssuePayload], HTTPURLResponse) = try await getWithResponse(path: "/repos/\(repositoryFullName)/issues", queryItems: pageItems)
			issues.append(contentsOf: response.0)
			hasNextPage = response.1.hasGitHubNextPage
			page += 1
		}
		return issues.filter { $0.pullRequest == nil }.map { $0.descriptor(repositoryFullName: repositoryFullName) }
	}

	func issue(repositoryFullName: String, issueNumber: String) async throws -> TicketDescriptor {
		let issue: GitHubIssuePayload = try await get(path: "/repos/\(repositoryFullName)/issues/\(issueNumber)")
		guard issue.pullRequest == nil else {
			throw ProviderError.unavailable("GitHub issue \(issueNumber) is a pull request, not an issue.")
		}
		return issue.descriptor(repositoryFullName: repositoryFullName)
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

	private func get<Value: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> Value {
		try await send(path: path, queryItems: queryItems, method: "GET", body: Optional<String>.none)
	}

	private func getWithResponse<Value: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> (Value, HTTPURLResponse) {
		try await sendWithResponse(path: path, queryItems: queryItems, method: "GET", body: Optional<String>.none)
	}

	private func send<Body: Encodable, Value: Decodable>(path: String, method: String, body: Body?) async throws -> Value {
		try await send(path: path, queryItems: [], method: method, body: body)
	}

	private func send<Body: Encodable, Value: Decodable>(path: String, queryItems: [URLQueryItem], method: String, body: Body?) async throws -> Value {
		let response: (Value, HTTPURLResponse) = try await sendWithResponse(path: path, queryItems: queryItems, method: method, body: body)
		return response.0
	}

	private func sendWithResponse<Body: Encodable, Value: Decodable>(path: String, queryItems: [URLQueryItem], method: String, body: Body?) async throws -> (Value, HTTPURLResponse) {
		var request = try makeRequest(path: path, queryItems: queryItems, method: method)
		if let body {
			request.httpBody = try JSONEncoder().encode(body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let (data, response) = try await transport.send(request)
		try validate(response: response)
		return (try JSONDecoder.github.decode(Value.self, from: data), response)
	}

	private func makeRequest(path: String, queryItems: [URLQueryItem] = [], method: String) throws -> URLRequest {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			throw ProviderError.unavailable("Invalid GitHub API path: \(path)")
		}
		let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		components.path = "/" + [basePath, requestPath].filter { $0.isEmpty == false }.joined(separator: "/")
		components.queryItems = queryItems.isEmpty ? nil : queryItems
		guard let url = components.url else {
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
			if response.isGitHubRateLimited {
				throw ProviderError.unavailable("GitHub API rate limit is exhausted\(response.githubRateLimitResetDescription).")
			}
			if response.statusCode == 401 || response.statusCode == 403 {
				throw ProviderError.unavailable("GitHub credentials are missing, expired, or unauthorized.")
			}
			throw ProviderError.unavailable("GitHub API request failed with HTTP \(response.statusCode).")
		}
	}
}

private extension HTTPURLResponse {
	var hasGitHubNextPage: Bool {
		value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true
	}

	var isGitHubRateLimited: Bool {
		(statusCode == 403 || statusCode == 429) && value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
	}

	var githubRateLimitResetDescription: String {
		guard let reset = value(forHTTPHeaderField: "X-RateLimit-Reset"),
			  let interval = TimeInterval(reset) else {
			return "."
		}
		let date = Date(timeIntervalSince1970: interval)
		return " until \(ISO8601DateFormatter().string(from: date))."
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
