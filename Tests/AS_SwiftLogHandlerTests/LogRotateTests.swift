//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

#if SUPPORTS_LOGROTATE
@testable import AS_SwiftLogHandler
import Foundation
import Logging
import Testing

struct LogRotateTests {
	typealias FileHandlingReaderFactory = @Sendable (String, URL, Destination.LogRotation, Logger.Level, DispatchSerialQueue?) -> any (LogHandler & Destination.FileHandling & Reader)

	@Test(
		arguments: [
			{ Destination.File(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
			{ Destination.SQLFile(label: $0, url: $1, fileHandling: $2, logLevel: $3, queue: $4) },
		] as [FileHandlingReaderFactory]
	)
	func reopensRenamedFile(
		handler: FileHandlingReaderFactory
	) async throws {
		let fileManager = FileManager()
		let url = fileManager.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("log")
		let rotatedURL = url.appendingPathExtension("1")

		let logHandler = handler("LogRotate", url, .useLogRotate, .trace, nil)
		let logger = Logger(label: "LogRotate") { _ in logHandler }
		defer {
			logHandler.close()
			type(of: logHandler).ensureDeleted(url: url)
			type(of: logHandler).ensureDeleted(url: rotatedURL)
		}

		logger.info("before rotation")

		// Rotate the way logrotate does by default: rename the live file.
		try fileManager.moveItem(at: url, to: rotatedURL)

		// The next write should notice the rename and recreate the file at the original path.
		logger.info("after rotation")
		#expect(fileManager.fileExists(atPath: url.path))

		// read() includes the newest rotated file, which here is rotatedURL.
		let current = try await logHandler.read().map(\.message)
		#expect(current == ["before rotation", "after rotation"])

		let rotatedHandler = handler("LogRotate", rotatedURL, .unbounded, .trace, nil)
		defer {
			rotatedHandler.close()
		}
		let rotated = try await rotatedHandler.read().map(\.message)
		#expect(rotated == ["before rotation"])
	}

	@Test
	func appendsAfterCopyTruncate() async throws {
		let fileManager = FileManager()
		let url = fileManager.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("log")
		let rotatedURL = url.appendingPathExtension("1")

		let logHandler = Destination.File(label: "LogRotate", url: url, fileHandling: .useLogRotate, logLevel: .trace, queue: nil)
		let logger = Logger(label: "LogRotate") { _ in logHandler }
		defer {
			logHandler.close()
			Destination.File.ensureDeleted(url: url)
			Destination.File.ensureDeleted(url: rotatedURL)
		}

		logger.info("before rotation")

		// Rotate the way logrotate's copytruncate does: copy the file, then truncate it in place.
		try fileManager.copyItem(at: url, to: rotatedURL)
		let truncator = try FileHandle(forWritingTo: url)
		try truncator.truncate(atOffset: 0)
		try truncator.close()

		logger.info("after rotation")

		// Without O_APPEND, the write would land at the old offset, leaving NULs before it.
		let contents = try Data(contentsOf: url)
		#expect(contents.first != 0)
		let text = String(decoding: contents, as: UTF8.self)
		#expect(text.contains("after rotation"))
		#expect(!text.contains("before rotation"))
	}
}
#endif
