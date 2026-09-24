//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

@testable import AS_SwiftLogHandler
import Foundation
@testable import Logging
import Synchronization
import Testing

@Suite(.serialized)
struct LoggingTests {
	/// A subset of SwiftLogEntry that removes non-testable info
	struct TestLogEntry: Equatable {
		let module: String
		let level: Logger.Level
		let file: String
		let function: String
		let message: String
		let metadata: JSONValue?

		init(
			level: Logger.Level,
			module: String,
			message: String,
			metadata: JSONValue?,
			file: String,
			function: String
		) {
			self.module = module
			self.level = level
			self.file = file
			self.function = function
			self.message = message
			self.metadata = metadata
		}

		init(_ entry: SwiftLogEntry) {
			module = entry.moduleName
			level = entry.level
			file = entry.file
			function = entry.function
			message = entry.message
			metadata = entry.metadata
		}
	}

	typealias FileHandlingFactory = @Sendable (String, URL, Destination.LogRotation, Logger.Level, DispatchSerialQueue?) -> any (LogHandler & Destination.FileHandling)

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingFactory]
	)
	func logHandlerValueSemantics(
		handler: FileHandlingFactory
	) {
		let uuidString = UUID().uuidString
		let url = FileManager.default.temporaryDirectory.appending(path: uuidString).appendingPathExtension("log")
		var logger1 = handler("first logger", url, .unbounded, .trace, nil)
		logger1.logLevel = .debug
		logger1[metadataKey: "only-on"] = "first"

		var logger2 = logger1
		logger2.logLevel = .error // Must not affect logger1
		logger2[metadataKey: "only-on"] = "second" // Must not affect logger1

		// These expectations must pass
		#expect(logger1.logLevel == .debug)
		#expect(logger2.logLevel == .error)
		#expect(logger1[metadataKey: "only-on"] == "first")
		#expect(logger2[metadataKey: "only-on"] == "second")

		logger2.close()
		logger1.close()

		type(of: logger1).ensureDeleted(url: url)
		type(of: logger2).ensureDeleted(url: url)
	}

#if canImport(os.log)
	@Test
	func osLogHandlerValueSemantics() {
		var logger1 = Destination.OS(label: "first logger")
		logger1.logLevel = .debug
		logger1[metadataKey: "only-on"] = "first"

		var logger2 = logger1
		logger2.logLevel = .error // Must not affect logger1
		logger2[metadataKey: "only-on"] = "second" // Must not affect logger1

		// These expectations must pass
		#expect(logger1.logLevel == .debug)
		#expect(logger2.logLevel == .error)
		#expect(logger1[metadataKey: "only-on"] == "first")
		#expect(logger2[metadataKey: "only-on"] == "second")
	}
