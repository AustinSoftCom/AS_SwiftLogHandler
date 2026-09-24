//  Copyright © 2026 Glenn L. Austin (AustinSoft.com)
//  Licensed under the MIT License. See LICENSE.txt for details.

#if canImport(os.log)
@testable import AS_SwiftLogHandler
import Foundation
@testable import Logging
import os.log
import Testing

@Suite
struct DestinationOSTests {
	@Test
	func defaultLevelMapCoversAllLevels() {
		let map = Destination.OS.LevelMap.defaultMap

		#expect(map.osLogType(.trace) == .debug)
		#expect(map.osLogType(.debug) == .debug)
		#expect(map.osLogType(.info) == .info)
		#expect(map.osLogType(.notice) == .default)
		#expect(map.osLogType(.warning) == .default)
		#expect(map.osLogType(.error) == .error)
		#expect(map.osLogType(.critical) == .fault)

		// Every Logger.Level must have an explicit entry in the default map
		#expect(map.map.count == Logger.Level.allCases.count)
	}

	@Test
	func levelMapNilInitializerUsesDefaults() {
		let map = Destination.OS.LevelMap(map: nil)

		#expect(map.map == Destination.OS.LevelMap.defaultMap.map)
	}

	@Test
	func levelMapReturnsDefaultForUnmappedLevel() {
		// A partial map: anything missing must fall back to .default
		let map = Destination.OS.LevelMap(map: [.error: .fault])

		#expect(map.osLogType(.error) == .fault)
		#expect(map.osLogType(.trace) == .default)
		#expect(map.osLogType(.critical) == .default)
	}

	@Test
	func remapChangesOnlyTheRequestedLevel() {
		let original = Destination.OS.LevelMap.defaultMap
		let remapped = original.remap(.notice, to: .info)

		#expect(remapped.osLogType(.notice) == .info)

		// All other entries are unchanged
		for level in Logger.Level.allCases where level != .notice {
			#expect(remapped.osLogType(level) == original.osLogType(level))
		}

		// The original map is unaffected (value semantics)
		#expect(original.osLogType(.notice) == .default)
	}

	@Test
	func initStoresConfiguration() {
		let levelMap = Destination.OS.LevelMap.defaultMap.remap(.warning, to: .error)
		let handler = Destination.OS(
			subsystem: "com.austinsoft.tests",
			label: "OSTests",
			logLevel: .warning,
			levelMap: levelMap
		)

		#expect(handler.label == "OSTests")
		#expect(handler.logLevel == .warning)
		#expect(handler.osLogMap.map == levelMap.map)
		#expect(handler.metadata.isEmpty)
	}

	@Test
	func initDefaults() {
		let handler = Destination.OS(label: "OSTests")

		#expect(handler.logLevel == .trace)
		#expect(handler.osLogMap.map == Destination.OS.LevelMap.defaultMap.map)
	}

	@Test
	func metadataSubscriptGetSetAndRemove() {
		var handler = Destination.OS(label: "OSTests")

		#expect(handler[metadataKey: "key"] == nil)

		handler[metadataKey: "key"] = "value"
		#expect(handler[metadataKey: "key"] == "value")
		#expect(handler.metadata["key"] == "value")

		handler[metadataKey: "key"] = nil
		#expect(handler[metadataKey: "key"] == nil)
		#expect(handler.metadata.isEmpty)
	}
}
#endif
