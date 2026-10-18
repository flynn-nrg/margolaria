# Spike M0e: signing, notarization and embedding SwiftUsd

**Question** (PLAN.md §8, M0e; open question 7 in §9): Can we ship Margolaria with SwiftUsd embedded, signed with Developer ID under the Hardened Runtime, notarized and stapled, so that Gatekeeper accepts it on another Mac? And are SwiftUsd's frameworks static or dynamic?

**Answer: yes, with two build-setting fixes.** SwiftUsd's frameworks are **dynamic**. Xcode embeds all of them and re-signs them with our Developer ID, and the Hardened Runtime loads them without any entitlement. The first notarization was accepted with no issues. `spctl` reports `accepted, source=Notarized Developer ID`. `scripts/release.sh` does all of it in one command.

Date: 2026-10-18. SwiftUsd 8.1.0, Xcode 27.1, macOS 27.0.1, Apple M2 Max.

## What was built

- **`scripts/release.sh`**, the release pipeline from PLAN.md §7.2:
  1. `xcodebuild archive` (Release);
  2. `-exportArchive` with `method = developer-id`;
  3. `notarytool submit --wait` with a keychain profile;
  4. `stapler staple`;
  5. `codesign --verify --deep --strict` and `spctl --assess`.

  It reads the team ID and version from the build settings, so they are written down in one place only. It keeps Apple's notarization log in `build/release/notary-log.json`. `--no-notarize` stops after signing.
- **`Config/Base.xcconfig`:**
  - `ARCHS = arm64`;
  - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO`.

  Both are explained under the gotchas below.
- **Documentation:** a README section on releases; PLAN.md open question 7 answered; the bundle identifier recorded in §7.1.

## Results

| Check | Result |
|---|---|
| SwiftUsd framework type | Dynamic (`Mach-O 64-bit dynamically linked shared library arm64`), signed by team `28M968D9KQ` |
| Embedded in the app | 107 frameworks in `Contents/Frameworks`, all re-signed with our Developer ID and a secure timestamp. Xcode does this for binary targets in Swift packages; we configure nothing. |
| App size | 216 MB on disk; the distribution zip is 44.5 MB |
| Hardened Runtime | On (`flags=0x10000(runtime)`). Release entitlements are empty. |
| Margolaria (Release) under the Hardened Runtime | Opens `brushed_copper.mtlx`. MaterialX loads its 56 library files and 807 nodedefs from inside the bundle. |
| ViewportSpike (Release) under the Hardened Runtime | USD loads its plugins and Storm renders the material. Library validation accepts the re-signed frameworks. |
| `codesign --verify --deep --strict` | Valid |
| Notarization | Accepted, no issues; 216 entries in the ticket: each framework twice (the bundle and its binary), plus the app and its executable. |
| `stapler validate` | OK |
| `spctl --assess --type execute` | `accepted, source=Notarized Developer ID` |
| Second Mac or clean user account | Opens without a Gatekeeper warning (checked by hand, 2026-10-18) |

`release.sh --no-notarize` took 3.7 minutes, almost all of it the archive (a separate Release build). Notarization adds the upload and Apple's processing, typically a few minutes.

## Gotchas found (worth remembering)

1. **Release builds failed to link: SwiftUsd has no Intel code.** Debug builds only the current architecture. Release builds every architecture, and the x86_64 link found none of the frameworks ("found architecture 'arm64', required architecture 'x86_64'"). `ARCHS = arm64` makes the app Apple-silicon-only. The spikes had built in Release before only because GraphSpike doesn't use USD.
2. **Xcode adds `get-task-allow` to Release builds too.** This entitlement lets a debugger attach, and notarization rejects it. Xcode injects it into every build it signs; only an archive export removes it. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for Release keeps a plain Release build notarizable as well. (The comment in `Margolaria.entitlements` claimed Release never gets it; it has been corrected.)
3. **No `disable-library-validation` needed.** Library validation only requires every loaded library to be signed by our team or by Apple. Re-signing at embed time satisfies it, including for USD plugins loaded with `dlopen` (Storm, UsdMtlx). The exception stays reserved for third-party Hydra delegates and Python packages (PLAN.md §7.1).
4. **Zip with `ditto -c -k --keepParent`, not `zip`.** Frameworks contain symlinks (`Versions/Current`), and `zip` without `-y` would turn them into copies and break the signatures.
5. **`notarytool` returns before you know why it failed.** On rejection, `notarytool log <id>` has the reasons. The script downloads the log on every run, accepted or not.
6. **`codesign -dv` doesn't show the certificate chain;** `-dvv` does.

## The second-machine test

The M0 exit criterion, done by hand and passed. To repeat it: copy `build/release/Margolaria-0.1.0.zip` to another Mac, or to a fresh user account on this one. Download it through a browser or AirDrop, so it gets the quarantine attribute. Then unzip it, double-click the app, and check that it opens without a Gatekeeper warning. To check from Terminal there: `spctl --assess --type execute -vv Margolaria.app`.

## Not done / open

- **Trimming the frameworks.** The app embeds every SwiftUsd framework, including some we will probably never use, such as Alembic, OpenVDB and Embree. Leaving them out needs care, because USD loads plugins by name from `plugInfo.json`. Worth a look before the first public release: it would make the download smaller and shrink what we sign and ship.
- **A `.dmg`** instead of a zip, with the usual Applications shortcut. That can come later, with the first public release.
- **Pre-existing Swift 6 warning** in the archive build: `MaterialXFileDocument` is `Sendable` but stores a non-`Sendable` `MXDocument`. It is unrelated to signing and belongs to M1, where the document model is reworked.
- **Archive noise.** `xcodebuild archive` printed one line, "error: the following command failed with exit code 0 but produced no further output", yet the archive succeeded and so did everything after it. Not investigated.
