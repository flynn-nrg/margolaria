# Spike M0b: Storm viewport on Metal

**Question** (PLAN.md §8, M0b): Can we render a USD stage with a MaterialX material in Hydra Storm on Metal, inside an `NSView`, using SwiftUsd?

> Since 2026-10-18, ViewportKit lives in `Packages/MargolariaKit` together with MXKit. Build-time gotcha 6 below led to that change; see "Build times" in the README.

**Answer: yes.** `UsdImagingGLEngine` from SwiftUsd renders with Storm on HgiMetal and hands back the frame as an `id<MTLTexture>`, which an `MTKView` copies to the screen. Storm compiles the MaterialX graph itself. A `.mtlx` file is brought in with a plain USD reference through the UsdMtlx plugin. No OpenGL is involved.

Date: 2026-10-17. SwiftUsd 8.1.0 (OpenUSD v26.08, MaterialX 1.39.5), Xcode 27.1, Swift 6.4, macOS 27.0.1 on arm64.

## What was built

```
ViewportSpike.app ──▶ ViewportKit (Swift) ──▶ ViewportBridge (Objective-C++) ──▶ UsdImagingGLEngine ─▶ Storm ─▶ HgiMetal
                       ViewportView                MGStormRenderer
                       StormMTKView (MTKView)
```

- **ViewportKit** (originally its own package, `Packages/ViewportKit`), with the same split as MXKit:
  - **ViewportBridge** (`MGStormRenderer.h/.mm`) is the only code that includes OpenUSD headers. Its header is plain Objective-C, using only Foundation and Metal types. That way Swift gets an ordinary class, `init(materialXFile:) throws`, and a `render(withWidth:height:) -> MTLTexture?`.
  - **ViewportKit** (Swift) has two parts:
    - `ViewportView` (SwiftUI) wraps `StormMTKView`, an `MTKView` subclass that draws on demand, orbits the camera on drag and zooms on scroll.
    - `MGStormRenderer.snapshot(width:height:)` renders offscreen to a `CGImage`.
  - **Tests** render the fixtures and save PNGs (`VIEWPORT_SNAPSHOT_DIR=… swift test`). They check:
    - the material binding;
    - a copper sphere on a grey background;
    - that a pure green `open_pbr_surface` renders green, which proves Storm uses the MaterialX graph rather than a fallback shader;
    - that a file with no material throws instead of crashing.
- **`Spikes/M0bViewport`** contains the `ViewportSpike` demo app target: one window, the copper sphere and an Open… button. It is signed like the main app (Config/ViewportSpike.xcconfig includes Base.xcconfig).

**Checked in the running app:**
- ViewportSpike.app is signed with the Apple Development identity and launches.
- It renders the copper sphere upright, at Retina resolution, with correct aspect in a wide window.
- Colours match the offscreen snapshot, so the sRGB curve isn't applied twice.
- Interaction (drag to orbit, scroll to zoom, resizing) has to be checked by hand.

### The stage

The stage is built in memory for each file:

```
/World
  /MaterialX     references @file.mtlx@</MaterialX>     (UsdMtlx: materials under /MaterialX/Materials)
  /Sphere        UsdGeomMesh, 96×48 segments, bound to the first material found
  /Lights/Key    UsdLuxDistantLight
  /Lights/Dome   UsdLuxDomeLight with OpenUSD's default HDR (HdxPackageDefaultDomeLightTexture)
```

This is the stage PLAN.md §5 describes: Hydra renders a generated USD stage that references the .mtlx.

## Findings

