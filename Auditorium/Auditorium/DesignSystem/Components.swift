import SwiftUI

struct StatusBadge: View {
	let title: String
	let tint: Color

	var body: some View {
		Text(title)
			.font(.caption.weight(.medium))
			.padding(.horizontal, 7)
			.padding(.vertical, 3)
			.background(tint.opacity(0.14), in: Capsule())
			.foregroundStyle(tint)
	}
}

struct ProviderCard: View {
	let title: String
	let subtitle: String
	let symbol: String
	let isSelected: Bool

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: symbol)
				.font(.title3)
				.frame(width: 30)
				.foregroundStyle(isSelected ? Color.white : Color.accentColor)
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.headline)
				Text(subtitle)
					.font(.caption)
					.foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
			}
			Spacer()
			if isSelected {
				Image(systemName: "checkmark.circle.fill")
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, minHeight: 72)
		.background(isSelected ? Color.accentColor : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
		.contentShape(RoundedRectangle(cornerRadius: 8))
	}
}

struct StatCard: View {
	let title: String
	let value: String
	let symbol: String
	let tint: Color

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Image(systemName: symbol)
					.foregroundStyle(tint)
				Spacer()
			}
			Text(value)
				.font(.title2.weight(.semibold))
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(12)
		.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
	}
}

struct TimelineRow: View {
	let event: RuntimeEventRecord

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Circle()
				.fill(event.level.tint)
				.frame(width: 8, height: 8)
				.padding(.top, 6)
			VStack(alignment: .leading, spacing: 3) {
				HStack {
					Text(event.message)
						.font(.callout)
					Spacer()
					Text(event.timestamp, format: .dateTime.hour().minute())
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Text(event.category.rawValue)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}

struct EmptyStateView: View {
	let symbol: String
	let title: String
	let message: String

	var body: some View {
		VStack(spacing: 12) {
			Image(systemName: symbol)
				.font(.system(size: 42))
				.foregroundStyle(.secondary)
			Text(title)
				.font(.title3.weight(.semibold))
			Text(message)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 360)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}
}

extension Collection {
	var isNotEmpty: Bool { !isEmpty }
}
