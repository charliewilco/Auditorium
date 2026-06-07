import Foundation

enum ProviderAuthenticationMethod: String, Sendable {
	case oauth
	case token
	case none
}

struct ProviderAuthenticationDescriptor: Sendable {
	let method: ProviderAuthenticationMethod
	let displayName: String
	let oauth: OAuthAuthorizationDescriptor?
}

struct OAuthAuthorizationDescriptor: Sendable {
	let authorizationEndpoint: URL
	let tokenEndpoint: URL
	let deviceCodeEndpoint: URL?
	let callbackScheme: String
	let scopes: [String]

	func authorizationURL(clientID: String, state: String, redirectURI: String) -> URL? {
		var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
		components?.queryItems = [
			URLQueryItem(name: "client_id", value: clientID),
			URLQueryItem(name: "redirect_uri", value: redirectURI),
			URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
			URLQueryItem(name: "state", value: state)
		]
		return components?.url
	}
}

enum GitHubOAuth {
	static let callbackScheme = "auditorium"

	static let descriptor = OAuthAuthorizationDescriptor(
		authorizationEndpoint: URL(string: "https://github.com/login/oauth/authorize")!,
		tokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!,
		deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
		callbackScheme: callbackScheme,
		scopes: ["repo", "read:user"]
	)
}
