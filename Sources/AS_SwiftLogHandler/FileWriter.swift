//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Foundation
import Synchronization

/// An actor that serializes file I/O using the destination's queue as its executor.
actor FileWriter {
	let url: URL
	private var fileHandle: FileHandle?
	let fileHandling: Destination.LogRotation
	let executorQueue: DispatchSerialQueue
	private(set) var openCount: Int

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
		openCount = 1
	}

	deinit {
		try? fileHandle?.close()
	}

	private static func openFile(at url: URL) -> FileHandle? {
		// O_APPEND keeps every write at the end of the file, even after an external
		// tool (such as logrotate's copytruncate) truncates it.
		let fileDescriptor = openForAppending(url.path)
		guard fileDescriptor >= 0 else {
			return nil
		}
		return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
	}

#if SUPPORTS_LOGROTATE
	/// Reopens the file if something else (such as logrotate) has renamed or removed it.
	private func reopenIfReplaced() {
		guard openCount > 0 else {
			return
		}
		let openIdentity = fileHandle.flatMap { FileIdentity(fileDescriptor: $0.fileDescriptor) }
		guard openIdentity == nil || openIdentity != FileIdentity(path: url.path) else {
			return
		}
		try? fileHandle?.close()
		fileHandle = Self.openFile(at: url)
	}
#endif

	private var pendingData: ([Data], UInt64) = ([], 0)
	private let maxDataSize: UInt64 = 1_000_000 // Max size stored in the pendingData buffer

	func write(_ string: String) {
		guard !string.isEmpty,
		      let data = string.data(using: .utf8)
		else {
			return
		}

#if SUPPORTS_LOGROTATE
		if case .useLogRotate = fileHandling {
			reopenIfReplaced()
		}
#endif

		pendingData.0.append(data)
		pendingData.1 += UInt64(data.count)

		flushPending()

		while pendingData.1 > maxDataSize,
		      !pendingData.0.isEmpty
		{
			let dropped = pendingData.0.removeFirst()
			pendingData.1 -= UInt64(dropped.count)
		}
	}

	private func flushPending() {
		// Write data while we still can
		while fileHandle != nil,
		      !pendingData.0.isEmpty
		{
			let data = pendingData.0[0]
			do {
				try fileHandle?.write(contentsOf: data)
				pendingData.0.removeFirst()
				pendingData.1 -= UInt64(data.count)
				checkRotation()
			} catch {
				// Still can't write, bail on the loop keeping the pendingData intact
				break
			}
		}
	}

	private func checkRotation() {
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
				// Do this "under the hood" so that we don't touch the output's openCount.
				try? fileHandle?.close()
				fileHandle = nil
				Helpers.rotate(baseURL: url, maxIndex: maxIndex)
				fileHandle = Self.openFile(at: url)
			}
		}
	}

	func open() -> Bool {
		guard openCount == 0 else {
			openCount += 1
			return true
		}
		fileHandle = Self.openFile(at: url)
		if fileHandle != nil {
			openCount = 1
		}
		return fileHandle != nil
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
		try? fileHandle?.close()
		fileHandle = nil
		openCount = 0
	}
}

/// Opens (creating if needed) a file for appending, returning its file descriptor or -1.
/// This is outside `FileWriter` so that `open` isn't shadowed by `FileWriter.open()`.
private func openForAppending(_ path: String) -> Int32 {
	open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
}
