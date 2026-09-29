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

	private static func openFile(at url: URL) -> FileHandle? {
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

	private var pendingData: ([Data], UInt64) = ([], 0)
	private let maxDataSize: UInt64 = 1_000_000 // Max size stored in the pendingData buffer

	func write(_ string: String) {
		guard !string.isEmpty,
		      let data = string.data(using: .utf8)
		else {
			return
		}

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
