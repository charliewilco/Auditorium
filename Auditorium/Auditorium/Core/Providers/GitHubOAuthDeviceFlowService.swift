import Foundation

enum GitHubOAuthDeviceFlowError: LocalizedError, Equatable {
	case missingDeviceEndpoint
	case expired
	case accessDenied
	case unsupportedResponse(String)

	var errorDescription: String? {
		switch self {
		case .missingDeviceEndpoint:
			"GitHub OAuth device flow is not configured."
		case .expired:
			"GitHub device authorization expired."
		case .accessDenied:
			"GitHub authorization was denied."
		case .unsupportedResponse(let detail):
			"GitHub OAuth returned an unsupported response: \(detail)"
		}
	}
}

struct GitHubOAuthDeviceCode: Decodable, Sendable, Equatable {
	let deviceCode: String
	let userCode: String
	let verificationURI: URL
	let verificationURIComplete: URL?
	let expiresIn: Int
	let interval: Int

	enum CodingKeys: String, CodingKey {
		case deviceCode = "device_code"
		case userCode = "user_code"
		case verificationURI = "verification_uri"
		case verificationURIComplete = "verification_uri_complete"
		case expiresIn = "expires_in"
		case interval
	}
}

struct GitHubOAuthTokenResponse: Decodable, Sendable, Equatable {
	let accessToken: String
	let scope: String
	let tokenType: String
	let expiresIn: Int?
	let refreshToken: String?
	let refreshTokenExpiresIn: Int?

	enum CodingKeys: String, CodingKey {
		case accessToken = "access_token"
		case scope
		case tokenType = "token_type"
		case expiresIn = "expires_in"
		case refreshToken = "refresh_token"
		case refreshTokenExpiresIn = "refresh_token_expires_in"
	}
}

struct GitHubOAuthDeviceFlowService: Sendable {
	let descriptor: OAuthAuthorizationDescriptor
	let transport: any GitHubAPITransport

	init(descriptor: OAuthAuthorizationDescriptor = GitHubOAuth.descriptor, transport: any GitHubAPITransport = URLSession.shared) {
		self.descriptor = descriptor
		self.transport = transport
	}

	func requestDeviceCode(clientID: String) async throws -> GitHubOAuthDeviceCode {
		guard let deviceCodeEndpoint = descriptor.deviceCodeEndpoint else {
			throw GitHubOAuthDeviceFlowError.missingDeviceEndpoint
		}
		let body = formBody([
			"client_id": clientID,
			"scope": descriptor.scopes.joined(separator: " ")
		])
		var request = URLRequest(url: deviceCodeEndpoint)
		request.httpMethod = "POST"
		request.httpBody = Data(body.utf8)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		let (data, response) = try await transport.send(request)
		try validate(response: response)
		return try JSONDecoder().decode(GitHubOAuthDeviceCode.self, from: data)
	}

	func pollToken(clientID: String, deviceCode: GitHubOAuthDeviceCode) async throws -> GitHubOAuthTokenResponse {
		let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
		var interval = max(1, deviceCode.interval)
		while Date() < deadline {
			do {
				return try await requestToken(clientID: clientID, deviceCode: deviceCode.deviceCode)
			} catch GitHubOAuthDeviceFlowError.unsupportedResponse(let error) where error == "authorization_pending" {
				try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
			} catch GitHubOAuthDeviceFlowError.unsupportedResponse(let error) where error == "slow_down" {
				interval += 5
				try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
			}
		}
		throw GitHubOAuthDeviceFlowError.expired
	}

	func requestToken(clientID: String, deviceCode: String) async throws -> GitHubOAuthTokenResponse {
		let body = formBody([
			"client_id": clientID,
			"device_code": deviceCode,
			"grant_type": "urn:ietf:params:oauth:grant-type:device_code"
		])
		var request = URLRequest(url: descriptor.tokenEndpoint)
		request.httpMethod = "POST"
		request.httpBody = Data(body.utf8)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		let (data, response) = try await transport.send(request)
		try validate(response: response)
		if let token = try? JSONDecoder().decode(GitHubOAuthTokenResponse.self, from: data) {
			return token
		}
		let error = try JSONDecoder().decode(GitHubOAuthErrorResponse.self, from: data)
		switch error.error {
		case "expired_token":
			throw GitHubOAuthDeviceFlowError.expired
		case "access_denied":
			throw GitHubOAuthDeviceFlowError.accessDenied
		default:
			throw GitHubOAuthDeviceFlowError.unsupportedResponse(error.error)
		}
	}

	private func validate(response: HTTPURLResponse) throws {
		guard (200..<300).contains(response.statusCode) else {
			throw ProviderError.unavailable("GitHub OAuth request failed with HTTP \(response.statusCode).")
		}
	}

	private func formBody(_ values: [String: String]) -> String {
		values
			.map { key, value in
				"\(escape(key))=\(escape(value))"
			}
			.sorted()
			.joined(separator: "&")
	}

	private func escape(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
	}
}

private struct GitHubOAuthErrorResponse: Decodable {
	let error: String
}
