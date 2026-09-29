//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

@testable import AS_SwiftLogHandler
import Foundation
@testable import Logging
import Testing

struct JSONValueTests {
	/// A stringConvertible payload that is none of the specially-handled numeric types,
	/// so conversion must fall back to `.string(description)`.
	struct Coordinate: CustomStringConvertible, Sendable {
		var description: String {
			"12.5,-3.25"
		}
	}

	@Test
	func stringMetadataValue() {
		#expect(JSONValue(Logger.MetadataValue.string("abc")) == .string("abc"))
	}

	@Test
	func stringConvertibleBool() {
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(true)) == .bool(true))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(false)) == .bool(false))
	}

	@Test
	func stringConvertibleIntegers() {
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(Int(-7))) == .number(-7))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(Int64(42))) == .number(42))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(UInt(7))) == .number(7))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(UInt8(255))) == .number(255))
	}

	@Test
	func stringConvertibleFloatingPoint() {
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(Float(1.5))) == .number(1.5))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(Double(2.25))) == .number(2.25))
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(NSNumber(value: 3.5))) == .number(3.5))
	}

	@Test
	func stringConvertibleFallsBackToDescription() {
		#expect(JSONValue(Logger.MetadataValue.stringConvertible(Coordinate())) == .string("12.5,-3.25"))
	}

	@Test
	func dictionaryAndArrayConvertRecursively() {
		let value = JSONValue(Logger.MetadataValue.dictionary([
			"items": .array([.string("a"), .stringConvertible(1)]),
			"name": .string("test"),
		]))

		#expect(value == .object([
			"items": .array([.string("a"), .number(1)]),
			"name": .string("test"),
		]))
	}

	@Test
	func metadataInitializer() {
		#expect(JSONValue(metadata: nil) == nil)
		#expect(JSONValue(metadata: [:]) == .object([:]))

		let metadata: Logger.Metadata = [
			"who": .string("tester"),
			"count": .stringConvertible(2),
		]
		#expect(JSONValue(metadata: metadata) == .object([
			"who": .string("tester"),
			"count": .number(2),
		]))
	}

	@Test
	func codableRoundTripCoversAllCases() throws {
		let value = JSONValue.object([
			"string": .string("abc"),
			"number": .number(1.5),
			"bool": .bool(true),
			"null": .null,
			"array": .array([.number(1), .string("two"), .null]),
			"nested": .object(["inner": .bool(false)]),
		])

		let data = try JSONEncoder().encode(value)
		let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

		#expect(decoded == value)
	}
}

struct SwiftLogEntryTests {
	static let date = Date(timeIntervalSince1970: 1_000_000)

	static func makeEntry(
		date: Date = Self.date,
		moduleName: String = "Test",
		level: Logger.Level = .info,
		file: String = "File.swift",
		lineNumber: UInt = 10,
		function: String = "run()",
		message: String = "message",
		metadata: JSONValue? = nil
	) -> SwiftLogEntry {
		SwiftLogEntry(
			date: date,
			moduleName: moduleName,
			level: level,
			file: file,
			lineNumber: lineNumber,
			function: function,
			message: message,
			metadata: metadata
		)
	}

	@Test
	func initFromLoggerMetadataConverts() {
		let metadata: Logger.Metadata = [
			"who": .string("tester"),
			"count": .stringConvertible(2),
		]
		let entry = SwiftLogEntry(
			date: Self.date,
			moduleName: "Test",
			level: .warning,
			file: "File.swift",
			lineNumber: 10,
			function: "run()",
			message: "message",
			metadata: metadata
		)

		#expect(entry.metadata == .object([
			"who": .string("tester"),
			"count": .number(2),
		]))

		let noMetadata = SwiftLogEntry(
			date: Self.date,
			moduleName: "Test",
			level: .warning,
			file: "File.swift",
			lineNumber: 10,
			function: "run()",
			message: "message",
			metadata: Logger.Metadata?.none
		)
		#expect(noMetadata.metadata == nil)
	}

	@Test
	func initFromJSONValueStoresAllFields() {
		let metadata = JSONValue.object(["key": .string("value")])
		let entry = Self.makeEntry(metadata: metadata)

		#expect(entry.date == Self.date)
		#expect(entry.moduleName == "Test")
		#expect(entry.level == .info)
		#expect(entry.file == "File.swift")
		#expect(entry.lineNumber == 10)
		#expect(entry.function == "run()")
		#expect(entry.message == "message")
		#expect(entry.metadata == metadata)
	}

	@Test
	func equalityComparesEveryFieldExceptMetadata() {
		let entry = Self.makeEntry()

		#expect(entry == Self.makeEntry())
		// Metadata is intentionally excluded from equality
		#expect(entry == Self.makeEntry(metadata: .object(["extra": .bool(true)])))

		#expect(entry != Self.makeEntry(date: Self.date + 1))
		#expect(entry != Self.makeEntry(moduleName: "Other"))
		#expect(entry != Self.makeEntry(level: .error))
		#expect(entry != Self.makeEntry(file: "Other.swift"))
		#expect(entry != Self.makeEntry(lineNumber: 11))
		#expect(entry != Self.makeEntry(function: "other()"))
		#expect(entry != Self.makeEntry(message: "other"))
	}

	@Test
	func comparableOrdersByDateOnly() {
		let earlier = Self.makeEntry(date: Self.date, message: "zzz")
		let later = Self.makeEntry(date: Self.date + 1, message: "aaa")

		#expect(earlier < later)
		#expect(!(later < earlier))
		// Same date is not ordered, regardless of other fields
		#expect(!(earlier < Self.makeEntry(date: Self.date, message: "aaa")))

		#expect([later, earlier].sorted() == [earlier, later])
	}
}
