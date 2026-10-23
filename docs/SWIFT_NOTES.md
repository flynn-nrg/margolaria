# Swift notes

A running glossary of the Swift concepts used in Margolaria, written for someone who knows C, C++, Go and Objective-C. Each entry says where the concept first appears, and the code there has a `// SWIFT:` comment explaining it in context. (`grep -rn "SWIFT:" App Packages` lists all of them.)

Entries are added as new concepts appear (docs/PLAN.md §6).

## Types and values

| Concept | In one line | Closest thing you know | First appears |
|---|---|---|---|
| `struct` vs `class` | Structs are copied on assignment (value types); classes are shared by reference and counted by ARC | C++ value objects vs `std::shared_ptr`; ObjC objects | `MXLibrary.swift` (class), `MXDocument.swift` (`MXElementSummary` struct) |
| `final class` | Can't be subclassed; methods are called directly | C++ `final` | `MXLibrary.swift` |
| `let` / `var` | Constant / variable. Prefer `let`. | `const` locals | `Package.swift` |
| `enum` with associated values | Each case can carry its own data; `switch` must cover every case | `std::variant` with names | `MXError.swift` |
| Enum with no cases | A namespace for static helpers | C++ `namespace` | `MXDocumentTests.swift` (`Fixtures`) |
| Optionals `T?` | A value or `nil`. Non-optional types can never be nil | Nullable pointer vs reference; Go's `v, ok` | `MXLibrary.swift` |
| `if let` / `guard let` | Unwrap an optional; `guard` exits early if it's nil | `if (p) {...}` / `if (!p) return` | `MXLibrary.swift` |
| `!`, `try!` | Force-unwrap / force-try: crash if nil or if it throws. Only use when failure is impossible. | `assert` + dereference | `MaterialXDocument.swift`, tests |
| `??` | Use a default if the left side is nil | `p ? *p : d` | `MaterialXDocument.swift` |
| Tuples | Anonymous fixed group of values; elements can have labels | `std::tuple` | `SwatchGeometry.swift`, `MXCorpusTests.swift` |
| `typealias` | A second name for a type | `typedef` / `using` | (was in `MaterialXFileDocument.swift`, removed in M1a) |
| Computed properties | A property whose getter runs code, with no storage | ObjC `@property` with a custom getter | `MXError.swift` |
| `static` / `static let` | Type members; `static let` is initialised lazily, exactly once, thread-safely | C++ static member; function-local static; `dispatch_once` | `MXLibrary.swift` (`bundled`) |
| `Self` | "This type", inside its own declaration | — | `MXGraph.swift` (`Self.resolveFile`) |
| `Result<T, E>` | Stores either a success value or an error | `std::expected` | `MXLibrary.swift` |
| Number types | `Int`, `Int32`, `Double`… never convert implicitly; use `Int(x)` | Stricter than C | `MXLibrary.swift` |
| `===` / `!==` | Same instance? (identity, for classes) | Pointer comparison | `ViewportView.swift` |
| Property observers `didSet` | Code that runs after every assignment to a property | A custom ObjC setter | `ViewportView.swift` (`StormMTKView.renderer`) |
| `repeat { } while` | Loop that runs at least once | `do { } while` | `Snapshot.swift` |
| `as?` conditional cast | A cast that gives nil when the object isn't of that type | `dynamic_cast`, `isKindOfClass:` | `SwatchRenderer.swift` |
| `UnsafeMutableRawPointer` | A `void *`; `storeBytes(of:toByteOffset:as:)` writes through it without bounds checks | `memcpy` into a `void *` | `SwatchRenderer.swift` |
| `ContinuousClock`, `Duration` | Measure elapsed time: `clock.measure { }` | `std::chrono::steady_clock` | `SwatchRendererTests.swift` |
| Iterating `indices` | `for i in array.indices` to change elements in place; `for x in array` gives copies | Index loop vs range-for by value | `SwatchSpikeApp.swift` |
| Raw strings `#"..."#` | Backslashes and quotes are literal; `"""` makes them multi-line | C++ `R"(...)"` | `StormRendererTests.swift` |
| `defer { }` | Runs when the enclosing scope exits, however it exits | Go `defer`; a C++ RAII guard | `LayerGraphView.swift` (`update`) |
| `CaseIterable` | The compiler generates `allCases`, an array of every case of an enum | An X-macro list | `GraphModel.swift` |
| Wrapping arithmetic `&+`, `&*` | Plain `+` traps on overflow; `&+` wraps around like unsigned C arithmetic | C unsigned `+` | `GraphModel.swift` (`SeededRandom`) |
| `Set` algebra | `union`, `symmetricDifference`, `contains`; sets are values like arrays | `std::set` + `<algorithm>` | `GraphCanvasController.swift`, `LayerGraphView.swift` |
| Enum as a state machine | Each case carries the data that state needs (`.movingNodes(start:original:)`) | A tagged union with a `switch` | `GraphCanvasController.swift` (`DragState`) |
| Multi-pattern `case` | `case .a(let x), .b(let x):` binds the same name in each pattern | Fall-through `case` labels | `GraphCanvasController.swift` (`mouseDown`) |
| Option sets | Bit flags as a set: `flags.contains(.shift)` | `if (flags & NSEventModifierFlagShift)` | `GraphEventView.swift` |
| Failable initializer `init?` | An initializer that can return `nil`; the result is optional | ObjC `-init` returning nil | `MXGraph.swift` (`MXConnection`) |
| Assigning `self` in an enum's `init` | `self = .node(name, output: nil)` picks the case | — | `MXGraph.swift` (`MXConnection`) |
| `if let x` shorthand | Unwraps `x` into a constant of the same name | — | `MXGraph.swift` |
| Nested types | `MXIssue.Severity`: a type declared inside another, for naming only | C++ nested class | `MXIssue.swift` |
| `for … where` | Loops only over elements for which the condition holds | `continue` at the top of the loop | `MXIssue.swift` |
| `try?` | Turns a thrown error into `nil` | Ignoring an error return | `MXIssue.swift` |
| String indices | Strings are sliced with `String.Index` values (`path[..<slash]`), not integers, because characters vary in size | — | `GraphPanel.swift` (`parent(of:)`) |
| `map`/`flatMap` on an optional | Transform the value inside an optional, or get nil | — | `GraphBuilder.swift` |

