//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging
import Synchronization

extension Destination {
	/**
	 A `LogHandler` destination that sends log output to a SQLite file.

	 File growth is managed per the ``Destination/LogRotation`` setting: with `.rotateAt`,
	 once the database (including its `-wal` and `-shm` companions) reaches the given size
	 it is rotated (renamed to `.1`, `.2`, … up to `maxIndex`) and a new database is
	 started. The platform-specific ``Destination/LogRotation/default`` is used unless
	 otherwise specified.
	 */
	public struct SQLFile: LogHandler, Sendable {
		/// Class object that is used to detect two SQLFile pointing to the
		/// same objRef — and same fileWriter (see: Swift Copy-on-Write)
		private var objRef = Helpers.ObjectRef()
		var _logLevel: Logging.Logger.Level
		public var logLevel: Logging.Logger.Level {
			get {
				_logLevel
			}
			set {
				ensureUnique()
				_logLevel = newValue
			}
		}

		public var metadata: Logging.Logger.Metadata = [:]
		var _metadataProvider: Logger.MetadataProvider?
		public var metadataProvider: Logger.MetadataProvider? {
			get {
				_metadataProvider
			}
			set {
				ensureUnique()
				_metadataProvider = newValue
			}
		}

		/// The label (source) for this logHandler
		let label: String
		/// The url to the file
		let url: URL
		/// The file writer actor
		var fileWriter: SQLiteFile?
		/// The bridging queue between our synchronous functionality and actor functionality
		let queue: DispatchSerialQueue
		public var openCount: Int {
			guard let fileWriter else {
				return 0
			}
			return fileWriter.executorQueue.sync {
				fileWriter.assumeIsolated {
					$0.openCount
				}
			}
		}

		public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
			get {
				metadata[key]
			}
			set {
				ensureUnique()
				metadata[key] = newValue
			}
		}

		/**
		 Create an `SQLFile` destination

		 This will create a SQLite log file at the specified URL, rotating it per the
		 `fileHandling` setting, and log the specified log levels. All `SQLFile` handlers
		 for the same URL share a single, reference-counted writer.

		 - Parameter label: The label to use on this LogHandler, recorded as each entry's module name
		 - Parameter url: file URL where to write the log file
		 - Parameter fileHandling: how to manage large logs
		 - Parameter logLevel: the minimum log level to write to the log file
		 - Parameter queue: the specific DispatchSerialQueue to use for serializing output
		 - Parameter metadataProvider: the optional Metadata provider to use with this logger
		 */
		public init(
			label: String,
			url: URL,
			fileHandling: LogRotation = .default,
			logLevel: Logger.Level = .trace,
			queue: DispatchSerialQueue? = nil,
			metadataProvider: Logger.MetadataProvider? = nil
		) {
			self.label = label
			self.url = url
			_logLevel = logLevel
			_metadataProvider = metadataProvider
			let serialQueue = queue ?? DispatchSerialQueue(label: "sqlFileQueue(\(url.lastPathComponent))", qos: .userInteractive)
			self.queue = serialQueue
			fileWriter = Helpers.getWriter(url: url, fileHandling: fileHandling, queue: serialQueue)
			if fileWriter == nil {
				try? FileHandle.standardError.write(contentsOf: Data("AS_SwiftLogHandler: SQLFile couldn't initialize (read-only/full filesystem?), logging disabled\n".utf8))
			}
		}

		/**
		 Function to create a unique copy of objRef and fileWriter IF AND ONLY IF you've made a copy
		 of the struct and start modifying it. Otherwise, Swift will save memory and have both variables
		 point to the same structure.

		 Updating the fileWriter here (rather than just refreshing objRef) is what keeps the
		 registry's open-count correct: once a copy diverges, it's an independent logger with its
		 own lifecycle, so it needs its own open() to match its own eventual close().
		 */
		private mutating func ensureUnique() {
			if !isKnownUniquelyReferenced(&objRef) {
				objRef = .init()
				if let fileWriter {
					if let url = fileWriter.url {
						self.fileWriter = Helpers.getWriter(url: url, fileHandling: fileWriter.fileHandling, queue: fileWriter.executorQueue)
					} else {
						self.fileWriter = Helpers.getWriter(queue: fileWriter.executorQueue)
					}
				}
			}
		}

		public func log(event: LogEvent) {
			guard let fileWriter else {
				return
			}
			let file = Helpers.shortFile(event.file)
			let metadata = Helpers.prepareMetadata(
				base: metadata,
				provider: metadataProvider,
				explicit: event.metadata,
				error: event.error
			)
			queue.sync {
				fileWriter.assumeIsolated { writer in
					writer.write(
						event.level,
						date: Date(),
						module: label,
						message: event.message.description,
						metadata: metadata,
						file: file,
						function: event.function,
						line: event.line
					)
				}
			}
		}

		public static func == (lhs: SQLFile, rhs: SQLFile) -> Bool {
			lhs.fileWriter?.url == rhs.fileWriter?.url
		}
	}
}

extension Destination.SQLFile: Destination.FileHandling {
	public static func ensureDeleted(url: URL) {
		let fileManager = FileManager()
		let dir = url.deletingLastPathComponent()
		let base = url.lastPathComponent
		if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
			for file in contents where file.lastPathComponent.hasPrefix(base) {
				try? fileManager.removeItem(at: file)
			}
		}
	}

	public static func fileURLs(from url: URL) -> [URL] {
		let lastPathComponent = url.lastPathComponent
		let baseURL = url.deletingLastPathComponent()
		return [
			url,
			baseURL.appendingPathComponent("\(lastPathComponent)-wal"),
			baseURL.appendingPathComponent("\(lastPathComponent)-shm"),
		]
	}

	public static func size(url: URL) -> UInt64 {
		UInt64(fileURLs(from: url)
			.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }
			.reduce(0, +))
	}

	public func open() -> Bool {
		guard let fileWriter else {
			return false
		}
		return queue.sync {
			fileWriter.assumeIsolated { writer in
				writer.open()
			}
		}
	}

	public func close() {
		guard let fileWriter else {
			return
		}
		defer {
			Helpers.checkWriter(fileWriter)
		}
		return queue.sync {
			fileWriter.assumeIsolated { writer in
				writer.close()
			}
		}
	}

	public func flush() {
		queue.sync {
			// Wait until the queue hits our block.
		}
	}

	public func flush() async {
		// Wait for every prior op on our serial queue to complete by enqueueing one behind
		// them and awaiting its completion.
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			queue.sync {
				continuation.resume()
			}
		}
	}
}

extension Destination.SQLFile: Reader {
	public func read(matching: (@Sendable (SwiftLogEntry) -> Bool)? = nil) async throws -> [SwiftLogEntry] {
		guard let fileWriter else {
			return []
		}

		return try await fileWriter.read(matching: matching)
	}
}
