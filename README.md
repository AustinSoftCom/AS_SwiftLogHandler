# AS_SwiftLogHandler

[![CI](https://github.com/AustinSoftCom/AS_SwiftLogHandler/actions/workflows/ci.yml/badge.svg)](https://github.com/AustinSoftCom/AS_SwiftLogHandler/actions/workflows/ci.yml)

A set of [swift-log](https://github.com/apple/swift-log) `LogHandler` backends for Apple platforms and Linux: *write* log messages to OSLog (Apple platforms only), or to a plain-text file or SQLite database — with the file and database destinations able to *read entries back* as structured data.

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
  - `.useLogRotate` (non-mobile/embedded platforms only) — leaves rotation to an external tool such as `newsyslog`/`logrotate`; the file and SQLite destinations notice when their file has been renamed or removed and reopen it, so no `postrotate` signal is needed. The text file destination also works with logrotate's `copytruncate`; don't use `copytruncate` with SQLite databases. With `.useLogRotate`, the SQLite destination uses a rollback journal instead of WAL, since a WAL file doesn't follow a renamed database.
  - `.unbounded` — no rotation; the file grows without limit.
- **Read logs back** — `Destination.File` and `Destination.SQLFile` conform to `Reader`, returning `[SwiftLogEntry]` (including entries from the most recent rotated file), optionally filtered with a closure:

  ```swift
  let errors = try await handler.read(matching: { $0.level == .error })
  ```

- **Shared files** — any number of `Destination.File` (or `Destination.SQLFile`) handlers pointing at the same URL share a single, reference-counted writer, so many loggers can safely write to one file. The file is closed when the last handler using it calls `close()`.
- **Structured metadata** — `Logger.Metadata` is preserved as a `Codable`, `Sendable` `JSONValue` tree and round-trips through both file formats. Metadata under the key `"private"` is never written to disk.
- **Metadata providers** — all three destinations accept a swift-log `Logger.MetadataProvider`, merged with the handler's and the log statement's metadata on every entry.
- **Swift 6 native** — strict-concurrency clean; file I/O is serialized through actors backed by a `DispatchSerialQueue`, so the synchronous `log(event:)` path never races with reads, flushes, or rotation.

## Requirements

- Swift 6.3 toolchain or later
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+
- Linux, with the SQLite development headers installed (`libsqlite3-dev` on Debian/Ubuntu, `sqlite-devel` on Fedora/RHEL). `Destination.SQLFile` needs SQLite 3.45 or later for JSONB support (Ubuntu 24.04+, Debian 13+). `Destination.OS` is unavailable on Linux.

Dependencies: [swift-log](https://github.com/apple/swift-log).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AustinSoftCom/AS_SwiftLogHandler.git", from: "2.1.0"),
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

### Several loggers sharing one file

Because `LoggingSystem.bootstrap` calls its factory once per `Logger`, it's common to create many handlers for the same URL. They all share one underlying writer, and each handler's `label` is recorded as the entry's module name, so entries stay attributable:

```swift
let url = URL.documentsDirectory.appending(path: "MyApp.log")

LoggingSystem.bootstrap { label in
    Destination.File(label: label, url: url)
}

let network = Logger(label: "Network")    // both write to MyApp.log,
let database = Logger(label: "Database")  // through the same writer
```

Each handler holds one reference to the shared writer; `close()` releases that reference, and the file is actually closed once the last reference is released. A given URL must be used by only one destination type — opening the same URL as both a `File` and an `SQLFile` is a programmer error and traps.

### Metadata providers

Pass a swift-log `Logger.MetadataProvider` to have contextual metadata (request IDs, user IDs, trace IDs, …) attached to every entry automatically:

```swift
enum RequestContext {
    @TaskLocal static var requestID: String?
}

let provider = Logger.MetadataProvider {
    guard let requestID = RequestContext.requestID else { return [:] }
    return ["request-id": .string(requestID)]
}

LoggingSystem.bootstrap({ label, metadataProvider in
    Destination.SQLFile(label: label, url: url, metadataProvider: metadataProvider)
}, metadataProvider: provider)
```

Every destination (`OS`, `File`, and `SQLFile`) accepts a `metadataProvider:` in its initializer, and exposes it as the `metadataProvider` property.

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
let isOpen = handler.open()                // take another reference, reopening the file if needed
handler.close()                            // release one reference; the last one closes the file
handler.openCount                          // number of open references to the shared writer

Destination.SQLFile.size(url: url)         // current size on disk (incl. -wal/-shm)
Destination.SQLFile.fileURLs(from: url)    // all files that make up the log
Destination.SQLFile.ensureDeleted(url: url)// delete the log and all rotated copies
```

## Behavior notes

- **Rotation:** with `.rotateAt`, the current file is renamed to `<name>.1`, existing `<name>.n` files shift to `<name>.n+1`, and anything beyond `maxIndex` is deleted. `read()` returns entries from `<name>.1` followed by the current file.
- **Levels on disk** are stored as emoji (🧵 trace, 🐞 debug, ℹ️ info, 📝 notice, ⚠️ warning, ❌ error, 🛑 critical), which keeps them compact and easy to spot when eyeballing a raw log file.
- **Module name:** the `label` passed to a destination's initializer is always recorded as the entry's module name.
- **Metadata merging:** each entry's metadata is the handler's metadata, overridden by the metadata provider's values, overridden by the log statement's explicit metadata. If the log call includes an `error`, `error.message` and `error.type` keys are added.
- **Private metadata:** any top-level metadata key named `"private"` is stripped before an entry is written to any destination.
- **Value semantics:** the handlers are structs, so copies made by `Logger` behave correctly — changing `logLevel`, metadata, or `metadataProvider` on one logger never affects another. All handlers for a URL share the same underlying writer; a copy that is modified takes its own reference to that writer, so it should be balanced by its own `close()`.

## Known Issues

- `Destination.SQLFile` does not yet handle write errors due to a full disk or loss of write access — the failed write is silently dropped (the application is unaffected, but log entries may be lost). `Destination.File` buffers up to ~1 MB of unwritten entries and retries them on the next write, dropping the oldest entries beyond that limit.

## Release Notes

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for what's changed in each version, including the breaking changes in 2.0.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

AS_SwiftLogHandler is released under the MIT License. See [LICENSE.txt](LICENSE.txt) for details.

Copyright © 2026 Glenn L. Austin (AustinSoft.com)