| What | Result |
|---|---|
| Storm on Metal from SwiftUsd | Works. `Hgi::CreatePlatformDefaultHgi()` gives HgiMetal. The renderer plugin is `HdStormRendererPlugin`, display name "Storm". |
| MaterialX in Storm | Works: `open_pbr_surface`, a `nodegraph` and `noise3d` all render. Storm generates MSL from the graph; we write no shader code. |
| `.mtlx` into USD | `AddReference(path, "/MaterialX")` works; the UsdMtlx plugin ships in SwiftUsd. Materials appear at `<ref>/Materials/<name>`. |
| Getting the frame | `engine.GetAovTexture(HdAovTokens->color)` → `HgiMetalTexture::GetTextureId()` returns an RGBA16Float `id<MTLTexture>`. |
| Showing it | Use an `MTKView` with the following settings, then blit the texture into the drawable using Storm's own command queue, so the blit runs after Storm's work:<br>• `colorPixelFormat = .rgba16Float`, so the pixel format matches and a blit works without a shader;<br>• `colorspace = sRGB`;<br>• `framebufferOnly = false`. |
| Orientation | Storm's texture is upright in Metal. Core Image needs `.downMirrored` for snapshots. |
| Colour | `colorCorrectionMode = sRGB` gives display-ready pixels. M3 replaces this with OCIO. |
| Swift-facing API | Objective-C++ was the right choice: `id<MTLTexture>` only exists in HgiMetal's Objective-C++ API, and an ObjC class hides every C++ type from Swift. |

## Gotchas found (worth remembering)

1. **Turn off presentation.** By default `UsdImagingGLEngine` ends each frame by presenting into an OpenGL framebuffer through `HgiInteropMetal`. With no GL context, it segfaults inside `glGetString`. Call `SetEnablePresentation(false)` when you read the AOV texture yourself.
2. **Hydra's plugin registry isn't thread-safe on first use.** Two engines created at the same time (Swift Testing runs tests in parallel) crashed inside `HfPluginRegistry::_DiscoverPlugins`. Engine creation now holds a mutex, and the test suite is `.serialized`. It's the same family of bug as M0a gotcha 5.
3. **Implicit `UsdGeomSphere` is tessellated with about 10 sides** and looks like a polygon. Generate a mesh with `GeomUtilSphereMeshGenerator` instead.
4. **Metals are black without an environment.** A dome light with no texture only warns ("Dome light has no texture asset path"). `HdxPackageDefaultDomeLightTexture()` points at the `StinsonBeach.hdr` that ships with Hdx.
5. **The dome is drawn as the background by default.** `SetRendererSetting(HdRenderSettingsTokens->domeLightCameraVisibility, false)` keeps the clear colour.
6. **Build times.** ViewportKit has its own `.build` folder, so its first `swift build` compiles the OpenUSD Clang modules again: **29 minutes** on this machine (M0a measured about 5). Incremental rebuilds of the bridge plus the tests take about 40 seconds. Consider a single package for all our SwiftUsd-dependent targets, so the module cache is built only once.

## Not done / open

> Since M1c: the viewport is in the main window, with a material picker. UsdMtlx also creates USD materials for a look's `materialassign`s ("preview", "calibration" in the look examples), so the app lists the MaterialX document's own materials rather than the renderer's.

- ~~**Anti-aliasing.**~~ Done in M1c, by supersampling: Storm renders at 2× and `ViewportKit/Downsampler.swift` scales the frame down, only while the camera is still. UsdImagingGLEngine has no MSAA option, and `HDX_MSAA_SAMPLE_COUNT` had no effect on its colour output. At 1040 × 1500 a frame takes 6.7 ms at 1× and 21.8 ms at 2×.
- **The key light seems weak** next to the HDR dome. Light balancing belongs to M3 (and needs a neutral studio HDR instead of Stinson Beach).
- ~~**No UVs on the sphere.**~~ Done in M1c: a face-varying `st` primvar, with the seam and poles handled. The generator also put the sphere's poles on Z (our stage is Y-up); M1c turns them to Y. All 84 materials in MaterialX's examples now render, textures included (`StormCorpusTests`).
- **Main thread.** Rendering runs in `MTKView.draw`. That's fine for one sphere, but PLAN.md §5 wants heavy work off the main thread; revisit with M1's real scenes.
- **Picking and selection outlines**: not attempted. `UsdImagingGLEngine::TestIntersection` exists; compare with wabiverse's HydraKit (PLAN.md §3) before building our own.
