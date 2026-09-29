//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging
import Synchronization

// MARK: - Default helpers for destinations

enum HandlerCloseDispoition {
	case fileHandlerNotTracked
	case fileHandlerStillBusy
}

enum Helpers {
	/// The type of file associated to our writer
	private enum StoredFileType {
		case file(FileWriter)
		case sqlFile(SQLiteFile)

		var storedTypeName: String {
			switch self {
			case .file:
				"File"
			case .sqlFile:
				"SQLFile"
			}
		}
	}

	private static let activeWriters: Mutex<[URL: StoredFileType]> = .init(.init())

	private static func getWriter<W>(
		url: URL,
		fileHandling: Destination.LogRotation,
		queue: DispatchSerialQueue,
		unbox: (StoredFileType) -> W?,
		box: (W) -> StoredFileType,
		requestedTypeName: String,
		make: (URL, Destination.LogRotation, DispatchSerialQueue) -> W?,
		open: (W) -> Bool
	) -> W? {
		activeWriters.withLock { activeWriters in
			let absoluteRealURL = url.standardized.resolvingSymlinksInPath()

			if let currentWriter = activeWriters[absoluteRealURL] {
				guard let writer = unbox(currentWriter) else {
					fatalError("FileWriterRegistry: \(absoluteRealURL) already registered as \(currentWriter.storedTypeName), requested as \(requestedTypeName)")
				}
				_ = open(writer)
				return writer
			}

			guard let newWriter = make(absoluteRealURL, fileHandling, queue) else {
				return nil
			}

			activeWriters[absoluteRealURL] = box(newWriter)
			return newWriter
		}
	}

	static func getWriter(
		url: URL,
		fileHandling: Destination.LogRotation,
		queue: DispatchSerialQueue
	) -> FileWriter? {
		getWriter(
			url: url, fileHandling: fileHandling, queue: queue,
			unbox: {
				if case let .file(w) = $0 {
					w
				} else {
					nil
				}
			},
			box: { .file($0) },
			requestedTypeName: "File",
			make: FileWriter.init,
			open: { $0.openSync() }
		)
	}

	static func getWriter(
		url: URL,
		fileHandling: Destination.LogRotation,
		queue: DispatchSerialQueue
	) -> SQLiteFile? {
		getWriter(
			url: url, fileHandling: fileHandling, queue: queue,
			unbox: {
				if case let .sqlFile(w) = $0 {
					w
				} else {
					nil
				}
			},
			box: { .sqlFile($0) },
			requestedTypeName: "SQLFile",
			make: SQLiteFile.init,
			open: { $0.openSync() }
		)
	}

	static func getWriter(
		queue: DispatchSerialQueue
	) -> SQLiteFile? {
		getWriter(
			url: URL(filePath: ":memory:"), fileHandling: .unbounded, queue: queue,
			unbox: {
				if case let .sqlFile(w) = $0 {
					w
				} else {
					nil
				}
			},
			box: { .sqlFile($0) },
			requestedTypeName: "SQLFile",
			make: SQLiteFile.init,
			open: { $0.openSync() }
		)
	}

	private static func checkWriter(url: URL, openCount: Int) -> HandlerCloseDispoition {
		activeWriters.withLock { activeWriters in
			guard openCount == 0 else {
				return .fileHandlerStillBusy
			}

			let absoluteRealURL = url.standardized.resolvingSymlinksInPath()
			activeWriters.removeValue(forKey: absoluteRealURL)
			return .fileHandlerNotTracked
		}
	}

	@discardableResult
	static func checkWriter(_ writer: any Destination.FileHandling) -> HandlerCloseDispoition {
		if let logHandler = writer as? Destination.File {
			guard let fileWriter = logHandler.fileWriter else {
				return .fileHandlerNotTracked
			}
			return checkWriter(fileWriter)
		} else if let logHandler = writer as? Destination.SQLFile {
			guard let sqliteFile = logHandler.fileWriter else {
				return .fileHandlerNotTracked
			}
			return checkWriter(sqliteFile)
		} else {
			return .fileHandlerNotTracked
		}
	}

	@discardableResult
	static func checkWriter(_ fileWriter: FileWriter) -> HandlerCloseDispoition {
		let url = fileWriter.url
		let openCount = fileWriter.executorQueue.sync {
			fileWriter.assumeIsolated {
				$0.openCount
			}
		}
		return checkWriter(url: url, openCount: openCount)
	}

	@discardableResult
	static func checkWriter(_ sqliteFile: SQLiteFile) -> HandlerCloseDispoition {
		let url = sqliteFile.url ?? URL(fileURLWithPath: ":memory:")
		let openCount = sqliteFile.executorQueue.sync {
			sqliteFile.assumeIsolated {
				$0.openCount
			}
		}
		return checkWriter(url: url, openCount: openCount)
	}