#endif

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingFactory]
	)
	func fileLogHandlerTests(
		handler: @escaping FileHandlingFactory
	) async throws {
		let uuidString = UUID().uuidString
		let url = FileManager.default.temporaryDirectory.appending(path: uuidString).appendingPathExtension("log")
		LoggingSystem.bootstrapInternal { label in handler(label, url, .unbounded, .trace, nil) }
		let moduleName = "Test"
		let logger = Logger(label: moduleName)
		let function = #function
		let metadata: [String: Logger.MetadataValue] = [
			"Test": .stringConvertible(1),
			"Test2": .string("abc"),
		]

		logger.trace("Trace", metadata: metadata)
		logger.debug("Debug", metadata: metadata)
		logger.info("Info", metadata: metadata)
		logger.notice("Notice", metadata: metadata)
		logger.warning("Warning", metadata: metadata)
		logger.error("Error", metadata: metadata)
		logger.critical("Critical", metadata: metadata)

		let filename = URL(fileURLWithPath: #file).lastPathComponent
		let logHandler = try #require(logger.handler as? (Destination.FileHandling & Reader))
		let records = try await logHandler.read().map { TestLogEntry($0) }
		let jsonValue = JSONValue(metadata: metadata)
		#expect(records == [
			TestLogEntry(level: .trace, module: moduleName, message: "Trace", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .debug, module: moduleName, message: "Debug", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .info, module: moduleName, message: "Info", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .notice, module: moduleName, message: "Notice", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .warning, module: moduleName, message: "Warning", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .error, module: moduleName, message: "Error", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .critical, module: moduleName, message: "Critical", metadata: jsonValue, file: filename, function: function),
		])

		type(of: logHandler).ensureDeleted(url: url)
	}

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingFactory]
	)
	func loggingMinWarnings(
		handler: @escaping FileHandlingFactory
	) async throws {
		let moduleName = "Test"
		let uuidString = UUID().uuidString
		let url = FileManager.default.temporaryDirectory.appending(path: uuidString).appendingPathExtension("log")
		LoggingSystem.bootstrapInternal { label in handler(label, url, .unbounded, .warning, nil) }
		let logger = Logger(label: moduleName)
		let function = #function
		let metadata: [String: Logger.MetadataValue] = [
			"Test": .stringConvertible(1),
			"Test2": .string("abc"),
		]

		logger.trace("Trace", metadata: metadata)
		logger.debug("Debug", metadata: metadata)
		logger.info("Info", metadata: metadata)
		logger.notice("Notice", metadata: metadata)
		logger.warning("Warning", metadata: metadata)
		logger.error("Error", metadata: metadata)
		logger.critical("Critical", metadata: metadata)

		let filename = URL(fileURLWithPath: #file).lastPathComponent
		let logHandler = try #require(logger.handler as? (Destination.FileHandling & Reader))
		let records = try await logHandler.read().map { TestLogEntry($0) }
		let jsonValue = JSONValue(metadata: metadata)
		#expect(records == [
			TestLogEntry(level: .warning, module: moduleName, message: "Warning", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .error, module: moduleName, message: "Error", metadata: jsonValue, file: filename, function: function),
			TestLogEntry(level: .critical, module: moduleName, message: "Critical", metadata: jsonValue, file: filename, function: function),
		])

		type(of: logHandler).ensureDeleted(url: url)
	}

	typealias FileHandlingReaderFactory = @Sendable (String, URL, Destination.LogRotation, Logger.Level, DispatchSerialQueue?) -> any (LogHandler & Destination.FileHandling & Reader)

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingReaderFactory]
	)
	func loggingMultipleSameLevel(
		handler: @escaping FileHandlingReaderFactory
	) async throws {
		let uuidString1 = UUID().uuidString
		let url1 = FileManager.default.temporaryDirectory.appending(path: uuidString1).appendingPathExtension("log")
		let uuidString2 = UUID().uuidString
		let url2 = FileManager.default.temporaryDirectory.appending(path: uuidString2).appendingPathExtension("log")
		let handler1: Mutex<(LogHandler & Destination.FileHandling & Reader)?> = .init(nil)
		let handler2: Mutex<(LogHandler & Destination.FileHandling & Reader)?> = .init(nil)
		LoggingSystem.bootstrapInternal { [handler] label in
			let h1 = handler(label + "1", url1, .unbounded, .trace, nil)
			let h2 = handler(label + "2", url2, .unbounded, .trace, nil)
			handler1.withLock { $0 = h1 }
			handler2.withLock { $0 = h2 }
			return Logging.MultiplexLogHandler([h1, h2])
		}
		let logger = Logger(label: "Test")

		let function = #function

		logger.debug("Debug")
		logger.info("Info")
		logger.error("Error")
		logger.critical("Critical")

		let filename = URL(fileURLWithPath: #file).lastPathComponent
		let logHandler1 = try handler1.withLock { try #require($0) }
		let logHandler2 = try handler2.withLock { try #require($0) }
		let records1 = try await logHandler1.read().map { TestLogEntry($0) }
		let records2 = try await logHandler2.read().map { TestLogEntry($0) }
		#expect(records1 == [
			TestLogEntry(level: .debug, module: "Test1", message: "Debug", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .info, module: "Test1", message: "Info", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .error, module: "Test1", message: "Error", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .critical, module: "Test1", message: "Critical", metadata: nil, file: filename, function: function),
		])

		#expect(records2 == [
			TestLogEntry(level: .debug, module: "Test2", message: "Debug", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .info, module: "Test2", message: "Info", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .error, module: "Test2", message: "Error", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .critical, module: "Test2", message: "Critical", metadata: nil, file: filename, function: function),
		])
	}

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingReaderFactory]
	)
	func loggingMultipleDifferentLevels(
		handler: @escaping FileHandlingReaderFactory
	) async throws {
		let uuidString1 = UUID().uuidString
		let url1 = FileManager.default.temporaryDirectory.appending(path: uuidString1).appendingPathExtension("log")
		let uuidString2 = UUID().uuidString
		let url2 = FileManager.default.temporaryDirectory.appending(path: uuidString2).appendingPathExtension("log")
		let handler1: Mutex<(LogHandler & Destination.FileHandling & Reader)?> = .init(nil)
		let handler2: Mutex<(LogHandler & Destination.FileHandling & Reader)?> = .init(nil)
		LoggingSystem.bootstrapInternal { [handler] label in
			let h1 = handler(label + "1", url1, .unbounded, .trace, nil)
			let h2 = handler(label + "2", url2, .unbounded, .error, nil)
			handler1.withLock { $0 = h1 }
			handler2.withLock { $0 = h2 }
			return Logging.MultiplexLogHandler([h1, h2])
		}
		let logger = Logger(label: "Test")

		let function = #function

		logger.debug("Debug")
		logger.info("Info")
		logger.error("Error")
		logger.critical("Critical")

		let filename = URL(fileURLWithPath: #file).lastPathComponent
		let logHandler1 = try handler1.withLock { try #require($0) }
		let logHandler2 = try handler2.withLock { try #require($0) }
		let records1 = try await logHandler1.read().map { TestLogEntry($0) }
		let records2 = try await logHandler2.read().map { TestLogEntry($0) }
		#expect(records1 == [
			TestLogEntry(level: .debug, module: "Test1", message: "Debug", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .info, module: "Test1", message: "Info", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .error, module: "Test1", message: "Error", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .critical, module: "Test1", message: "Critical", metadata: nil, file: filename, function: function),
		])

		#expect(records2 == [
			TestLogEntry(level: .error, module: "Test2", message: "Error", metadata: nil, file: filename, function: function),
			TestLogEntry(level: .critical, module: "Test2", message: "Critical", metadata: nil, file: filename, function: function),
		])
	}

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingReaderFactory]
	)
	func loggingToFileUntilRotatedToLimit(
		handler: @escaping FileHandlingReaderFactory
	) throws {
		let uuidString = UUID().uuidString
		let url = URL(fileURLWithPath: "/tmp").appending(path: uuidString).appendingPathExtension("log")
		let fileSize = 2048
		let numRecordsPerFile = 16
		LoggingSystem.bootstrapInternal { [handler] label in
			handler(label, url, .rotateAt(size: UInt64(fileSize), maxIndex: 3), .trace, nil)
		}

		let fileManager = FileManager()
		for fileName in try fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path()) {
			if fileName.hasPrefix(uuidString) {
				try? fileManager.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(fileName))
			}
		}

		let logger = Logger(label: "Test")

		for idx in 0..<(4 * numRecordsPerFile) {
			logger.trace("\(String(repeating: "-", count: 20)) \(String(format: "%05d", idx)) \(String(repeating: "-", count: 20))")
		}

		let logHandler = try #require(logger.handler as? (Destination.FileHandling & Reader))
		logHandler.close()

		#expect(fileManager.fileExists(atPath: url.path))
		#expect(fileManager.fileExists(atPath: url.appendingPathExtension("1").path))
		#expect(fileManager.fileExists(atPath: url.appendingPathExtension("2").path))
		#expect(fileManager.fileExists(atPath: url.appendingPathExtension("3").path))
		#expect(!fileManager.fileExists(atPath: url.appendingPathExtension("4").path))

		type(of: logHandler).ensureDeleted(url: url)

		#expect(!fileManager.fileExists(atPath: url.path))
		#expect(!fileManager.fileExists(atPath: url.appendingPathExtension("1").path))
		#expect(!fileManager.fileExists(atPath: url.appendingPathExtension("2").path))
		#expect(!fileManager.fileExists(atPath: url.appendingPathExtension("3").path))
	}

	@Test
	func largeFileMessages() async throws {
		let uuidString = UUID().uuidString
		let url = URL(fileURLWithPath: "/tmp").appending(path: uuidString).appendingPathExtension("log")
		LoggingSystem.bootstrapInternal { label in
			Destination.File(label: label, url: url, fileHandling: .unbounded, logLevel: .trace, queue: nil)
		}

		let logger = Logger(label: "Test")

		logger.trace("0 \(String(repeating: "-", count: 65535)) Succeeded!")
		logger.info("1 \(String(repeating: "🙂", count: 32768)) Succeeded!")
		logger.error("2 \(String(repeating: "🛑", count: 16384)) Succeeded!")

		let logHandler = try #require(logger.handler as? (Destination.FileHandling & Reader))

		let records = try await logHandler.read()
		#expect(records.count == 3)
		let errors = try await logHandler.read(matching: { $0.level == .error })
		#expect(errors.count == 1)

		logHandler.close()
		Destination.File.ensureDeleted(url: url)
	}
}