## Functions and closures

| Concept | In one line | Closest thing you know | First appears |
|---|---|---|---|
| Argument labels | Part of the function name; `_` removes one at the call site | ObjC message syntax | `MXDocument.swift` (`setDataLibrary(_:)`) |
| `throws` / `try` / `do`-`catch` | Errors are thrown and must be acknowledged with `try` at every call site | Go's `err` returns, but enforced by the compiler | `MXLibrary.swift` |
| Closures | Anonymous functions; `$0` is the first argument | ObjC blocks, C++ lambdas | `MXDocument.swift` (`.map { String($0) }`) |
| Trailing closures | A closure can follow the call's parentheses; extra ones get labels | — | `ContentView.swift` (`Label { } icon: { }`) |
| Key paths `\.name` | A reference to a property, usable as a function | Pointer to member | `MXDocumentTests.swift` |
| `inout` / `&` | The callee may modify the argument | Non-const reference parameter | `MXLibrary.swift` |
| Capture lists `[weak self]` | Capture `self` weakly in a closure, so the closure doesn't keep it alive | `__weak` before an ObjC block | `ViewportView.swift` |
| `fatalError("...")` | Stop the program with a message; never returns | `abort()` | `ViewportView.swift` |
| `async` / `await`, `Task.yield()` | A function that can suspend without blocking its thread; `yield` lets other work (UI updates) run | Coroutines; Go's `runtime.Gosched()` | `SwatchSpikeApp.swift` |
| `reduce` | Folds a collection into one value: `xs.reduce(0, +)` | `std::accumulate` | `GraphLayout.swift` |
| `@objc` and `#selector` | Expose a method to the Objective-C runtime and name it for target/action, checked at compile time | `@selector(tick:)` | `GraphBenchmark.swift` |
| `Selector(("name:"))` | A selector from its name, for actions with no Swift declaration | `NSSelectorFromString` | `MainMenu.swift` |
| Variadic parameters | `_ items: Item...`: any number of arguments, seen as an array | C `...`, but typed | `MainMenu.swift` |
| `withExtendedLifetime` | Keeps an object alive until a closure returns; Swift may free a local after its last use | — | `MargolariaApp.swift` |
| Default arguments | `func graph(at path: String = "")`: callers may leave the argument out | C++ default arguments | `MXDocument.swift` |
| `@discardableResult` | A function whose result callers may ignore without a warning | — | `LayerGraphView.swift` (`drawText`) |
| `inout` on your own functions | `func apply(to model: inout GraphModel)`, called with `&model` | Non-const reference parameter | `GraphAutoLayout.swift` |
| Nested functions | A `func` inside a `func`; it can use the outer function's constants | A lambda assigned to a local | `MXCorpusTests.swift` |

