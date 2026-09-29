//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Logging
import SQLite3
import Synchronization

private let SQLITE_TRANSIENT: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = unsafeBitCast(uintptr_t.max, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

/// An actor that serializes file I/O using the destination's queue as its executor.
actor SQLiteFile {
	let url: URL?
	let fileHandling: Destination.LogRotation
	var sqlite: SQLiteInfo?
	private var writesTilNextCheck: Int
	static let defaultWritesTilNextCheck = 100
	let executorQueue: DispatchSerialQueue
	private(set) var openCount: Int

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		executorQueue.asUnownedSerialExecutor()
	}

	init?(queue: DispatchSerialQueue) {
		url = nil
		fileHandling = .unbounded
		executorQueue = queue
		sqlite = SQLiteInfo(url: url)
		if sqlite != nil {
			openCount = 1
		} else {
			openCount = 0
		}
		writesTilNextCheck = 0
	}

	init?(url: URL, fileHandling: Destination.LogRotation = .unbounded, queue: DispatchSerialQueue) {
		self.url = url
		self.fileHandling = fileHandling
		executorQueue = queue
		// Don't append to the current log file if it's already larger than the rotateAt size, if .rotateAt is set.
		if case let .rotateAt(size: maxSize, maxIndex: maxIndex) = fileHandling {
			let totalSize = Destination.SQLFile.size(url: url)

			if totalSize > maxSize {
				Helpers.rotate(baseURL: url, maxIndex: maxIndex)
				// Make sure the leftover WAL and SHM files are deleted
				let fileManager = FileManager()
				for fileUrl in Destination.SQLFile.fileURLs(from: url) {
					try? fileManager.removeItem(at: fileUrl)
				}
			}
		}

		sqlite = SQLiteInfo(url: url)

		if sqlite == nil {
			// Couldn't open the file, so try to rotate the existing log file and try again.
			if case let .rotateAt(_, maxIndex) = fileHandling {
				Helpers.rotate(baseURL: url, maxIndex: maxIndex)
			} else {
				Helpers.rotate(baseURL: url, maxIndex: 1)
			}
			// Make sure the leftover WAL and SHM files are deleted
			let fileManager = FileManager()
			for fileUrl in Destination.SQLFile.fileURLs(from: url) {
				try? fileManager.removeItem(at: fileUrl)
			}
			sqlite = SQLiteInfo(url: url)
		} else {
			openCount = 0
		}

		if sqlite != nil {
			openCount = 1
		} else {
			openCount = 0
		}
		writesTilNextCheck = 0

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

	func checkAndRotateFile() -> Int {
		guard sqlite != nil else {
			return Self.defaultWritesTilNextCheck
		}

		switch fileHandling {
#if SUPPORTS_LOGROTATE
		case .useLogRotate:
			fallthrough
#endif

		case .unbounded:
			return Self.defaultWritesTilNextCheck

		case let .rotateAt(size: maxSize, maxIndex: maxIndex):
			guard let url else {
				return Self.defaultWritesTilNextCheck
			}

			let calcNumChecks: (UInt64) -> Int = {
				let v = $0 / 400
				return Int(max(10, min(v, 1000)))
			}
			let totalSize = Destination.SQLFile.size(url: url)

			if totalSize > maxSize {
				sqlite?.close()
				sqlite = nil
				Helpers.rotate(baseURL: url, maxIndex: maxIndex)
				// Make sure the leftover WAL and SHM files are deleted
				let fileManager = FileManager()
				for fileUrl in Destination.SQLFile.fileURLs(from: url) {
					try? fileManager.removeItem(at: fileUrl)
				}
				sqlite = SQLiteInfo(url: url)
				return calcNumChecks(maxSize)
			} else {
				return calcNumChecks(maxSize - totalSize)
			}
		}
	}

#if SUPPORTS_LOGROTATE
	func reopen() {
		sqlite?.close()
		sqlite = SQLiteInfo(url: url)
	}
#endif

	func open() -> Bool {
		guard sqlite == nil else {
			openCount += 1
			return false
		}
		if openCount == 0 {
			sqlite = SQLiteInfo(url: url)
			if sqlite != nil {
				openCount = 1
			}
		} else {
			openCount += 1
		}
		return sqlite != nil
	}

	nonisolated func openSync() -> Bool {
		executorQueue.sync {
			self.assumeIsolated {
				$0.open()
			}
		}
	}

	func close() {
		guard openCount == 1 else {
			openCount -= 1
			return
		}
		sqlite?.close()
		sqlite = nil
		openCount = 0
	}
}

extension SQLiteFile {
	func bindUInt(_ value: UInt, stmt: OpaquePointer?, at index: FieldIndex) {
		sqlite3_bind_int64(stmt, index.bindIndex, Int64(value))
	}

	func bindDate(_ value: Date, stmt: OpaquePointer?, at index: FieldIndex) {
		sqlite3_bind_double(stmt, index.bindIndex, value.timeIntervalSince1970)
	}

	func bindText(_ value: String, stmt: OpaquePointer?, at index: FieldIndex) {
		// Strings *can* contain NUL, so saving all the bytes and supply the length
		let bytes = value.utf8.map { Int8(bitPattern: $0) }

		sqlite3_bind_text(stmt, index.bindIndex, bytes, Int32(bytes.count), SQLITE_TRANSIENT)
	}

	func bindMetadata(_ value: Logger.Metadata?, stmt: OpaquePointer?, at index: FieldIndex) {
		guard let jsonValue = JSONValue(metadata: value),
		      let jsonData = try? JSONEncoder().encode(jsonValue)
		else {
			sqlite3_bind_null(stmt, index.bindIndex)
			return
		}
		_ = jsonData.withUnsafeBytes { buffer in
			sqlite3_bind_blob(stmt, index.bindIndex, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
		}
	}

	func write(
		_ level: Logger.Level,
		date: Date,
		module: String,
		message: String,
		metadata: Logger.Metadata?,
		file: String,
		function: String,
		line: UInt
	) {
		guard sqlite != nil,
		      sqlite?.dbOpen ?? false
		else {
			return
		}

		if writesTilNextCheck == 0 {
			writesTilNextCheck = checkAndRotateFile()
		} else {
			writesTilNextCheck -= 1
		}

		guard let sqlite else {
			return
		}

		bindDate(date, stmt: sqlite.insertStmt, at: .date)
		bindText(module, stmt: sqlite.insertStmt, at: .moduleName)
		bindText(level.string, stmt: sqlite.insertStmt, at: .level)
		bindText(file, stmt: sqlite.insertStmt, at: .file)
		bindUInt(line, stmt: sqlite.insertStmt, at: .lineNumber)
		bindText(function, stmt: sqlite.insertStmt, at: .function)
		bindText(message, stmt: sqlite.insertStmt, at: .message)
		bindMetadata(metadata, stmt: sqlite.insertStmt, at: .metadata)
		sqlite3_step(sqlite.insertStmt)
		sqlite3_reset(sqlite.insertStmt)
	}
}

extension SQLiteFile {
	/// To keep the code consistent, we're going to use the same indexes for read and bind
	enum FieldIndex: Int32, CaseIterable {
		case date
		case moduleName
		case level
		case file
		case lineNumber
		case function
		case message
		case metadata

		var readIndex: Int32 {
			rawValue
		}

		var bindIndex: Int32 {
			rawValue + 1
		}

		var fieldName: String {
			switch self {
			case .date:
				"date"
			case .moduleName:
				"moduleName"
			case .level:
				"level"
			case .file:
				"file"
			case .lineNumber:
				"lineNumber"
			case .function:
				"function"
			case .message:
				"message"
			case .metadata:
				"metadata"
			}
		}

		var fieldDef: String {
			switch self {
			case .date:
				"TIMESTAMP NOT NULL"
			case .moduleName,
			     .level,
			     .file,
			     .function,
			     .message:
				"TEXT NOT NULL"
			case .lineNumber:
				"INT NOT NULL"
			case .metadata:
				"BLOB"
			}
		}

		var parameter: String {
			switch self {
			case .date,
			     .moduleName,
			     .level,
			     .file,
			     .lineNumber,
			     .function,
			     .message:
				"?"
			case .metadata:
				"jsonb(?)"
			}
		}

		var selectValue: String {
			switch self {
			case .date,
			     .moduleName,
			     .level,
			     .file,
			     .lineNumber,
			     .function,
			     .message:
				fieldName
			case .metadata:
				"json(\(fieldName))"
			}
		}
	}
}

extension SQLiteFile {
	func uint(stmt: OpaquePointer?, at index: FieldIndex) -> UInt {
		UInt(sqlite3_column_int64(stmt, index.readIndex))
	}

	func date(stmt: OpaquePointer?, at index: FieldIndex) -> Date {
		Date(timeIntervalSince1970: sqlite3_column_double(stmt, index.readIndex))
	}

	func text(stmt: OpaquePointer?, at index: FieldIndex) -> String {
		guard let textBytes = sqlite3_column_text(stmt, index.readIndex) else {
			return ""
		}
		let length = Int(sqlite3_column_bytes(stmt, index.readIndex))
		return String(bytes: UnsafeBufferPointer(start: textBytes, count: length), encoding: .utf8) ?? ""
	}

	func jsonValue(stmt: OpaquePointer?, at index: FieldIndex) -> JSONValue? {
		guard let bytes = sqlite3_column_text(stmt, index.readIndex) else {
			return nil
		}
		let length = Int(sqlite3_column_bytes(stmt, index.readIndex))
		let data = Data(bytes: bytes, count: length)
		return try? JSONDecoder().decode(JSONValue.self, from: data)
	}

	func readEntries(from sqlite: SQLiteInfo, matching predicate: ((SwiftLogEntry) -> Bool)? = nil) throws -> [SwiftLogEntry] {
		var entries: [SwiftLogEntry] = []

		sqlite3_reset(sqlite.selectStmt)
		defer {
			sqlite3_reset(sqlite.selectStmt)
		}

		while true {
			let sqliteResult = sqlite3_step(sqlite.selectStmt)
			switch sqliteResult {
			case SQLITE_ROW:
				break
			case SQLITE_DONE:
				return entries
			default:
				throw ReaderError.dbError(sqliteResult)
			}

			let entry = try? SwiftLogEntry(
				date: date(stmt: sqlite.selectStmt, at: .date),
				moduleName: text(stmt: sqlite.selectStmt, at: .moduleName),
				level: .from(string: text(stmt: sqlite.selectStmt, at: .level)),
				file: text(stmt: sqlite.selectStmt, at: .file),
				lineNumber: uint(stmt: sqlite.selectStmt, at: .lineNumber),
				function: text(stmt: sqlite.selectStmt, at: .function),
				message: text(stmt: sqlite.selectStmt, at: .message),
				metadata: jsonValue(stmt: sqlite.selectStmt, at: .metadata)
			)
			if let entry {
				if predicate == nil || predicate!(entry) {
					entries.append(entry)
				}
			}
		}
	}

	func read(matching: (@Sendable (SwiftLogEntry) -> Bool)? = nil) async throws -> [SwiftLogEntry] {
		var entries: [SwiftLogEntry] = []
		if let sqlite {
			if let url {
				let fileManager = FileManager()
				let url2 = url.appendingPathExtension("1")
				if fileManager.fileExists(atPath: url2.path),
				   let sqlite2 = SQLiteInfo(url: url2)
				{
					try entries.append(contentsOf: readEntries(from: sqlite2, matching: matching))
				}
			}

			try entries.append(contentsOf: readEntries(from: sqlite, matching: matching))
		}

		return entries
	}
}

extension SQLiteFile {
	class SQLiteInfo {
		static let dbUserVersion: Int64 = 1

		var dbPointer: OpaquePointer?
		var insertStmt: OpaquePointer?
		var selectStmt: OpaquePointer?
		var rowCountStmt: OpaquePointer?

		var dbOpen: Bool {
			dbPointer != nil
				&& insertStmt != nil
				&& selectStmt != nil
				&& rowCountStmt != nil
		}

		init?(url: URL?) {
			let path: String = if let url {
				url.path()
			} else {
				":memory:"
			}
			var dbPointer: OpaquePointer?
			guard sqlite3_open(path, &dbPointer) == SQLITE_OK,
			      let dbPointer
			else {
				sqlite3_close_v2(dbPointer)
				return nil
			}

			let stmtCreator = { (dbPointer: OpaquePointer, sql: String) throws -> OpaquePointer in
				var stmt: OpaquePointer? = nil
				sqlite3_prepare_v2(dbPointer, sql, -1, &stmt, nil)
				guard let stmt else {
					throw NSError() // Only to abort the init and return nil
				}
				return stmt
			}

			let userVersion = { () -> Int64 in
				guard let userVersionStmt = try? stmtCreator(dbPointer, "PRAGMA user_version") else {
					return -1
				}
				defer {
					sqlite3_finalize(userVersionStmt)
				}

				sqlite3_step(userVersionStmt)
				return sqlite3_column_int64(userVersionStmt, 0)
			}()

			if userVersion != 0, userVersion != Self.dbUserVersion {
				sqlite3_close_v2(dbPointer)
				return nil
			}

			if url != nil {
				sqlite3_exec(dbPointer, "PRAGMA journal_mode=WAL;", nil, nil, nil)
				sqlite3_exec(dbPointer, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
			}
			sqlite3_exec(dbPointer, "PRAGMA auto_vacuum = INCREMENTAL;", nil, nil, nil)

			let fieldDefs = FieldIndex.allCases.map { "\($0.fieldName) \($0.fieldDef)" }.joined(separator: ", ")
			let sql = """
					CREATE TABLE IF NOT EXISTS logs (
						id INTEGER NOT NULL UNIQUE PRIMARY KEY,
						\(fieldDefs)
					)
				"""
			guard sqlite3_exec(dbPointer, sql, nil, nil, nil) == SQLITE_OK else {
				sqlite3_close_v2(dbPointer)
				return nil
			}

			if sqlite3_exec(dbPointer, "PRAGMA user_version = \(Self.dbUserVersion)", nil, nil, nil) != SQLITE_OK {
				sqlite3_close_v2(dbPointer)
				return nil
			}

			var insertStmt: OpaquePointer? = nil
			var selectStmt: OpaquePointer? = nil
			var rowCountStmt: OpaquePointer? = nil
			do {
				let fieldNames = FieldIndex.allCases.map(\.fieldName).joined(separator: ", ")
				let fieldParams = FieldIndex.allCases.map(\.parameter).joined(separator: ", ")
				insertStmt = try stmtCreator(
					dbPointer,
					"INSERT INTO logs (\(fieldNames)) VALUES (\(fieldParams));"
				)
				selectStmt = try stmtCreator(
					dbPointer,
					"SELECT \(FieldIndex.allCases.map(\.selectValue).joined(separator: ", ")) FROM logs ORDER BY id;"
				)
				rowCountStmt = try stmtCreator(dbPointer, "SELECT COUNT(*) FROM logs;")
				guard let insertStmt, let selectStmt, let rowCountStmt else {
					throw NSError()
				}
				self.dbPointer = dbPointer
				self.insertStmt = insertStmt
				self.selectStmt = selectStmt
				self.rowCountStmt = rowCountStmt
			} catch {
				if let rowCountStmt {
					sqlite3_finalize(rowCountStmt)
				}
				if let selectStmt {
					sqlite3_finalize(selectStmt)
				}
				if let insertStmt {
					sqlite3_finalize(insertStmt)
				}
				sqlite3_close_v2(dbPointer)
				return nil
			}
		}

		func close() {
			if let insertStmt {
				sqlite3_finalize(insertStmt)
				self.insertStmt = nil
			}
			if let selectStmt {
				sqlite3_finalize(selectStmt)
				self.selectStmt = nil
			}
			if let rowCountStmt {
				sqlite3_finalize(rowCountStmt)
				self.rowCountStmt = nil
			}
			if let dbPointer {
				sqlite3_close_v2(dbPointer)
				self.dbPointer = nil
			}
		}

		deinit {
			close()
		}
	}
}
