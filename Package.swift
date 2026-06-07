// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "Auditorium",
	platforms: [
		.macOS(.v15)
	],
	products: [
		.library(name: "AuditoriumCore", targets: ["AuditoriumCore"])
	],
	targets: [
		.target(
			name: "AuditoriumCore",
			path: "Auditorium/Auditorium/Core"
		),
		.testTarget(
			name: "AuditoriumCoreTests",
			dependencies: ["AuditoriumCore"]
		),
	],
	swiftLanguageModes: [.v5]
)