## Protocols and extensions

| Concept | In one line | Closest thing you know | First appears |
|---|---|---|---|
| Protocols | A set of requirements a type promises to meet | Go interfaces, ObjC protocols | `MXError.swift` (`Error`) |
| Extensions | Add members or conformances to any type, including Apple's and C++ ones | ObjC categories | `MXError.swift`, `CxxString.swift` |
| `Identifiable`, `Hashable`, `Equatable` | Standard protocols; the compiler writes `==` and `hash` for simple structs | `operator==` defaulted | `MXDocument.swift` |
| Associated types | A type placeholder inside a protocol, filled in by each conforming type | Template parameter | (was `Snapshot` in `MaterialXFileDocument.swift`, removed in M1a) |
| `some View` | An opaque return type: one concrete type, not named | `auto` return type | `ContentView.swift` |
| Subclassing and `override` | Swift classes can subclass ObjC ones; `override` is required and checked | ObjC subclassing, C++ `override` | `ViewportView.swift` (`StormMTKView: MTKView`) |
| Initializer rules | Set your own properties *before* `super.init`; `required init?(coder:)` must be provided | Reverse of `[super init]` first | `ViewportView.swift` |
| `RandomNumberGenerator` | Implement `next() -> UInt64` and every `random(in:using:)` API accepts your generator | — | `GraphModel.swift` (`SeededRandom`) |
| Subclassing `CALayer` | Override `draw(in:)`; also `init(layer:)`, which Core Animation uses to copy layers | ObjC `CALayer` subclass | `LayerGraphView.swift` (`NodeLayer`) |
| Subclassing AppKit classes | `override func read(from:ofType:)`; `override class var` for class properties AppKit asks the type | ObjC subclassing | `MaterialXDocument.swift` |
| `LocalizedError` | Gives an error the message alerts show (`errorDescription`) | `NSLocalizedDescriptionKey` | `MXError.swift` |

## Modules and access

| Concept | In one line | First appears |
|---|---|---|
| `import` | Imports a compiled module, not text | everywhere |
| Access levels | `public` > `internal` (default) > `fileprivate` > `private` | `CxxString.swift` |
| `@testable import` | Tests can see `internal` declarations | `MXDocumentTests.swift` |
| `public private(set)` | On a stored property: readable everywhere, settable only inside the type | — | `MXDocument.swift` (`hasDataLibrary`) |
| Swift packages | `Package.swift` is Swift code describing targets and dependencies | `Packages/MargolariaKit/Package.swift` |
| `@_exported import` | Re-export another module to everyone who imports this one | An umbrella header | `Snapshot.swift` |
| Public memberwise init | A `public` struct still only gets an `internal` automatic init; write `public init` | — | `ViewportView.swift` |
| `private(set)` | Readable at the property's access level, writable only inside the type | A public getter with a private setter | `GraphCanvasController.swift` (`marquee`) |
| `open` vs `public` | `open` classes can be subclassed outside the module; `public` ones only inside | — | `GraphEventView.swift` |

