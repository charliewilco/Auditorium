import Foundation
import Security

enum KeychainError: Error {
	case unexpectedStatus(OSStatus)
	case missingData
}

struct KeychainService {
	private let service = "co.charliewil.Auditorium"

	func storeSecret(_ secret: String, account: String) throws {
		let data = Data(secret.utf8)
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		SecItemDelete(query as CFDictionary)
		var addQuery = query
		addQuery[kSecValueData as String] = data
		let status = SecItemAdd(addQuery as CFDictionary, nil)
		guard status == errSecSuccess else {
			throw KeychainError.unexpectedStatus(status)
		}
	}

	func readSecret(account: String) throws -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess else {
			throw KeychainError.unexpectedStatus(status)
		}
		guard let data = item as? Data else {
			throw KeychainError.missingData
		}
		return String(data: data, encoding: .utf8)
	}

	func deleteSecret(account: String) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainError.unexpectedStatus(status)
		}
	}
}
