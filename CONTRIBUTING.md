# Contributing to AS_SwiftLogHandler

Thanks for your interest in contributing! AS_SwiftLogHandler is a small, focused package, and contributions of all kinds are welcome — bug reports, documentation improvements, tests, and code.

## Reporting issues

Please open an issue at
[https://github.com/AustinSoftCom/AS_SwiftLogHandler/issues](https://github.com/AustinSoftCom/AS_SwiftLogHandler/issues) and include:

- What you expected to happen and what actually happened.
- A minimal code sample that reproduces the problem, if possible.
- The Swift toolchain version and platform (macOS/iOS/tvOS/watchOS/visionOS and OS version).

For questions about usage rather than bugs, an issue is fine too — questions often reveal gaps in the documentation.

## Submitting changes

1. Fork the repository and create a branch from `develop` (this project follows a git-flow-style layout: `develop` for ongoing work, `main` for releases).
2. Make your changes.
3. Add tests demonstrating your fixes.
4. Run the tests (`swift test`) and make sure they all pass.
5. Open a pull request against `develop` with a clear description of what the change does and why.

Please keep pull requests focused — one bug fix or feature per PR is much easier to review than a batch of unrelated changes.

## Code guidelines

- **Swift 6 strict concurrency:** the package builds in Swift 6 language mode with no concurrency warnings. Changes must preserve that — the handlers are `Sendable` structs, and all file I/O goes through actors whose executor is a `DispatchSerialQueue` so the synchronous `log(event:)` path stays race-free.
- **No new dependencies** without prior discussion in an issue. The only runtime dependency is [swift-log](https://github.com/apple/swift-log); tests may additionally use [swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump).
- **Public API must be documented** with SwiftDoc (`///`) comments, including parameters and return values. Follow the style of the existing sources.
- **Formatting:** match the existing code — tabs for indentation in Swift sources, PascalCase types, camelCase members.
- **Behavior guarantees matter:** the README documents specific semantics (on-disk log formats, rotation behavior, `read()` covering the most recent rotated file, `"private"` metadata never being persisted, value semantics of the handlers). Changing the on-disk format in particular breaks reading logs written by earlier versions, so any change to these needs a very good reason, discussion in an issue first, and updated documentation.

## Tests

- Tests use the [Swift Testing](https://developer.apple.com/documentation/testing/) framework (`@Suite`, `@Test`, `#expect`), not XCTest, so the suite runs with `swift test` — no Xcode required.
- Because the tests bootstrap the global `LoggingSystem`, the suite runs serialized (`@Suite(.serialized)`); new tests that create loggers should fit that pattern and use unique temporary file URLs.
- Tests that cover both file destinations should be parameterized over the handler factories (see `LoggingTests.swift`) so `Destination.File` and `Destination.SQLFile` stay behaviorally in sync.
- New features and bug fixes should come with tests. For bug fixes, a test that fails before the fix and passes after it is ideal.

## License

By contributing, you agree that your contributions will be licensed under the same [MIT License](LICENSE.txt) that covers the project.
