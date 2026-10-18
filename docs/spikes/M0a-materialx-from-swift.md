# Spike M0a: MaterialX from Swift

**Question** (PLAN.md §9, open question 1): Can Swift use the MaterialX C++ API through apple/SwiftUsd, or do we have to build MaterialX ourselves?

**Answer: yes, through a small C++ bridge. No separate MaterialX build is needed.**

> Since 2026-10-18, MXKit lives in `Packages/MargolariaKit` together with ViewportKit, and depends on a local, patched copy of SwiftUsd (`scripts/fetch-swiftusd.sh`). See "Build times" in the README.

Date: 2026-10-17. SwiftUsd 8.1.0 (OpenUSD v26.08), Xcode 27.1, Swift 6.4, macOS 27.0.1 on arm64.

## Findings

| What | Result |
|---|---|
| MaterialX version in SwiftUsd 8.1.0 | **1.39.5**, as dynamic frameworks (`MaterialXCore.framework` etc., `current version 1.39.5`) |
| MaterialX libraries included | Core, Format, GenShader, GenGlsl, GenHw, **GenMsl**, Render, RenderHw, RenderGlsl. **Not** included: GenOsl, GenMdl, GenSlang, RenderMsl, RenderOsl (their headers ship, but not their binaries). |
| Platforms for MaterialX | macOS arm64 only (the USD frameworks also cover iOS and visionOS) |
| Headers | All MaterialX headers ship in SwiftUsd's public include directory, `swift-package/Sources/_OpenUSD_SwiftBindingHelpers/include/MaterialX*`. Any C++ target that depends on the `OpenUSD` product can `#include <MaterialXCore/Document.h>`. |
| Swift import of MaterialX | **Not available directly.** SwiftUsd's `module.modulemap` lists only `pxr` headers, so `import OpenUSD` doesn't expose MaterialX to Swift. |
| Data libraries (stdlib, pbrlib, bxdf, …) | Ship inside `Usd_UsdMtlx.framework/Resources/MaterialX_Libraries/libraries`: 56 files, 807 nodedefs. Found at runtime with `Bundle(identifier: "com.pixar.Usd-UsdMtlx")`. |
| Framework type | **Dynamic.** This answers open question 7: all 108 frameworks must be embedded in the app and re-signed with our identity. |
| Linking | Depending on the `OpenUSD` product links **all 108** SwiftUsd frameworks, and they all load at launch. Fine for now; the launch-time cost should be measured later. |

## Design that came out of it

```
App (Swift) ──imports──▶ MXKit (Swift) ──imports──▶ MXBridge (C++) ──#include──▶ MaterialX (C++, from SwiftUsd)
```

- **MXBridge** (`Packages/MargolariaKit/Sources/MXBridge`) is the only code that includes MaterialX headers. Its header follows three rules:
  - It includes **no MaterialX headers**: the MaterialX objects hide behind a pimpl.
  - **No C++ exception crosses into Swift**: they're caught and turned into an error string.
  - Its signatures use **only simple types**: `std::string`, `std::vector`, plain structs.
- **MXKit** (`Packages/MargolariaKit/Sources/MXKit`) wraps the bridge in Swift types: `MXDocument`, `MXLibrary`, `MXError`, `MXValidationResult`. The app never sees a C++ type.
- The tests in `Packages/MargolariaKit/Tests/MXKitTests` cover:
  - loading the libraries;
  - parsing, and listing the elements in file order;
  - a **stable round trip** (writing the same document twice gives identical text);
  - validation passing and failing;
  - malformed XML producing a Swift error instead of a crash;
  - a v1.38 file being upgraded on load.

Run them with `swift test` in `Packages/MargolariaKit`.

## Gotchas found (worth remembering)

1. **Swift can't catch C++ exceptions.** One that escapes into Swift terminates the process. Every bridge function that calls MaterialX must catch `std::exception`. There's a test for this ("Malformed XML throws parseFailed instead of crashing").
2. **Non-`const` C++ methods become `mutating` in Swift.** Swift imports C++ classes as value types, so calling a non-const method on a `let` constant is a compile error. A C++ handle stored in a Swift class must be a `var` if any of its non-const methods are called.
3. **`String(std.string)` doesn't type-check** when the SwiftUsd module graph is part of the build. The overlay defines it, but Swift 6.4 reports "no exact matches in call to initializer". `std.string.description` works, so MXKit uses a one-line `swiftString` helper (`CxxString.swift`). Revisit with future Swift versions.
4. **Find framework bundles by identifier, not folder name.** dyld loads frameworks through their real `Versions/A` path, so the bundle's URL doesn't end in `X.framework`.
5. **Tests run in parallel.** Concurrent `Bundle(identifier:)` lookups raced, and one returned nil. Loading the libraries once, through a `static let`, fixed it. That's the right design anyway.
6. **Xcode requires approving package macros.** SwiftUsd contains a Swift macro. In Xcode, approve it once with "Trust & Enable". On the command line, pass `-skipMacroValidation` to `xcodebuild`.
7. **Build times.** The first build of anything that depends on SwiftUsd takes about 5 minutes, mostly building Clang modules for OpenUSD. After that, the MXKit tests rebuild and run in about 30 seconds. Xcode keeps its own build folder (DerivedData), so its first build pays that cost again.
