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
		public var logLevel: Logging.Logger.Level
		public var metadata: Logging.Logger.Metadata = .init()
		/// The label (source) for this logHandler
		let label: String
		/// The url to the file
		let url: URL
		/// The file writer actor
		let fileWriter: FileWriter?
		/// The bridging queue between our synchronous functionality and actor functionality
		let queue: DispatchSerialQueue

		public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
			get {
				metadata[key]
			}
			set {
				metadata[key] = newValue
			}
		}

		/**
		 Create a `File` destination

		 This will create a log file at the specified URL, rotating it per the
		 `fileHandling` setting, and log the specified log levels.

		 - Parameter label: The label to use on this LogHandler, if empty the LogEvent's source will be used
		 - Parameter url: file URL where to write the log file
		 - Parameter fileHandling: how to manage large logs
		 - Parameter logLevel: the minimum log level to write to the log file
		 - Parameter queue: the specific DispatchSerialQueue to use for serializing output
		 */
		public init(
			label: String,
			url: URL,
			fileHandling: Destination.LogRotation = .default,
			logLevel: Logger.Level = .trace,
			queue: DispatchSerialQueue? = nil
		) {
			self.label = label
			self.url = url
			self.logLevel = logLevel
			let serialQueue = queue ?? DispatchSerialQueue(label: "fileQueue(\(url.deletingPathExtension().lastPathComponent))", qos: .userInteractive)
			self.queue = serialQueue
			fileWriter = FileWriter(url: url, fileHandling: fileHandling, queue: serialQueue)
			if fileWriter == nil {
				try? FileHandle.standardError.write(contentsOf: Data("AS_SwiftLogHandler: File couldn't initialize (read-only/full filesystem?), logging disabled\n".utf8))
			}
		}

		public func log(event: LogEvent) {
			let dateTime = Helpers.formattedDateTime(Date())
			let file = Helpers.shortFile(event.file)
			let logMessage = Helpers.package(message: event.message.description, metadata: event.metadata, includePrivate: false)
			let logLine = "\(dateTime) [\(!label.isEmpty ? label : event.source)] [\(event.level.string)] \(file):\(event.line) (\(event.function)): \(logMessage)\n"
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

	/// Close the log file
	public func close() {
		queue.sync {
			fileWriter?.assumeIsolated { writer in
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

extension Destination.File {
	/// An actor that serializes file I/O using the destination's queue as its executor.
	actor FileWriter {
		private let url: URL
		private var fileHandle: FileHandle?
		private let fileHandling: Destination.LogRotation
		private let executorQueue: DispatchSerialQueue

		nonisolated var unownedExecutor: UnownedSerialExecutor {
			executorQueue.asUnownedSerialExecutor()
		}

		init?(
			url: URL,
			fileHandling: Destination.LogRotation = .unbounded,
			queue: DispatchSerialQueue
		) {
			self.url = url
			executorQueue = queue
			self.fileHandling = fileHandling
			fileHandle = Self.openFile(at: url)
			if fileHandle == nil {
				return nil
			}

#if SUPPORTS_LOGROTATE
			if case .useLogRotate = fileHandling {
				let signalSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: executorQueue)
				signalSource.setEventHandler { [weak self] in
					Task {
						await self?.reopen()
					}
				}
				signalSource.resume()
			}
#endif
		}

		deinit {
			try? fileHandle?.close()
		}

		static func openFile(at url: URL) -> FileHandle? {
			if !FileManager.default.fileExists(atPath: url.path) {
				FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
			}
			let fileHandle = try? FileHandle(forUpdating: url)
			_ = fileHandle?.seekToEndOfFile()
			return fileHandle
		}

#if SUPPORTS_LOGROTATE
		func reopen() {
			try? fileHandle?.close()
			fileHandle = Self.openFile(at: url)
		}
#endif

		func write(_ string: String) {
			guard !string.isEmpty,
			      let data = string.data(using: .utf8)
			else {
				return
			}

			// Write whatever we have, then check the resulting size.
			fileHandle?.write(data)

			switch fileHandling {
#if SUPPORTS_LOGROTATE
			case .useLogRotate:
				fallthrough
#endif

			case .unbounded:
				return

			case let .rotateAt(sizeMax, maxIndex):
				guard let curOffset = try? fileHandle?.offset() else {
					// Couldn't check the resulting size, so just return
					return
				}

				if curOffset >= sizeMax {
					close()
					Helpers.rotate(baseURL: url, maxIndex: maxIndex)
					fileHandle = Self.openFile(at: url)
				}
			}
		}

		func close() {
			try? fileHandle?.close()
			fileHandle = nil
		}
	}
}
