import Foundation

struct GitHubAccountSelection: Equatable, Identifiable {
	let id: UUID
	let displayName: String
	let providerKindRaw: String
	let keychainAccount: String
}

struct GitHubCredentialSelectionService {
	func availableAccounts(
		from providerAccounts: [ProviderAccountRecord],
		secretReader: (String) throws -> String?
	) -> [GitHubAccountSelection] {
		providerAccounts.compactMap { account in
			guard
				account.providerKindRaw == RepositoryProviderKind.github.rawValue
					|| account.providerKindRaw == IssueProviderKind.githubIssues.rawValue,
				let token = try? secretReader(account.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
				token.isEmpty == false
			else {
				return nil
			}
			return GitHubAccountSelection(
				id: account.id,
				displayName: account.displayName,
				providerKindRaw: account.providerKindRaw,
				keychainAccount: account.keychainAccount
			)
		}
	}
}

struct GitHubAuthenticationState: Equatable {
	enum Status: Equatable {
		case disconnected
		case missingSecret
		case connected
	}

	let status: Status
	let displayName: String
	let detail: String
	let keychainAccount: String?

	var isConnected: Bool {
		status == .connected
	}

	init(providerAccounts: [ProviderAccountRecord], secretReader: (String) throws -> String?) {
		let githubAccounts = providerAccounts.filter {
			$0.providerKindRaw == RepositoryProviderKind.github.rawValue || $0.providerKindRaw == IssueProviderKind.githubIssues.rawValue
		}
		guard let account = githubAccounts.first else {
			status = .disconnected
			displayName = "GitHub"
			detail = "No GitHub account is connected."
			keychainAccount = nil
			return
		}

		displayName = account.displayName
		keychainAccount = account.keychainAccount
		if (try? secretReader(account.keychainAccount))?.isEmpty == false {
			status = .connected
			var details = ["Connected. Secret material is stored in Keychain."]
			if account.grantedScopes.isEmpty == false {
				details.append("Scopes: \(account.grantedScopes.sorted().joined(separator: ", ")).")
			}
			if let accessTokenExpiresAt = account.accessTokenExpiresAt {
				details.append("Access token expires \(accessTokenExpiresAt.formatted(date: .abbreviated, time: .shortened)).")
			}
			if account.refreshTokenKeychainAccount != nil {
				details.append("Refresh token is stored separately in Keychain.")
			}
			detail = details.joined(separator: " ")
		}
		else {
			status = .missingSecret
			detail = "Credential metadata exists, but the Keychain secret is missing."
		}
	}
}
