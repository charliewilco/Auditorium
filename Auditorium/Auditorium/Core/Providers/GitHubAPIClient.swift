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
	let retryPolicy: GitHubAPIRetryPolicy
	let sleep: @Sendable (Duration) async throws -> Void

	init(
		token: String,
		baseURL: URL = URL(string: "https://api.github.com")!,
		transport: any GitHubAPITransport = URLSession.shared,
		retryPolicy: GitHubAPIRetryPolicy = .default,
		sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
			try await Task.sleep(for: duration)
		}
	) {
		self.token = token
		self.baseURL = baseURL
		self.transport = transport
		self.retryPolicy = retryPolicy
		self.sleep = sleep
	}

	func listRepositories() async throws -> [RepositoryDescriptor] {
		let repositories: [GitHubRepositoryPayload] = try await get(
			path: "/user/repos",
			queryItems: [
				URLQueryItem(name: "per_page", value: "100"),
				URLQueryItem(name: "sort", value: "pushed"),
			]
		)
		return repositories.map(\.descriptor)
	}

	func repository(fullName: String) async throws -> RepositoryDescriptor {
		let repository: GitHubRepositoryPayload = try await get(path: "/repos/\(fullName)")
		return repository.descriptor
	}

	func listIssues(repositoryFullName: String, filter: GitHubIssueFilter = GitHubIssueFilter()) async throws -> [TicketDescriptor] {
		var page = 1
		var issues: [GitHubIssuePayload] = []
		var hasNextPage = true
		while hasNextPage {
			let pageItems =
				filter.queryItems + [
					URLQueryItem(name: "per_page", value: "100"),
					URLQueryItem(name: "page", value: String(page)),
				]
			let response: ([GitHubIssuePayload], HTTPURLResponse) = try await getWithResponse(
				path: "/repos/\(repositoryFullName)/issues",
				queryItems: pageItems
			)
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
		_ =
			try await send(path: "/repos/\(repositoryFullName)/issues/\(issueNumber)/comments", method: "POST", body: payload)
			as GitHubCommentPayload
	}

	func addLabels(repositoryFullName: String, issueNumber: String, labels: [String]) async throws {
		let cleanedLabels = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.isEmpty == false }
		guard cleanedLabels.isEmpty == false else {
			return
		}
		let payload = GitHubLabelsRequest(labels: cleanedLabels)
		_ =
			try await send(path: "/repos/\(repositoryFullName)/issues/\(issueNumber)/labels", method: "POST", body: payload)
			as [GitHubLabelPayload]
	}

	func createPullRequest(_ request: PullRequestRequest) async throws -> PullRequestDescriptor {
		try PullRequestReviewPolicy().validate(request)
		let payload = [
			"title": request.title,
			"body": request.body,
			"head": request.branchName,
			"base": request.targetBranch,
		]
		let response: GitHubPullRequestPayload = try await send(
			path: "/repos/\(request.repository.fullName)/pulls",
			method: "POST",
			body: payload
		)
		return response.descriptor(fallbackBranchName: request.branchName, fallbackTargetBranch: request.targetBranch, checksStatus: .pending)
	}

	func pullRequest(repositoryFullName: String, number: Int) async throws -> PullRequestDescriptor {
		let response: GitHubPullRequestPayload = try await get(path: "/repos/\(repositoryFullName)/pulls/\(number)")
		let checksStatus: ChecksStatus
		if let sha = response.head?.sha, sha.isEmpty == false {
			checksStatus = try await pullRequestChecksStatus(repositoryFullName: repositoryFullName, ref: sha)
		}
		else {
			checksStatus = .pending
		}
		return response.descriptor(fallbackBranchName: "", fallbackTargetBranch: "", checksStatus: checksStatus)
	}

	func validateScopes(requiredScopes: Set<String> = ["repo", "read:user"]) async throws -> Set<String> {
		let request = try makeRequest(path: "/user", method: "GET")
		let (_, response) = try await sendWithRetry(request)
		try validate(response: response)
		let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? ""
		let granted = Set(scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
		guard requiredScopes.isSubset(of: granted) else {
			throw ProviderError.unavailable(
				"GitHub credentials are missing required scopes: \(requiredScopes.subtracting(granted).sorted().joined(separator: ", "))."
			)
		}
		return granted
	}

	private func commitStatus(repositoryFullName: String, ref: String) async throws -> ChecksStatus {
		let response: GitHubCommitStatusPayload = try await get(path: "/repos/\(repositoryFullName)/commits/\(ref)/status")
		return response.checksStatus
	}

	private func commitCheckRuns(repositoryFullName: String, ref: String) async throws -> ChecksStatus {
		let response: GitHubCheckRunsPayload = try await get(
			path: "/repos/\(repositoryFullName)/commits/\(ref)/check-runs",
			queryItems: [
				URLQueryItem(name: "per_page", value: "100")
			]
		)
		return response.checksStatus
	}

	private func pullRequestChecksStatus(repositoryFullName: String, ref: String) async throws -> ChecksStatus {
		let statuses = try await commitStatus(repositoryFullName: repositoryFullName, ref: ref)
		let checkRuns = try await commitCheckRuns(repositoryFullName: repositoryFullName, ref: ref)
		if statuses == .failed || checkRuns == .failed {
			return .failed
		}
		if statuses == .pending || checkRuns == .pending {
			return .pending
		}
		if statuses == .passed || checkRuns == .passed {
			return .passed
		}
		return .skipped
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

	private func send<Body: Encodable, Value: Decodable>(path: String, queryItems: [URLQueryItem], method: String, body: Body?) async throws
		-> Value
	{
		let response: (Value, HTTPURLResponse) = try await sendWithResponse(path: path, queryItems: queryItems, method: method, body: body)
		return response.0
	}

	private func sendWithResponse<Body: Encodable, Value: Decodable>(path: String, queryItems: [URLQueryItem], method: String, body: Body?)
		async throws -> (Value, HTTPURLResponse)
	{
		var request = try makeRequest(path: path, queryItems: queryItems, method: method)
		if let body {
			request.httpBody = try JSONEncoder().encode(body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let (data, response) = try await sendWithRetry(request)
		try validate(response: response)
		return (try JSONDecoder.github.decode(Value.self, from: data), response)
	}

	private func sendWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
		var attempt = 0
		while true {
			do {
				let result = try await transport.send(request)
				guard shouldRetry(response: result.1, attempt: attempt) else {
					return result
				}
				try await sleep(delay(for: result.1, attempt: attempt))
				attempt += 1
			}
			catch is CancellationError {
				throw CancellationError()
			}
			catch {
				guard shouldRetry(error: error, attempt: attempt) else {
					throw error
				}
				try await sleep(delay(for: nil, attempt: attempt))
				attempt += 1
			}
		}
	}

	private func shouldRetry(response: HTTPURLResponse, attempt: Int) -> Bool {
		guard attempt < retryPolicy.maxRetries else {
			return false
		}
		if (500..<600).contains(response.statusCode) || response.statusCode == 429 {
			return true
		}
		return response.statusCode == 403 && response.isGitHubRateLimited
	}

	private func shouldRetry(error: Error, attempt: Int) -> Bool {
		guard attempt < retryPolicy.maxRetries else {
			return false
		}
		guard let urlError = error as? URLError else {
			return false
		}
		return urlError.isTransientGitHubTransportError
	}

	private func delay(for response: HTTPURLResponse?, attempt: Int) -> Duration {
		if let response,
			let preferredDelay = response.gitHubRetryDelay(now: Date()),
			preferredDelay > .zero
		{
			return min(preferredDelay, retryPolicy.maxDelay)
		}
		let cappedBackoff = min(retryPolicy.backoffDelay(for: attempt), retryPolicy.maxDelay)
		let nanoseconds = cappedBackoff.clampedNanoseconds
		guard nanoseconds > 0 else {
			return .zero
		}
		return .nanoseconds(Int64.random(in: 0...Int64(nanoseconds)))
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

struct GitHubAPIRetryPolicy: Equatable, Sendable {
	let maxRetries: Int
	let baseDelay: Duration
	let maxDelay: Duration

	static let `default` = GitHubAPIRetryPolicy(maxRetries: 3, baseDelay: .milliseconds(250), maxDelay: .seconds(5))

	init(maxRetries: Int, baseDelay: Duration, maxDelay: Duration) {
		self.maxRetries = max(0, maxRetries)
		self.baseDelay = max(.zero, baseDelay)
		self.maxDelay = max(.zero, maxDelay)
	}

	func backoffDelay(for attempt: Int) -> Duration {
		let multiplier = 1 << min(max(0, attempt), 10)
		let nanoseconds = baseDelay.clampedNanoseconds
		let scaled = nanoseconds.multipliedReportingOverflow(by: UInt64(multiplier))
		return .nanoseconds(Int64(min(scaled.overflow ? UInt64(Int64.max) : scaled.partialValue, UInt64(Int64.max))))
	}
}

extension HTTPURLResponse {
	fileprivate var hasGitHubNextPage: Bool {
		value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true
	}

	fileprivate var isGitHubRateLimited: Bool {
		(statusCode == 403 || statusCode == 429) && value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
	}

	fileprivate var githubRateLimitResetDescription: String {
		guard let reset = value(forHTTPHeaderField: "X-RateLimit-Reset"),
			let interval = TimeInterval(reset)
		else {
			return "."
		}
		let date = Date(timeIntervalSince1970: interval)
		return " until \(ISO8601DateFormatter().string(from: date))."
	}

	fileprivate func gitHubRetryDelay(now: Date) -> Duration? {
		if let retryAfter = value(forHTTPHeaderField: "Retry-After"),
			let interval = TimeInterval(retryAfter)
		{
			return .seconds(max(0, interval))
		}
		guard let reset = value(forHTTPHeaderField: "X-RateLimit-Reset"),
			let interval = TimeInterval(reset)
		else {
			return nil
		}
		return .seconds(max(0, interval - now.timeIntervalSince1970))
	}
}

extension Duration {
	fileprivate var clampedNanoseconds: UInt64 {
		let components = components
		guard components.seconds > 0 || components.attoseconds > 0 else {
			return 0
		}
		let seconds = UInt64(clamping: components.seconds)
		let secondsNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
		let attosecondNanoseconds = UInt64(clamping: components.attoseconds / 1_000_000_000)
		let total = secondsNanoseconds.partialValue.addingReportingOverflow(attosecondNanoseconds)
		if secondsNanoseconds.overflow || total.overflow {
			return UInt64(Int64.max)
		}
		return min(total.partialValue, UInt64(Int64.max))
	}
}

extension URLError {
	fileprivate var isTransientGitHubTransportError: Bool {
		switch code {
		case .timedOut,
			.cannotFindHost,
			.cannotConnectToHost,
			.networkConnectionLost,
			.dnsLookupFailed,
			.notConnectedToInternet,
			.internationalRoamingOff,
			.callIsActive,
			.dataNotAllowed,
			.secureConnectionFailed:
			true
		default:
			false
		}
	}
}

extension JSONDecoder {
	fileprivate static var github: JSONDecoder {
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

struct GitHubLabelsRequest: Encodable {
	let labels: [String]
}

struct GitHubPullRequestPayload: Decodable {
	let number: Int?
	let title: String
	let htmlURL: URL
	let state: String?
	let draft: Bool?
	let merged: Bool?
	let head: GitHubPullRequestRefPayload?
	let base: GitHubPullRequestRefPayload?

	enum CodingKeys: String, CodingKey {
		case number
		case title
		case htmlURL = "html_url"
		case state
		case draft
		case merged
		case head
		case base
	}

	func descriptor(fallbackBranchName: String, fallbackTargetBranch: String, checksStatus: ChecksStatus) -> PullRequestDescriptor {
		PullRequestDescriptor(
			title: title,
			url: htmlURL,
			branchName: head?.ref ?? fallbackBranchName,
			targetBranch: base?.ref ?? fallbackTargetBranch,
			status: pullRequestStatus,
			checksStatus: checksStatus
		)
	}

	private var pullRequestStatus: PullRequestStatus {
		if merged == true {
			return .merged
		}
		if state == "closed" {
			return .closed
		}
		if draft == true {
			return .draft
		}
		return .open
	}
}

struct GitHubPullRequestRefPayload: Decodable {
	let ref: String
	let sha: String?
}

struct GitHubCommitStatusPayload: Decodable {
	let state: String

	var checksStatus: ChecksStatus {
		switch state {
		case "success":
			return .passed
		case "failure", "error":
			return .failed
		case "pending":
			return .pending
		default:
			return .skipped
		}
	}
}

struct GitHubCheckRunsPayload: Decodable {
	let checkRuns: [GitHubCheckRunPayload]

	enum CodingKeys: String, CodingKey {
		case checkRuns = "check_runs"
	}

	var checksStatus: ChecksStatus {
		guard checkRuns.isEmpty == false else {
			return .skipped
		}
		let statuses = checkRuns.map(\.checksStatus)
		if statuses.contains(.failed) {
			return .failed
		}
		if statuses.contains(.pending) {
			return .pending
		}
		if statuses.contains(.passed) {
			return .passed
		}
		return .skipped
	}
}

struct GitHubCheckRunPayload: Decodable {
	let status: String
	let conclusion: String?

	var checksStatus: ChecksStatus {
		guard status == "completed" else {
			return .pending
		}
		switch conclusion {
		case "success":
			return .passed
		case "failure", "cancelled", "timed_out", "action_required":
			return .failed
		case "skipped", "neutral":
			return .skipped
		default:
			return .pending
		}
	}
}