## Concurrency (Swift 6)

| Concept | In one line | First appears |
|---|---|---|
| `Sendable` | Safe to share between threads; checked by the compiler | `MXError.swift` |
| `@unchecked Sendable` | "I checked this by hand." Always explain why. | `MXLibrary.swift` |
| `Task { @MainActor in }` | Schedule work to run later on the main thread | `dispatch_async(dispatch_get_main_queue(), ^{})` | `ViewportView.swift` |
| Global/static non-`Sendable` values | `static let x: SomeClass` is rejected: any thread could reach it. Make it an instance property instead | — | `SwatchRenderer.swift`, `SwatchRendererTests.swift` |
| `@MainActor` on a type | Every property and method runs on the main thread; callers from elsewhere must `await` | "Main thread only" in the docs, but checked | `GraphCanvasController.swift`, `GraphCanvasControllerTests.swift` (suite) |
| `@MainActor` in a function type | `@MainActor (T) -> Void`: the closure runs on the main actor, so it may touch main-actor state | — | `GraphBenchmark.swift` (`Scenario`) |
| `MainActor.assumeIsolated { }` | "I know I'm on the main thread" (e.g. in a main-run-loop Timer); checked at run time, traps if wrong | `assert([NSThread isMainThread])` | `GraphBenchmark.swift` |
| `@ObservationIgnored` | Excludes a property of an `@Observable` class from observation (callbacks, bookkeeping) | — | `GraphCanvasController.swift` |
| `nonisolated(unsafe)` | Turns off the concurrency check for one declaration (a thread-safe but non-`Sendable` value). Always explain why. | — | `LayerGraphView.swift` (`NodeLayer.titleFont`) |

## SwiftUI

