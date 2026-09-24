# AS_SwiftLogHandler

[![CI](https://github.com/AustinSoftCom/AS_SwiftLogHandler/actions/workflows/ci.yml/badge.svg)](https://github.com/AustinSoftCom/AS_SwiftLogHandler/actions/workflows/ci.yml)

A set of [swift-log](https://github.com/apple/swift-log) `LogHandler` backends for Apple platforms that can *write* log messages to OSLog, a plain-text file, or a SQLite database — and *read them back* as structured entries.

## Features

- **Three destinations**, all value-semantic `LogHandler` structs:
  - `Destination.OS` — forwards to the unified logging system (OSLog), with a configurable mapping from `Logger.Level` to `OSLogType`.
  - `Destination.File` — writes formatted lines to a text file.
  - `Destination.SQLFile` — writes entries to a SQLite database (WAL mode), one row per log entry with metadata stored as JSONB.
- **Log rotation** for both file destinations via `Destination.LogRotation`:
  - `.rotateAt(size:maxIndex:)` — when the file meets or exceeds `size`, it is rotated to `.1`, `.1` to `.2`, and so on up to `maxIndex`. **This is the default.**
    - The default for this value for the file loggers is plaform-specific:
      - macOS/visionOS: `.rotateAt(size: 1024 * 1024, maxIndex: 5)`
      - watchOS: `.rotateAt(size: 32 * 1024, maxIndex: 3)`
      - iOS/tvOS: `.rotateAt(size: 64 * 1024, maxIndex: 3)`
      - anything else: `.rotateAt(size: 1024 * 1024, maxIndex: 5)`
  - `.useLogRotate` (non-mobile/embedded platforms only) — leaves rotation to an external tool such as `newsyslog`/`logrotate`; the file destination reopens its file on `SIGHUP`.
  - `.unbounded` — no rotation; the file grows without limit.
- **Read logs back** — `Destination.File` and `Destination.SQLFile` conform to `Reader`, returning `[SwiftLogEntry]` (including entries from the most recent rotated file), optionally filtered with a closure:

  ```swift
  let errors = try await handler.read(matching: { $0.level == .error })
  ```

- **Structured metadata** — `Logger.Metadata` is preserved as a `Codable`, `Sendable` `JSONValue` tree and round-trips through both file formats. Metadata under the key `"private"` is never written to disk.
- **Swift 6 native** — strict-concurrency clean; file I/O is serialized through actors backed by a `DispatchSerialQueue`, so the synchronous `log(event:)` path never races with reads, flushes, or rotation.

## Requirements

- Swift 6.3 toolchain or later
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+

Dependencies: [swift-log](https://github.com/apple/swift-log).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AustinSoftCom/AS_SwiftLogHandler.git", from: "1.0.0"),
],
```

and add the product to any target that needs it:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "AS_SwiftLogHandler", package: "AS_SwiftLogHandler"),
    ]
),
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL.

## Usage

### Logging to OSLog

```swift
import AS_SwiftLogHandler
import Logging

LoggingSystem.bootstrap { label in
    Destination.OS(label: label)
}

let logger = Logger(label: "MyApp")
logger.info("Hello from swift-log", metadata: ["user": "glenn"])
```

`Destination.OS` uses your bundle identifier as the OSLog subsystem by default and the label as the category. The default level mapping can be customized:

```swift
let levelMap = Destination.OS.LevelMap.defaultMap.remap(.notice, to: .info)
let handler = Destination.OS(subsystem: "com.example.app", label: "Networking", levelMap: levelMap)
```

### Logging to a file

```swift
let url = URL.documentsDirectory.appending(path: "MyApp.log")

LoggingSystem.bootstrap { label in
    Destination.File(
        label: label,
        url: url,
        fileHandling: .rotateAt(size: 48 * 1024, maxIndex: 5)
    )
}
```

Each line contains a GMT timestamp with sub-millisecond precision, the label, level, source file, line, function, message, and JSON-encoded metadata.

### Logging to a SQLite file

```swift
LoggingSystem.bootstrap { label in
    Destination.SQLFile(
        label: label,
        url: URL.documentsDirectory.appending(path: "MyApp.sqlog"),
        fileHandling: .rotateAt(size: 128 * 1024, maxIndex: 5)
    )
}
```

Entries are written to a `logs` table; the database uses WAL journaling, and `size(url:)`/rotation account for the `-wal` and `-shm` sidecar files.

### Logging to more than one destination at once

Use swift-log's `MultiplexLogHandler` to fan out to several destinations:

```swift
LoggingSystem.bootstrap { label in
    MultiplexLogHandler([
        Destination.OS(label: label),
        Destination.File(label: label, url: url),
    ])
}
```

### Reading logs back

Both file destinations conform to `Reader`:

```swift
let handler = Destination.SQLFile(label: "MyApp", url: url)

// Everything, oldest first (including the most recent rotated file):
let all: [SwiftLogEntry] = try await handler.read()

// Or filtered with a closure:
let recentErrors = try await handler.read(matching: {
    $0.level == .error && $0.date > cutoff
})
```

`SwiftLogEntry` carries the timestamp, module name (label), level, source file, line number, function, message, and metadata (as `JSONValue?`), and is `Comparable` by date.

### File maintenance

`Destination.File` and `Destination.SQLFile` conform to `Destination.FileHandling`:

```swift
handler.flush()                            // synchronous barrier — all pending writes done
await handler.flush()                      // async version
handler.close()                            // close the file; this handler won't reopen it

Destination.SQLFile.size(url: url)         // current size on disk (incl. -wal/-shm)
Destination.SQLFile.fileURLs(from: url)    // all files that make up the log
Destination.SQLFile.ensureDeleted(url: url)// delete the log and all rotated copies
```

## Behavior notes

- **Rotation:** with `.rotateAt`, the current file is renamed to `<name>.1`, existing `<name>.n` files shift to `<name>.n+1`, and anything beyond `maxIndex` is deleted. `read()` returns entries from `<name>.1` followed by the current file.
- **Levels on disk** are stored as emoji (🧵 trace, 🐞 debug, ℹ️ info, 📝 notice, ⚠️ warning, ❌ error, 🛑 critical), which keeps them compact and easy to spot when eyeballing a raw log file.
- **Private metadata:** any top-level metadata key named `"private"` is stripped before an entry is written to any destination.
- **Value semantics:** the handlers are structs, so copies made by `Logger` behave correctly — changing `logLevel` or metadata on one logger never affects another, while all copies share the same underlying file writer.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

AS_SwiftLogHandler is released under the MIT License. See [LICENSE.txt](LICENSE.txt) for details.

Copyright © 2026 Glenn L. Austin (AustinSoft.com)
