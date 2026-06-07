import Foundation

struct ReportActions {
	static func markdownForCopy(_ report: ReportRecord) -> String {
		report.markdown
	}

	static func revealURL(for report: ReportRecord) -> URL {
		URL(fileURLWithPath: report.filePath)
	}

	static func suggestedExportFileName(for report: ReportRecord) -> String {
		let trimmedTitle = report.title.trimmingCharacters(in: .whitespacesAndNewlines)
		let baseName = trimmedTitle.isEmpty ? "Auditorium Report" : trimmedTitle
		let sanitized =
			baseName
			.map { character in
				character.isSafeFileNameCharacter ? String(character) : "-"
			}
			.joined()
			.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
			.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
		let fileName = sanitized.isEmpty ? "Auditorium Report" : sanitized
		return fileName.hasSuffix(".md") ? fileName : "\(fileName).md"
	}

	static func export(_ report: ReportRecord, to url: URL) throws {
		try report.markdown.write(to: url, atomically: true, encoding: .utf8)
	}
}

extension Character {
	fileprivate var isSafeFileNameCharacter: Bool {
		isLetter || isNumber || self == " " || self == "-" || self == "_" || self == "."
	}
}