| Concept | In one line | First appears |
|---|---|---|
| `@main` + `App` | A SwiftUI app's entry point (the spikes; the main app uses AppKit's, see below) | `Spikes/M0dGraphCanvas/GraphSpikeApp.swift` |
| `@main` + `static func main()` | Any type with a `static func main()` can be the entry point, like C's `main()` | `MargolariaApp.swift` |
| `View` and `body` | `body` *describes* the UI for the current state; SwiftUI applies the changes | `ContentView.swift` |
| Result builders | The `{ ... }` UI syntax: each expression becomes part of the result | `ContentView.swift` |
| View modifiers | `.font(...)`, `.padding()`: each wraps the view in a new one, so they chain | `ContentView.swift` |
| `@State`, `$binding` | View-owned storage; `$` passes a read/write reference to it | `ContentView.swift` |
| `@ObservedObject` | Redraw when an `ObservableObject` changes | `ContentView.swift` |
| `DocumentGroup`, `ReferenceFileDocument` | SwiftUI's document app. Replaced in M1a by `NSDocument`, because it doesn't give the document its file's URL | (removed in M1a) |
| `NSHostingController` | An AppKit view controller showing a SwiftUI view: SwiftUI inside AppKit | `MaterialXDocument.swift` |
| `@Observable` in a view | A plain `let` of an `@Observable` object is enough: SwiftUI tracks what `body` reads | `CanvasGraphView.swift`, `ContentView.swift` |
| `NSViewRepresentable` | Wraps an AppKit view for SwiftUI: `makeNSView` once, `updateNSView` on changes | `ViewportView.swift` |
| `.task(id:)` | Run work when the view appears and whenever `id` changes | `ViewportView.swift` |
| `WindowGroup`, `.fileImporter` | A plain (non-document) window; the system Open panel | `Spikes/M0bViewport/ViewportSpikeApp.swift` |
| `LazyVGrid`, `ForEach` | A grid that creates cells as they scroll into view; one view per element of a collection | `Spikes/M0cSwatches/SwatchSpikeApp.swift` |
| `@Observable` | A class whose property reads are tracked; views that read a property redraw when it changes. Replaces `ObservableObject` + `@Published` | KVO, without the strings | `GraphCanvasController.swift` |
| `withObservationTracking` | Observe an `@Observable` from non-SwiftUI code: fires once, *before* the change, so re-register and read the new value later | A one-shot KVO observer | `LayerGraphView.swift` |
| `Canvas` | Immediate-mode drawing into a `GraphicsContext`, redrawn whenever state it reads changes | `drawRect:` | `CanvasGraphView.swift` |
| `ZStack`, `.overlay` | Stack views on top of each other | Subviews in z order | `GraphSpikeApp.swift`, `CanvasGraphView.swift` |
| `Picker` + `.tag` | A choice control; `.tag(value)` is what selecting a row writes into the binding | `NSPopUpButton` + `representedObject` | `GraphSpikeApp.swift` |
| `UserDefaults` from the command line | `-key value` launch arguments appear as defaults | `NSArgumentDomain` | `GraphSpikeApp.swift` (`LaunchOptions`) |
| `@Binding` | A property that refers to state another view owns; `$state` passes one | A pointer to the owner's field | `GraphPanel.swift` |
| `.onChange(of:initial:)` | Run code when a value changes (and, with `initial: true`, on appear) | KVO observer | `GraphPanel.swift` |
| `ContentUnavailableView` | The standard "nothing to show" placeholder | — | `GraphPanel.swift` |

## Swift ↔ C++

| Concept | In one line | First appears |
|---|---|---|
| C++ interop mode | `.interoperabilityMode(.Cxx)` / `SWIFT_OBJC_INTEROP_MODE = objcxx`; every importer of a C++-using module needs it too | `Package.swift`, `Config/Base.xcconfig` |
| `std.string` | `std::string` in Swift. Make one with `std.string(swiftString)`; convert back with `.swiftString` (our helper) | `CxxString.swift` |
| `std::vector` | Imported as a Swift collection, so `for x in v` works | `MXDocument.swift` |
| C++ classes are structs | Copying a Swift value copies the C++ object (copy constructor) | `MXBridge.h` |
| `const` ↔ `mutating` | Non-const C++ methods are `mutating`, so they need a `var` | `MXDocument.swift` |
| C++ exceptions | Can't be caught in Swift; one that escapes terminates the process. Catch them in C++. | `MXBridge.cpp` |
| Objective-C classes | Import as Swift classes: `-initWithX:error:` becomes `init(x:) throws`, `nullable` becomes `?` | `MGStormRenderer.h`, `Snapshot.swift` |
| Out-parameter structs | A C++ `T&` parameter is an `inout` argument: pass a `var` with `&` | `MXDocument.swift` (`generateMSL`) |

## Testing

| Concept | In one line | First appears |
|---|---|---|
| `@Test`, `#expect`, `@Suite` | Swift Testing: a test function, a checked condition, a group of tests | `MXDocumentTests.swift` |
| `#require` | Like `#expect`, but stops the test on failure, and unwraps an optional | `MXGraphTests.swift` |
| Parameterized tests | `@Test(arguments: list)` runs once per element, each reported separately | `MXCorpusTests.swift` |
| Traits | `.serialized`, `.enabled(if:)`: change how a test or suite runs | `StormRendererTests.swift`, `MXCorpusTests.swift` |
| `Issue.record` | Records a failure with a message, without stopping the test | `MXCorpusTests.swift` |
| `#filePath` | The path of the current source file, like `__FILE__` | `MXCorpusTests.swift` |
