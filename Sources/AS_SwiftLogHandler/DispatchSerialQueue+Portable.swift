//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

import Dispatch

#if !canImport(Darwin)
/**
 A serial `DispatchQueue` that can act as an actor's executor.

 Apple platforms provide `DispatchSerialQueue`, but swift-corelibs-libdispatch
 does not, and its `DispatchQueue` doesn't conform to `SerialExecutor`. This
 provides the subset of `DispatchSerialQueue` used here, so the public API is
 the same on every platform.
 */
public final class DispatchSerialQueue: SerialExecutor, Sendable {
	/// The underlying `DispatchQueue` that runs the jobs
	let dispatchQueue: DispatchQueue

	/**
	 Creates a new serial dispatch queue.

	 - Parameter label: a string label to attach to the queue to uniquely identify it
	 - Parameter qos: the quality-of-service level to associate with the queue
	 */
	public init(label: String, qos: DispatchQoS = .unspecified) {
		dispatchQueue = DispatchQueue(label: label, qos: qos)
	}

	/// Submits a work item for execution and returns its result after it finishes.
	func sync<T>(execute work: () throws -> T) rethrows -> T {
		try dispatchQueue.sync(execute: work)
	}

	public func enqueue(_ job: consuming ExecutorJob) {
		let job = UnownedJob(job)
		dispatchQueue.async {
			job.runSynchronously(on: self.asUnownedSerialExecutor())
		}
	}

	public func checkIsolated() {
		dispatchPrecondition(condition: .onQueue(dispatchQueue))
	}
}
#endif
