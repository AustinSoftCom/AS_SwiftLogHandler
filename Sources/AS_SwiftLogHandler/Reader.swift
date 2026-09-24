//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation

/// Errors thrown while reading log entries back from a destination.
public enum ReaderError: Error {
	/// The date string could not be parsed.
	case invalidDateString(String)
	/// The parsed date was invalid.
	case invalidDate
	/// The underlying database returned the given SQLite error code.
	case dbError(Int32)
}

/// A log destination whose stored entries can be read back as `SwiftLogEntry` values.
public protocol Reader: Sendable {
	/**
	 Read log entries from the underlying storage.

	 - Parameter matching: an optional closure to filter entries.
	 If `nil`, all entries are returned.
	 - Returns: array of matching `SwiftLogEntry`.
	 */
	func read(matching: (@Sendable (SwiftLogEntry) -> Bool)?) async throws -> [SwiftLogEntry]
}

extension Reader {
	/// Convenience overload that reads every entry.
	public func read() async throws -> [SwiftLogEntry] {
		try await read(matching: nil)
	}
}

extension Reader {
	/**
	 Parse a high-precision timestamp string (`yyyy-MM-dd HH:mm:ss.fffffff`) into a `Date`.

	 The whole-second portion is parsed with the shared ISO 8601 format style, and any
	 fractional-second component is parsed separately and added to the result.

	 - Parameter string: the timestamp string to parse
	 - Returns: the parsed date
	 - Throws: ``ReaderError/invalidDateString(_:)`` if the string cannot be parsed
	 */
	public func dateFrom(string: any StringProtocol) throws -> Date {
		let parts = string.split(separator: ".")
		var date: Date
		if !parts.isEmpty {
			date = try Helpers.dateFormatter.parse(String(parts[0]))
		} else {
			throw ReaderError.invalidDateString(String(string))
		}
		if parts.count > 1 {
			// Add the fractional seconds
			let fracSecs = Double("0.\(String(parts[1]))")
			date.addTimeInterval(fracSecs ?? 0)
		}
		return date
	}
}
