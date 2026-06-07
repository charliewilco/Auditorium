import Foundation

struct GitBranchName {
	nonisolated static func make(prefix: String, ticketExternalID: String, ticketTitle: String) -> String {
		let sanitizedPrefix = sanitize(prefix, fallback: "auditorium")
		let sanitizedTicketID = sanitize(ticketExternalID, fallback: "ticket")
		let sanitizedTitle = sanitize(ticketTitle, fallback: "work")
		let titleLimit = 56
		let title = String(sanitizedTitle.prefix(titleLimit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		return "\(sanitizedPrefix)/\(sanitizedTicketID)-\(title)"
	}

	nonisolated private static func sanitize(_ value: String, fallback: String) -> String {
		let lowered = value.lowercased()
		var output = ""
		var previousWasSeparator = false
		for scalar in lowered.unicodeScalars {
			if CharacterSet.alphanumerics.contains(scalar) {
				output.unicodeScalars.append(scalar)
				previousWasSeparator = false
			}
			else if previousWasSeparator == false {
				output.append("-")
				previousWasSeparator = true
			}
		}
		let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		return trimmed.isEmpty ? fallback : trimmed
	}
}
