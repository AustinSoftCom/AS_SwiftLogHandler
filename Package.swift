// swift-tools-version: 6.3

import PackageDescription

let package = Package(
	name: "AS_SwiftLogHandler",
	platforms: [
		.macOS(.v15),
		.iOS(.v18),
		.tvOS(.v18),
		.watchOS(.v11),
		.visionOS(.v2),
	],
	products: [
		.library(
			name: "AS_SwiftLogHandler",
			targets: ["AS_SwiftLogHandler"]
		),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
	],
	targets: [
		.target(
			name: "AS_SwiftLogHandler",
			dependencies: [
				.product(name: "Logging", package: "swift-log"),
			],
			swiftSettings: [
				.define("SUPPORTS_LOGROTATE", .when(platforms: [.macOS, .linux])),
			]
		),
		.testTarget(
			name: "AS_SwiftLogHandlerTests",
			dependencies: [
				"AS_SwiftLogHandler",
			]
		),
	]
)
