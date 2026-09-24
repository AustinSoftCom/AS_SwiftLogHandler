//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging

/// A concrete, `Sendable` and `Codable` representation of a JSON value,
/// used to store and retrieve log entry metadata.
public enum JSONValue: Sendable, Codable, Equatable {
	/// ← Sendable AND Codable, concrete
	/// A JSON string.
	case string(String)
	/// A JSON number.
	case number(Double)
	/// A JSON boolean.
	case bool(Bool)
	/// A JSON object keyed by string.
	case object([String: JSONValue]) // recursive, still Sendable
	/// A JSON array.
	case array([JSONValue])
	/// A JSON null.
	case null

	init(_ value: Logger.MetadataValue) {
		switch value {
		case let .string(s):
			self = .string(s)

		case let .stringConvertible(s):
			switch s {
			case let n as Bool:
				self = .bool(n)
			case let n as any SignedInteger:
				self = .number(Double(n))
			case let n as any UnsignedInteger:
				self = .number(Double(n))
			case let n as Float:
				self = .number(Double(n))
			case let n as Double:
				self = .number(n)
			case let n as NSNumber:
				self = .number(n.doubleValue)
			default:
				self = .string(s.description)
			}

		case let .dictionary(d):
			self = .object(d.mapValues { JSONValue($0) })

		case let .array(a):
			self = .array(a.map { JSONValue($0) })
		}
	}

	init?(metadata: [String: Logger.MetadataValue]?) {
		guard let metadata else {
			return nil
		}
		let obj = metadata.reduce(into: [String: JSONValue]()) { partialResult, keyValue in
			partialResult[keyValue.key] = JSONValue(keyValue.value)
		}
		self = .object(obj)
	}
}

/// A single log entry read back from a destination's storage.
public struct SwiftLogEntry: Equatable, Comparable, Sendable {
	/// The timestamp of the log entry.
	public let date: Date
	/// The label (source) of the LogHandler that wrote the entry.
	public let moduleName: String
	/// The log level of the entry.
	public let level: Logger.Level
	/// The short file name where the entry was logged.
	public let file: String
	/// The line number where the entry was logged.
	public let lineNumber: UInt
	/// The function where the entry was logged.
	public let function: String
	/// The log message text.
	public let message: String
	/// The metadata attached to the entry, if any.
	public let metadata: JSONValue?

	/**
	 Create a log entry from `swift-log` metadata.

	 - Parameter date: the timestamp of the log entry
	 - Parameter moduleName: the label (source) of the LogHandler that wrote the entry
	 - Parameter level: the log level of the entry
	 - Parameter file: the short file name where the entry was logged
	 - Parameter lineNumber: the line number where the entry was logged
	 - Parameter function: the function where the entry was logged
	 - Parameter message: the log message text
	 - Parameter metadata: the `Logger.Metadata` attached to the entry, converted to ``JSONValue``
	 */
	public init(
		date: Date,
		moduleName: String,
		level: Logger.Level,
		file: String,
		lineNumber: UInt,
		function: String,
		message: String,
		metadata: Logger.Metadata?
	) {
		self.date = date
		self.moduleName = moduleName
		self.level = level
		self.file = file
		self.lineNumber = lineNumber
		self.function = function
		self.message = message
		self.metadata = JSONValue(metadata: metadata)
	}

	/**
	 Create a log entry from already-decoded metadata.

	 - Parameter date: the timestamp of the log entry
	 - Parameter moduleName: the label (source) of the LogHandler that wrote the entry
	 - Parameter level: the log level of the entry
	 - Parameter file: the short file name where the entry was logged
	 - Parameter lineNumber: the line number where the entry was logged
	 - Parameter function: the function where the entry was logged
	 - Parameter message: the log message text
	 - Parameter metadata: the metadata attached to the entry, if any
	 */
	public init(
		date: Date,
		moduleName: String,
		level: Logger.Level,
		file: String,
		lineNumber: UInt,
		function: String,
		message: String,
		metadata: JSONValue?
	) {
		self.date = date
		self.moduleName = moduleName
		self.level = level
		self.file = file
		self.lineNumber = lineNumber
		self.function = function
		self.message = message
		self.metadata = metadata
	}

	public static func < (lhs: SwiftLogEntry, rhs: SwiftLogEntry) -> Bool {
		lhs.date < rhs.date
	}

	public static func == (lhs: SwiftLogEntry, rhs: SwiftLogEntry) -> Bool {
		lhs.date == rhs.date
			&& lhs.moduleName == rhs.moduleName
			&& lhs.level == rhs.level
			&& lhs.file == rhs.file
			&& lhs.lineNumber == rhs.lineNumber
			&& lhs.function == rhs.function
			&& lhs.message == rhs.message
	}
}
