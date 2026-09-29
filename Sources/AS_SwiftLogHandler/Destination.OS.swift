//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

#if canImport(os.log)
import Foundation
import Logging
import os.log
import Synchronization

extension Destination {
	/**
	 A `LogHandler` destination that sends log output to OSLog.
	 */
	public struct OS: LogHandler, Sendable {
		/// The map structure that converts `swift-log` Logger.Level to OSLogType
		public struct LevelMap: Sendable {
			/// The defaults that we believe map between `Logging.Logger.Level`
			/// and `OSLogType`.
			public static let defaultMap = LevelMap(
				map: [
					.trace: .debug,
					.debug: .debug,
					.info: .info,
					.notice: .default,
					.warning: .default,
					.error: .error,
					.critical: .fault,
				]
			)

			/// The internal, active map
			let map: [Logging.Logger.Level: OSLogType]

			/// Create a new LevelMap with the specified dictionary
			init(map: [Logging.Logger.Level: OSLogType]? = nil) {
				self.map = map ?? Self.defaultMap.map
			}

			/// Given the current `LevelMap` modify the one entry to the new value and return that.
			func remap(_ from: Logging.Logger.Level, to: OSLogType) -> Self {
				var newMap = map
				newMap[from] = to
				return .init(map: newMap)
			}

			func osLogType(_ level: Logging.Logger.Level) -> OSLogType {
				map[level] ?? .default
			}
		}

		public var logLevel: Logging.Logger.Level
		public var metadata: Logging.Logger.Metadata = .init()
		public var metadataProvider: Logging.Logger.MetadataProvider?
		/// The label (source) for this logHandler
		let label: String
		/// The actual OS logger
		let osLog: OSLog
		/// The level map of `swift-log` Logger.Level to `OSLogType`
		let osLogMap: LevelMap

		public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
			get {
				metadata[key]
			}
			set {
				metadata[key] = newValue
			}
		}

		/**
		 Create an `OS` destination

		 This will create an OSLog-backed log handler using the specified subsystem and category,
		 logging the specified log levels.

		 - Parameter subsystem: the OSLog subsystem, defaults to the main bundle identifier
		 - Parameter label: the OSLog category, and the label to use on this LogHandler
		 - Parameter logLevel: the log levels to send to OSLog
		 - Parameter levelMap: the mapping of `swift-log` levels to `OSLogType` values
		 - Parameter metadataProvider: the optional Metadata provider to use with this logger
		 */
		public init(
			subsystem: String = Bundle.main.bundleIdentifier ?? "SwiftLogHandler",
			label: String,
			logLevel: Logging.Logger.Level = .trace,
			levelMap: LevelMap = .defaultMap,
			metadataProvider: Logging.Logger.MetadataProvider? = nil
		) {
			self.logLevel = logLevel
			self.label = label
			osLog = OSLog(subsystem: subsystem, category: label)
			osLogMap = levelMap
			self.metadataProvider = metadataProvider
		}

		public func log(event: Logging.LogEvent) {
			let file = Helpers.shortFile(event.file)
			let metadata = Helpers.prepareMetadata(
				base: metadata,
				provider: metadataProvider,
				explicit: event.metadata,
				error: event.error
			)
			// message is already sanitized as I've already handled %{public}@ and %{private}@, along with the "new" String Interpolation formatting
			os_log(
				"%{public}@",
				log: osLog,
				type: osLogMap.osLogType(event.level),
				"[\(event.level.string)] \(file):\(event.line) (\(event.function)): \(Helpers.package(message: event.message.description, metadata: metadata, includePrivate: false))"
			)
		}
	}
}
#endif
