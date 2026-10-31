# M3: Previews & colour

**Goal** (PLAN.md §8): per-node thumbnails, solo preview, OCIO colour pickers and view transform. **Exit criterion:** swatches update in under 100 ms after an edit on a typical graph.

**Result: met.** On the marble example (a nodegraph of 12 nodes feeding a standard_surface), a value edit redraws the 7 swatches downstream of it in about 17 ms, and a shader value edit its 2 swatches in about 19 ms (`SwatchCacheTests`). Only graph edits are slower: a new connection recompiles the shaders downstream, about 200 ms for one swatch the first time, and 4 ms once macOS's shader cache has it.

Each PR's own exit criterion is checked by a test:

| PR | Exit criterion | Test |
|---|---|---|
| M3a | Conversions match the colour spaces' published definitions, and every MaterialX space is known; the Developer ID build embeds and signs OCIO | `ColorKitTests`; signing and notarization are checked by hand on the release build |
| M3b | The suspect examples (SimpleHair, gold, Disney) are explained or fixed | Explained by a comparison with MaterialXView under the same light (PLAN.md §8.2); `DisplayPassTests` check every display and view on the GPU against OCIO's CPU processor (within 2e-4) |
| M3c | Swatches update in under 100 ms after an edit on a typical graph (M3's criterion) | `SwatchCacheTests`; `SwatchCorpusTests` (281 of 293 swatches in the examples); `SwatchAgreementTests` (swatches against Storm) |
| M3d | Any node's output in the examples can be soloed | `SoloPreviewTests`: every node with a swatch in every example is soloed and rendered by Storm |
| M3e | Picks give the values OCIO's conversions give, in every space the picker offers | `ColorPickingTests`: every pick space with every kind of input space, both ways, and the published sRGB curve, ACEScg and Display P3 primaries |
| Input spaces | Converting keeps the colour; every standard space OCIO knows is offered | `ColorKitTests`, `MXEditTests` |
| Working space | Changing it can keep every colour's look; Storm shows an ACEScg document as it should | `MXEditTests`, `SoloPreviewTests` ("working space") |

Dates: 2026-10-28 to 2026-10-31. Seven PRs: #23 (M3a), #24 (M3b), #25 (M3c), #26 (M3d), #27 (M3e), #28 (colour spaces of inputs), #29 (working space). The app and MargolariaKit grew from about 16,100 to 22,600 lines of Swift, C++ and Objective-C++, and from 121 to 170 test functions.

## What was built

| PR | Scope | Main pieces |
|---|---|---|
| **M3a** (#23) | OpenColorIO | `scripts/build-ocio.sh` (OCIO 2.5.2 as one dynamic framework, dependencies linked in statically) · `ColorBridge` (the only code including OCIO's headers) and `ColorKit` (`ColorConfiguration`, `ColorSpace`, `ColorConverter`) · OCIO's built-in studio config · lossless processors · the inspector's colour wells converted by OCIO |
| **M3b** (#24) | Viewport lighting and view transform | `StudioEnvironment` (a neutral studio drawn by code, written as a .hdr) · `DisplayPass` (our Metal pass applying OCIO's display/view transform as generated MSL) · display and view menus · the comparison with MaterialXView |
| **M3c** (#25) | Per-node swatches | `SwatchService` (an actor: parses the preview text, generates and compiles shaders in parallel, draws) · `SwatchCache` per document · `SwatchPlan` (which nodes, and fingerprints of everything upstream) · swatches lit and transformed as the viewport · only nodes near the view · overlap separation and the Arrange button |
| **M3d** (#26) | Solo preview | `MXDocument.soloPreview` (a wrapper material around any node, in the preview text only) · ⌥-click, S, or the inspector's button · data swatches through the display's Raw view · Storm's rewire fix (`ConnectionSignature`) |
| **M3e** (#27) | Colour picker | `ColorPickerPopover` (colour field and hue strip, RGB/HSV sliders with coloured tracks, hex, eyedropper, before and now) · `PickSpace` and `ColorPicking` · the out-of-gamut warning and Clip |
| **Input spaces** (#28) | Colour spaces of inputs | `ColorSpaceMenu` beside every colour value and image file: convert, reinterpret, or back to the default · `InputColorSpace` · `setColorSpace(_:ofInput:on:)` |
| **Working space** (#29) | The document's and nodegraphs' space | `WorkingSpaceMenu` in the inspector (the document's when nothing is selected) with Convert Colours or Keep Numbers · `MXWorkingSpace.swift` · the template sheet's working space · the document's space moved down for Storm |

The canvas now shows a swatch on every node that has something to draw, and the viewport and swatches share one light and one view transform, so what a node shows and what the material shows agree.

## Decisions

The full list, with reasons, is in PLAN.md §8.3. The ones that shaped the code most:

1. **OCIO built from source, with its built-in studio config** (M3a). No prebuilt macOS framework exists; static dependencies keep its private Imath from clashing with SwiftUsd's. MaterialX's colour space names are aliases in the ACES studio config, so `colorspace` attributes go to OCIO unchanged. Conversions are lossless, because converted values are written into documents.
2. **The view transform is our own Metal pass** (M3b). SwiftUsd builds OpenUSD without OCIO, so Hydra's OCIO mode isn't there; OCIO generates the MSL instead. Storm keeps encoding sRGB, which the pass decodes exactly (§8.2: Storm drew nothing with colour correction off).
3. **A neutral studio drawn by code** (M3b), not a shipped HDR: no licence or binary in the repository, and the same file lights MaterialXView for comparisons.
4. **Swatches are drawn from the document's text, off the main thread** (M3c). An MXDocument isn't thread-safe; a String can go anywhere. One actor for the app compiles shaders in parallel and caches pipelines by their source, so value edits never recompile.
5. **Fingerprints, not edit tracking, decide what to redraw** (M3c). Each node's hash covers everything upstream of it, so any change (an edit, undo, revert) redraws exactly the nodes it affects, and moving a node redraws nothing.
6. **Swatches are right rather than matched to Storm** (M3c). Storm's diffuse environment light is about 0.57 of the true value under the studio light (§8.2); the swatches use a real cosine convolution, so diffuse swatches are brighter than the viewport's sphere until Storm is fixed.
7. **Solo is a wrapper material in the preview text** (M3d), not a second renderer: the viewport's light, camera and view transform apply, and the document isn't changed. Its shape works around three UsdMtlx and Storm problems (§8.2).
8. **Data is shown raw** (M3d). Roughness, masks and normals go through the display's Raw view; tone mapping is for light.
9. **Our own colour picker** (M3e). The macOS panel picks only in its own spaces, can't go above 1, and stored out-of-gamut colours silently. Out-of-gamut values are kept, with a warning and a Clip button.
10. **Changing a colour space can keep the colour or the numbers** (input spaces, working space). Converting is the default; reinterpreting is offered for values in the wrong space. Images can't be converted, so keeping their look means tagging them with the old space.

## Problems found and fixed (worth remembering)

| Where | Problem | Fix |
|---|---|---|
| M3a | OCIO's default processors approximate pow, log and exp: white came back as 1.000024 | Lossless processors |
| M3b | Storm's colour buffer held only the clear colour with colour correction disabled | Storm keeps sRGB output; DisplayPass decodes it (§8.2, cause not found) |
| M3b | The studio looked mirrored | Storm reads .hdr files bottom row first (found with a mirror sphere) |
| M3c | Swatches lit from the wrong side | MaterialX's lat-long convention differs from Storm's; `u_envMatrix` negates all three axes |
| M3c | Multi-output nodes had no outputs in tests | Tests set the data library, as the app does |
| M3c | 12 of 293 swatches in the examples fail to compile | MaterialX 1.39.5 generator bugs (§8.2); shown as "No preview" with the reason in the inspector |
| M3d | Rewiring inside a nodegraph left the viewport showing the old network | MGStormRenderer compares connections after each update and re-adds the MaterialX reference when one changed |
| M3d | `surface_unlit` fell back to grey in Storm | Values are soloed as the emission of a black `standard_surface` |
| M3d | A top-level `convert` reading a nodegraph came out black; shaders inside a nodegraph lost their connections | Conversions go inside the nodegraph, shaders stay at the top level |
| M3e | The first picker had only a black-to-white slider to pick from | A colour field with a hue strip, and slider tracks that show the colour |
| M3e | `NSColorSampler`'s handler raised `@Sendable` warnings | `MainActor.assumeIsolated` |
| Working space | Storm ignored `colorspace` on `<materialx>`: an ACEScg red showed as (192, 108, 95) instead of (231, 89, 89) | The preview text moves the document's space down onto top-level elements |

## Not done / open

- **Reports upstream.** To OpenUSD: Storm without colour correction, the dark diffuse environment light, the missed rewires, `surface_unlit`, UsdMtlx and nodes around a nodegraph, and the ignored document `colorspace`. To MaterialX: the two MSL generator bugs. Each has a workaround here; minimal reproductions are still to be written.
- **Another OCIO config** (a studio's own, `$OCIO`) and **HDR displays** (EDR) come later.
- **Gamut mapping**: out-of-gamut colours can only be clipped.
- **Inputs at their nodedef default** aren't converted when the working space changes. Greys are the same in every space; a coloured default shifts slightly.
- **g18_ap1** isn't offered: OCIO's built-in ACES config doesn't have it.
- **Keyboard shortcuts** for the many actions, once the features are done (PLAN.md §8.4).
- **Not in M3, as planned:** nodegraph creation, promote to interface, custom nodedefs, backdrops, two-way XML editing and the command palette (M4).
