//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

@testable import AS_SwiftLogHandler
import Foundation
import Logging
import Testing

struct HelperTests {
	struct TestError: Error {}

	@Test
	func prepareMetadataMergesAllSources() throws {
		let base: Logger.Metadata = ["base": "b", "shared": "base"]
		let provider = Logger.MetadataProvider { ["provided": "p", "shared": "provider"] }

		// Nothing at all
		#expect(Helpers.prepareMetadata(base: [:], provider: nil, explicit: nil, error: nil) == nil)
		#expect(Helpers.prepareMetadata(base: [:], provider: nil, explicit: [:], error: nil) == nil)

		// Only the handler's metadata — must not be dropped
		#expect(Helpers.prepareMetadata(base: base, provider: nil, explicit: nil, error: nil) == base)

		// Provider overrides base, explicit overrides provider
		let merged = Helpers.prepareMetadata(base: base, provider: provider, explicit: ["shared": "explicit"], error: nil)
		#expect(merged == ["base": "b", "provided": "p", "shared": "explicit"])

		// Error adds its message and type
		let withError = try #require(Helpers.prepareMetadata(base: [:], provider: nil, explicit: nil, error: TestError()))
		#expect(withError["error.message"] != nil)
		#expect(withError["error.type"] == .string(String(reflecting: TestError.self)))
	}

	@Test
	func multipleFileOpening() async throws {
		let uuidString = UUID().uuidString
		let url = FileManager.default.temporaryDirectory.appending(path: uuidString).appendingPathExtension("log")
		let queue = DispatchSerialQueue(label: "testMultipleFileOpening")
		let fw1: FileWriter = try #require(Helpers.getWriter(url: url, fileHandling: .unbounded, queue: queue))
		let fw2: FileWriter = try #require(Helpers.getWriter(url: url, fileHandling: .unbounded, queue: queue))
		#expect(fw1 === fw2)
		#expect(await fw1.openCount == 2)
	}

	@Test
	func multipleSQLFileOpening() async throws {
		let uuidString = UUID().uuidString
		let url = FileManager.default.temporaryDirectory.appending(path: uuidString).appendingPathExtension("log")
		let queue = DispatchSerialQueue(label: "testMultipleFileOpening")
		let fw1: SQLiteFile = try #require(Helpers.getWriter(url: url, fileHandling: .unbounded, queue: queue))
		let fw2: SQLiteFile = try #require(Helpers.getWriter(url: url, fileHandling: .unbounded, queue: queue))
		#expect(fw1 === fw2)
		#expect(await fw1.openCount == 2)
	}
}
