//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging
import Synchronization

extension Destination {
	/**
	 A `LogHandler` destination that sends log output to a file.

	 File growth is managed per the ``Destination/LogRotation`` setting: with `.rotateAt`,
	 once the file reaches the given size it is rotated (renamed to `.1`, `.2`, … up to
	 `maxIndex`) and a new file is started. The platform-specific
	 ``Destination/LogRotation/default`` is used unless otherwise specified.
	 */
	public struct File: LogHandler, Sendable {
		/// Class object that is used to detect two File pointing to the
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

		public var metadata: Logging.Logger.Metadata = .init()
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
		var fileWriter: FileWriter?
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
		 Create a `File` destination

		 This will create a log file at the specified URL, rotating it per the
		 `fileHandling` setting, and log the specified log levels. All `File` handlers
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
			fileHandling: Destination.LogRotation = .default,
			logLevel: Logger.Level = .trace,
			queue: DispatchSerialQueue? = nil,
			metadataProvider: Logger.MetadataProvider? = nil
		) {
			self.label = label
			self.url = url
			_logLevel = logLevel
			let serialQueue = queue ?? DispatchSerialQueue(label: "fileQueue(\(url.deletingPathExtension().lastPathComponent))", qos: .userInteractive)
			self.queue = serialQueue
			_metadataProvider = metadataProvider
			fileWriter = Helpers.getWriter(url: url, fileHandling: fileHandling, queue: serialQueue)
			if fileWriter == nil {
				try? FileHandle.standardError.write(contentsOf: Data("AS_SwiftLogHandler: File couldn't initialize (read-only/full filesystem?), logging disabled\n".utf8))
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
					self.fileWriter = Helpers.getWriter(url: fileWriter.url, fileHandling: fileWriter.fileHandling, queue: fileWriter.executorQueue)
				}
			}
		}

		public func log(event: LogEvent) {
			let dateTime = Helpers.formattedDateTime(Date())
			let file = Helpers.shortFile(event.file)
			let metadata = Helpers.prepareMetadata(
				base: metadata,
				provider: metadataProvider,
				explicit: event.metadata,
				error: event.error
			)
			let logMessage = Helpers.package(message: event.message.description, metadata: metadata, includePrivate: false)
			let logLine = "\(dateTime) [\(label)] [\(event.level.string)] \(file):\(event.line) (\(event.function)): \(logMessage)\n"
			queue.sync {
				fileWriter?.assumeIsolated { writer in
					writer.write(logLine)
				}
			}
		}

		public static func == (lhs: File, rhs: File) -> Bool {
			lhs.url == rhs.url
		}
	}
}

extension Destination.File: Destination.FileHandling {
	public static func fileURLs(from url: URL) -> [URL] {
		[url]
	}

	/// Utility to remove all of the log files in the log file's directory, including all of the rollovers.
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

	/// Utility to get the current log file's size
	public static func size(url: URL) -> UInt64 {
		(try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
	}

	/// Open the log file
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

	/// Close the log file
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

extension Destination.File: Reader {
	public func read(matching: (@Sendable (SwiftLogEntry) -> Bool)? = nil) async throws -> [SwiftLogEntry] {
		var entries: [SwiftLogEntry] = []
		let logLineRE = /^(.+) \[(.+)\] \[(.+)\] (.+):([0-9]+) \((.+?)\): (.*)$/
		for url in [url.appendingPathExtension("1"), url] {
			let readLen = 32768
			var data = Data()
			var position = 0

			do {
				let fileHandle = try FileHandle(forReadingFrom: url)
				defer {
					fileHandle.closeFile()
				}

				while true {
					let startIndex = position
					// Skip over the newline
					let endLineIndex: Data.Index
					if let newlineIndex = (position == 0 ? data.firstIndex(of: 0x0A) : data[position...].firstIndex(of: 0x0A)) {
						endLineIndex = newlineIndex.advanced(by: -1)
						position = newlineIndex.advanced(by: 1)
					} else {
						let existingData: Data = if position > 0,
						                            position <= data.count
						{
							Data(data[position...])
						} else if position == 0,
						          !data.isEmpty
						{
							data
						} else {
							Data()
						}
						if let newData = try fileHandle.read(upToCount: readLen),
						   !newData.isEmpty
						{
							position = 0
							data = existingData + newData
							continue
						} else {
							endLineIndex = data.endIndex.advanced(by: -1)
							position = data.endIndex
						}
					}
					if startIndex >= endLineIndex {
						break
					}
					guard let line = String(data: data[startIndex...endLineIndex], encoding: .utf8),
					      let match = try logLineRE.firstMatch(in: line)
					else {
						// We could be reading in the middle of writing log messages, so just return what we've got.
						try? await Task.sleep(nanoseconds: 100_000)
						continue
					}

					let date = try dateFrom(string: match.1)
					let (message, metadata) = Helpers.unpackage(messageText: String(match.7))

					let entry = try SwiftLogEntry(
						date: date,
						moduleName: String(match.2),
						level: Logger.Level.from(string: match.3),
						file: String(match.4),
						lineNumber: UInt(match.5) ?? 0,
						function: String(match.6),
						message: message,
						metadata: metadata
					)
					if let matching {
						if matching(entry) {
							entries.append(entry)
						}
					} else {
						entries.append(entry)
					}
				}
			} catch {
				// Do nothing, if we can't open the file we'll just return an empty list of entries for this file
			}
		}

		return entries
	}
}
