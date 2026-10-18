# margolaria

A MaterialX authoring tool
See [docs/PLAN.md](docs/PLAN.md) for the project plan and [the interface mockup](docs/mockup/margolaria-mockup.png).

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
scripts/fetch-swiftusd.sh     # once: clones apple/SwiftUsd into Vendor/ (about 1.4 GB) and patches it
xcodegen                      # generates Margolaria.xcodeproj from project.yml
open Margolaria.xcodeproj
```

To sign with your own certificate, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and fill it in.

From the command line:

```sh
xcodebuild -scheme Margolaria -skipMacroValidation -derivedDataPath build/DerivedData build
xcodebuild -scheme Margolaria -skipMacroValidation -derivedDataPath build/DerivedData test
```

### Build times

All our code that uses OpenUSD and MaterialX is in one Swift package, `Packages/MargolariaKit`. Each package and each build folder compiles its dependencies separately, so:

- **Add new modules as targets in MargolariaKit**, not as new packages.
- **Prefer `xcodebuild test -scheme Margolaria`** with the same `-derivedDataPath` as your app builds: the tests then reuse the app's build. `swift test` in `Packages/MargolariaKit` works too, but keeps its own build in `Packages/MargolariaKit/.build`.
- SwiftUsd comes from `Vendor/SwiftUsd`, patched (`Vendor/swiftusd-openusdcxx-product.patch`) to add a product without SwiftUsd's Swift overlay. We don't use the overlay, and compiling it took about 12 of the 13 minutes of a clean build. To upgrade SwiftUsd, change `SWIFTUSD_TAG` in `scripts/fetch-swiftusd.sh` and run it again.
- **Your editor's indexer builds too.** SourceKit-LSP, the language server behind Swift support in editors other than Xcode, keeps its own full build in `Packages/MargolariaKit/.build/index-build`. While it runs, a clean build can take several times longer (6 minutes instead of 1.5 here).

Measured on 2026-10-18:

| Clean build | Before | Now |
|---|---|---|
| `swift build` + tests, in `Packages/MargolariaKit` | 13 min per package (MXKit, ViewportKit) | 73 s (with the indexer running alongside) |
| `xcodebuild build-for-testing -scheme Margolaria` (app + test bundles) | — | 96 s (indexer idle) |