	/// Static `Date.ISO8601FormatStyle` used by `Helpers.formattedDateTime(_:)` and
	/// `Reader.dateFrom(string:)`. `Date.ISO8601FormatStyle` is thread-safe under modern Foundation.
	static var dateFormatter: Date.ISO8601FormatStyle {
		var formatter = Date.ISO8601FormatStyle(
			dateSeparator: .dash,
			dateTimeSeparator: .space
		)
		.year()
		.month()
		.day()
		.dateSeparator(.dash)
		.time(includingFractionalSeconds: false)
		.timeSeparator(.colon)
		.dateTimeSeparator(.space)
		formatter.timeZone = TimeZone.gmt

		return formatter
	}

	/**
	 Format a `Date` as a high-precision timestamp string (`yyyy-MM-dd HH:mm:ss.fffffff`).

	 `Date.ISO8601FormatStyle` cannot produce fractional seconds beyond millisecond precision,
	 so the fractional component is rebuilt to 7 digits via `String(format:)`.

	 - Parameter date: the date to format
	 - Returns: formatted timestamp string
	 */
	static func formattedDateTime(_ date: Date) -> String {
		var dateTime = date.formatted(Self.dateFormatter)
		let fracSecs = String(
			String(format: "%.8f", date.timeIntervalSinceReferenceDate - trunc(date.timeIntervalSinceReferenceDate))
				.dropFirst()
				.dropLast()
		)
		dateTime += fracSecs
		return dateTime
	}

	/**
	 Returns just the last path component of a file path. Useful for trimming `#file` values
	 down to a short, log-friendly form.

	 - Parameter file: the file path (typically `#file`)
	 - Returns: the file's last path component
	 */
	static func shortFile(_ file: String) -> String {
		URL(fileURLWithPath: file).lastPathComponent
	}

	static func rotate(baseURL url: URL, maxIndex: Int) {
		// Move files around based upon the log name, .9 to .10, .8 to .9, and so on.
		// Don't move ".0" to ".1", since .0 doesn't exist.  However, if the baseURL
		// file doesn't exist, don't do anything.
		let fileManager = FileManager()
		guard fileManager.fileExists(atPath: url.path) else { return }

		try? fileManager.removeItem(at: url.appendingPathExtension("\(maxIndex)"))
		for index in stride(from: maxIndex, to: 1, by: -1) {
			try? fileManager.moveItem(at: url.appendingPathExtension("\(index - 1)"), to: url.appendingPathExtension("\(index)"))
		}
		try? fileManager.moveItem(at: url, to: url.appendingPathExtension("1"))
	}

	/**
	 Used to separate the message from any metadata
	 */
	static let messagePackageSeparator = "; metadata:"

	/**
	 Return a single string from the message and optional metadata.
	 */
	static func package(message: String, metadata: Logger.Metadata?, includePrivate: Bool) -> String {
		guard var metadata else {
			return message
		}
		// Filter out anything that should not be stored
		if !includePrivate {
			metadata = metadata.filter { keyValue in
				keyValue.key != "private"
			}
		}
		if let jsonValue = JSONValue(metadata: metadata),
		   let metadataJSON = try? JSONEncoder().encode(jsonValue),
		   let metadataJSONText = String(data: metadataJSON, encoding: .utf8)
		{
			return "\(message)\(messagePackageSeparator)\(metadataJSONText)"
		} else {
			return "\(message)"
		}
	}

	static func unpackage(messageText: String) -> (String, JSONValue?) {
		var parts = messageText.components(separatedBy: messagePackageSeparator)
		let metadataPart = parts.removeLast()
		if let metadata = try? JSONDecoder().decode(JSONValue.self, from: Data(metadataPart.utf8)),
		   case .object = metadata
		{
			return (parts.joined(separator: messagePackageSeparator), metadata)
		} else {
			return (messageText, nil)
		}
	}

	/**
	 Borrowed from StreamLogHandler to provide a comprehensive metadata from three sources and error.

	 Unlike StreamLogHandler (whose caller falls back to its cached handler metadata when this
	 returns `nil`), this returns the handler's `base` metadata when there are no per-statement
	 values, and `nil` only when there is no metadata at all.
	 */
	static func prepareMetadata(
		base: Logger.Metadata,
		provider: Logger.MetadataProvider?,
		explicit: Logger.Metadata?,
		error: (any Error)?
	) -> Logger.Metadata? {
		var metadata = base

		let provided = provider?.get() ?? [:]

		guard !provided.isEmpty || !((explicit ?? [:]).isEmpty) || error != nil else {
			// all per-log-statement values are empty, so only the handler's metadata applies
			return base.isEmpty ? nil : base
		}

		if !provided.isEmpty {
			metadata.merge(provided, uniquingKeysWith: { _, provided in provided })
		}

		if let explicit, !explicit.isEmpty {
			metadata.merge(explicit, uniquingKeysWith: { _, explicit in explicit })
		}

		if let error {
			metadata["error.message"] = "\(error)"
			metadata["error.type"] = "\(String(reflecting: type(of: error)))"
		}

		return metadata
	}

	final class ObjectRef: Sendable {}
}
