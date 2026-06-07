import Foundation

struct PullRequestReviewPolicy {
	static let allowsAutoMergeInV0 = false

	func validate(_ request: PullRequestRequest) throws {
		guard request.allowsAutoMerge == false else {
			throw ProviderError.unavailable("Auditorium v0 opens pull requests for human review and never auto-merges.")
		}
	}
}
