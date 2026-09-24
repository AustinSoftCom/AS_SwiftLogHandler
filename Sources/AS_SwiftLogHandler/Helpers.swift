//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging

// MARK: - Default helpers for destinations

enum Helpers {
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
		// Don't move ".0" to ".1", since .0 doesn't exist.
		let fileManager = FileManager()
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
}
