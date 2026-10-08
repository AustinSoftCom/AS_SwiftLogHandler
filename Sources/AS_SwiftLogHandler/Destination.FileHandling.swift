//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging

extension Destination {
	/// How to handle log file growth
	public enum LogRotation: Sendable {
#if SUPPORTS_LOGROTATE
		/// Use the external tool `logRotate` to manage log file sizes.
		///
		/// Before each write, the destination checks whether its file has been renamed
		/// or removed, and if so reopens it at the original path. Text files are
		/// opened for appending, so logrotate's `copytruncate` also works with them.
		/// SQLite databases use a rollback journal instead of WAL, since a WAL file
		/// doesn't follow a renamed database; don't use `copytruncate` with them.
		case useLogRotate
#endif
		/// Internally rotate log files when they meet or exceed the specified size,
		/// renaming older files up to and including `maxIndex` (so file.1, file.2, file.3,
		/// ...file.n) where `n` == `maxIndex`
		case rotateAt(size: UInt64, maxIndex: Int)
		/// Let log files grow unbounded. Not recommended, but permitted.
		case unbounded

#if os(macOS) || os(visionOS)
		/// The default setting for LogRotation, specified by platform.
		public static let `default`: LogRotation = .rotateAt(size: 1024 * 1024, maxIndex: 5)
#elseif os(watchOS)
		/// The default setting for LogRotation, specified by platform.
		public static let `default`: LogRotation = .rotateAt(size: 32 * 1024, maxIndex: 3)
#elseif os(iOS) || os(tvOS)
		/// The default setting for LogRotation, specified by platform.
		public static let `default`: LogRotation = .rotateAt(size: 64 * 1024, maxIndex: 3)
#else
		/// The default setting for LogRotation, specified by platform.
		public static let `default`: LogRotation = .rotateAt(size: 1024 * 1024, maxIndex: 5)
#endif
	}

	/// Common file-management operations for file-backed log destinations,
	/// such as deleting, sizing, closing, and flushing their underlying files.
	public protocol FileHandling {
		/// Returns the number of LogHandlers refer to this open object
		var openCount: Int { get }
		/// Deletes everything related to this URL, plus any "old" files (.1, .2, .etc)
		static func ensureDeleted(url: URL)
		/// Returns the fileURLs related to this URL, mainly for SQLite files (-wal, -shm)
		static func fileURLs(from url: URL) -> [URL]
		/// Returns the total size of the *current* (non-rotated) log file,
		/// including any companion files (e.g. SQLite's -wal and -shm).
		static func size(url: URL) -> UInt64

		/// Opens the log file if it's not already open
		func open() -> Bool
		/// Closes the log file, nothing else will be written to this log file
		func close()
		/// Flush the in-progress logging output (synchronous version)
		func flush()
		/// Flush the in-progress logging output (asynchronous version)
		func flush() async
	}
}
