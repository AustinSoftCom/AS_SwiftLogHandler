//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Logging

extension Logger.Level {
	/// Errors thrown when converting between `Logger.Level` and its string representation.
	public enum LogLevelError: Error {
		/// The string does not correspond to any `Logger.Level`.
		case invalidValue(String)
	}

	/// String value for the option
	var string: String {
		switch self {
		case .trace:
			"🧵"
		case .debug:
			"🐞"
		case .info:
			"ℹ️"
		case .notice:
			"📝"
		case .warning:
			"⚠️"
		case .error:
			"❌"
		case .critical:
			"🛑"
		}
	}

	static func from(string: any StringProtocol) throws -> Self {
		let string = String(string)
		switch string {
		case "🧵":
			return .trace
		case "🐞":
			return .debug
		case "ℹ️":
			return .info
		case "📝":
			return .notice
		case "⚠️":
			return .warning
		case "❌":
			return .error
		case "🛑":
			return .critical
		default:
			throw LogLevelError.invalidValue(string)
		}
	}
}
