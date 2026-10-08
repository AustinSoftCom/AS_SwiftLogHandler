# Release Notes

## 2.1.0

### Behavior changes

- **`.useLogRotate` no longer handles `SIGHUP`.** Before each write, the file and SQLite destinations now check whether their file has been renamed or removed, and reopen it at the original path. Remove any `postrotate` script that sends `SIGHUP` (such as `kill -HUP`): the library no longer handles the signal, so unless your app handles or ignores it, `SIGHUP` terminates the process.
- **SQLite databases using `.useLogRotate` no longer use WAL mode.** A WAL file doesn't follow a renamed database, so entries still in it were lost when logrotate renamed the database. These databases now use SQLite's rollback journal, which is slower per write. Other rotation modes still use WAL.

### New features

- **Linux support.** `Destination.File` and `Destination.SQLFile` work on Linux; `Destination.OS` is Apple-only. Building needs the SQLite development headers (`libsqlite3-dev` on Debian/Ubuntu, `sqlite-devel` on Fedora/RHEL), and `Destination.SQLFile` needs SQLite 3.45 or later for JSONB support.
- **logrotate's `copytruncate` works with text log files**, which are now opened for appending. Don't use `copytruncate` with SQLite databases.

### Fixes

- `Destination.SQLFile` percent-encoded its path, so a URL containing spaces or other reserved characters created a database with names like `%20` in it.

## 2.0.0

### Breaking changes

- **`label` is always used as the module name.** In 1.0, `Destination.File` and `Destination.SQLFile` fell back to the `LogEvent`'s `source` when the handler's `label` was empty. In 2.0, the `label` passed to the initializer is always recorded as the entry's module name.
- **`Destination.FileHandling` has new requirements:** `open() -> Bool` and `openCount`. Code that conforms its own types to `FileHandling` must implement them.
- **`close()` is now reference-counted.** Handlers for the same URL share one writer; `close()` releases the calling handler's reference, and the file is only closed when the last reference is released. In 1.0, `close()` closed the file outright and it could not be reopened; in 2.0, `open()` takes a new reference and reopens the file if needed.
- **One destination type per URL.** Creating a `Destination.File` and a `Destination.SQLFile` for the same URL is now a programmer error and traps.

### New features

- **Shared, reference-counted writers.** The file I/O that used to live inside `Destination.File` and `Destination.SQLFile` has been moved into separate writer objects (`FileWriter` and `SQLiteFile`) that are shared by every handler writing to the same file (URLs are compared after standardizing and resolving symlinks). Multiple loggers — for example, every `Logger` created through `LoggingSystem.bootstrap` — can now safely write to a single file.
- **Metadata providers.** `Destination.OS`, `Destination.File`, and `Destination.SQLFile` all accept a `metadataProvider:` initializer parameter and expose a `metadataProvider` property. Provided metadata is merged with the handler's metadata and the log statement's explicit metadata (explicit wins, then provider, then handler).
- **Error metadata.** When a log call includes an `error`, its description and type are recorded as the `error.message` and `error.type` metadata keys.
- **`open()` and `openCount`** on `Destination.FileHandling`, for managing and inspecting a handler's reference to its shared writer.

### Improvements

- `Destination.File` now buffers up to ~1 MB of entries that fail to write (e.g. while the disk is full) and retries them on the next write, instead of dropping them immediately.
- Rotation no longer does anything when the current log file doesn't exist.

## 1.0.0

- Initial release: `Destination.OS`, `Destination.File`, and `Destination.SQLFile` log handlers, built-in log rotation, and reading entries back as `SwiftLogEntry` values.
