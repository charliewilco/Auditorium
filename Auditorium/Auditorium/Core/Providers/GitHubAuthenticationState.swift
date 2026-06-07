import Foundation

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
			detail = "Connected. Secret material is stored in Keychain."
		} else {
			status = .missingSecret
			detail = "Credential metadata exists, but the Keychain secret is missing."
		}
	}
}
