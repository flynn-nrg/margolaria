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
| `SIMD3<T>` | A small fixed-size vector value: `a + b`, `a * 2`, `.x/.y/.z` work element by element | GLSL/Metal `double3`; `simd::double3` | `ColorConverter.swift` |
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
| Multi-line strings `"""` | Text over several lines; the closing `"""`'s indentation is removed from each line | C++ raw string literal | `Downsampler.swift` (Metal source; now `DisplayPass.swift`) |
| `defer { }` | Runs when the enclosing scope exits, however it exits | Go `defer`; a C++ RAII guard | `LayerGraphView.swift` (`update`) |
| `CaseIterable` | The compiler generates `allCases`, an array of every case of an enum | An X-macro list | `GraphModel.swift` |
| Wrapping arithmetic `&+`, `&*` | Plain `+` traps on overflow; `&+` wraps around like unsigned C arithmetic | C unsigned `+` | `GraphModel.swift` (`SeededRandom`) |
| `Set` algebra | `union`, `symmetricDifference`, `contains`; sets are values like arrays | `std::set` + `<algorithm>` | `GraphCanvasController.swift`, `LayerGraphView.swift` |
| `CGRect` parts | A rectangle is an `origin` (`CGPoint`) and a `size` (`CGSize`); `minX`/`maxY`/`midX` read it normalised, `offsetBy`, `union`, `contains` work on it | `NSRect`/`CGRect` and their C functions | `MXBackdropEdit.swift`, `GraphLayout.swift` (M4d) |
| Enum as a state machine | Each case carries the data that state needs (`.movingNodes(start:original:)`) | A tagged union with a `switch` | `GraphCanvasController.swift` (`DragState`) |
| `if case` / `guard case` | Matches one enum case and binds its values, without a full `switch` | — | `ContentView.swift` (`IssuesBadge`), `MXInspectableTests.swift` |
| Multi-pattern `case` | `case .a(let x), .b(let x):` binds the same name in each pattern | Fall-through `case` labels | `GraphCanvasController.swift` (`mouseDown`) |
| `case ... where` | A pattern with a condition; if it is false, the `switch` tries the next case | — | `GraphCanvasController.swift` (`mouseDown`) |
| `switch` on a tuple, optional patterns | `switch (a, b)` matches both at once; `.x(let v)?` matches an optional holding `.x` | Nested `switch`es | `GraphCanvasController.swift` (`endWire`) |
| `case .x(var v)` | Binds a mutable *copy* of the associated value; store it back with `state = .x(v)` | Copying a struct out of a union | `GraphCanvasController.swift` (`mouseDragged`) |
| `Set.insert(_:).inserted` | `insert` returns whether the element was new | `std::set::insert(...).second` | `GraphWiring.swift` |
| `formUnion` vs `union` | `formUnion` adds another set's elements in place; `union` returns a new set (likewise `formIntersection`, …) | `s.insert(b.begin(), b.end())` vs a copy | `GraphCanvasController.swift` (`movingSelection`, M4d) |
| `dict[key, default: v]` | Reads a dictionary value, or `v` if the key is missing, without an optional | `map.value(key, v)` in Qt | `GraphWiring.swift` |
| `(0...n).map`, `indices.dropFirst()` | Map over a range of integers; every index but the first | A `for` loop filling a vector | `GraphLayout.swift` (`wirePoints`), `GraphWiring.swift` |
| `Dictionary(grouping:by:)` | Builds a dictionary from each key to the array of elements with that key, in order | Go: a `map[K][]V` filled in a loop | `MXNodeCatalog.swift` |
| Comparing tuples | `(a1, b1) < (a2, b2)` compares element by element: a sort key with tie-breakers in one expression | `std::tie(a1, b1) < std::tie(a2, b2)` | `MXNodeCatalog.swift` (`search`, `MXNodeKind.init`) |
| `lazy` sequences | `xs.lazy.map(f).first` computes values only as they are asked for, so it stops at the first | C++20 range views | `MXNodeCatalog.swift` |
| `firstIndex(of:)`, `allSatisfy`, `min(by:)` | Position of a value (or nil); true if every element passes; the smallest by a comparison | `std::find`, `std::all_of`, `std::min_element` | `MXNodeCatalog.swift` |
| Option sets | Bit flags as a set: `flags.contains(.shift)` | `if (flags & NSEventModifierFlagShift)` | `GraphEventView.swift` |
| Failable initializer `init?` | An initializer that can return `nil`; the result is optional | ObjC `-init` returning nil | `MXGraph.swift` (`MXConnection`) |
| Assigning `self` in an enum's `init` | `self = .node(name, output: nil)` picks the case | — | `MXGraph.swift` (`MXConnection`) |
| `if let x` shorthand | Unwraps `x` into a constant of the same name | — | `MXGraph.swift` |
| Nested types | `MXIssue.Severity`: a type declared inside another, for naming only | C++ nested class | `MXIssue.swift` |
| `for … where` | Loops only over elements for which the condition holds | `continue` at the top of the loop | `MXIssue.swift` |
| `try?` | Turns a thrown error into `nil` | Ignoring an error return | `MXIssue.swift` |
| String indices | Strings are sliced with `String.Index` values (`path[..<slash]`), not integers, because characters vary in size | — | `GraphPanel.swift` (`parent(of:)`) |
| Regex literals `#/.../#` | Regular expressions checked by the compiler; capture groups become typed fields (`.1`, `.2`) of each match | `std::regex`, but checked at compile time | `MXXMLTextTests.swift` (`Reference`; MXXMLText.swift until M4e) |
| `popLast()`, `compactMap` | Remove-and-return the last element (nil if empty); `map` that drops nils | `pop_back` with a check | `MXXMLText.swift` |
| `map`/`flatMap` on an optional | Transform the value inside an optional, or get nil | — | `GraphBuilder.swift` |
| `ClosedRange` | `0...1`: a range including both ends; SwiftUI sliders take one | — | `MXValue.swift` (`sliderRange`) |
| `zip` | Pairs two sequences element by element into tuples | Python `zip` | `MXValue.swift` (`MXPortUI`) |
| `Double` vs `Float`; `String(Float(x))` | 64- and 32-bit floats, never converted implicitly. `String(_:)` on a Float prints the shortest text that reads back as the same Float | `double`/`float`; `%g` with round-trip precision | `MXValue.swift` (`MXValueText`) |
| Enums with raw values | `enum E: String { case studio }`: each case has a fixed value (`.rawValue`), and `E(rawValue:)` reads one back, nil if unknown | A C enum with explicit values, plus a parse function | `ViewportSettings.swift` (`ViewportEnvironment`) |
| Raw values unlike the case names | `case uiName = "uiname"`: Swift's camelCase for the case, the file's spelling for the value | `#define` names vs their strings | `MXInterfaceEdit.swift` (`MXInputMetadata`) |
| `pathComponents`, `starts(with:)` | A path as an array of its parts; whether one array begins with another, to tell a file is inside a folder | Comparing `NSString` path components | `MXLibraryFiles.swift` (`href`) |
| `FileManager.url(for:in:appropriateFor:create:)` | Finds a standard folder (Application Support, Caches...), creating it if asked | `NSSearchPathForDirectoriesInDomains` | `MXLibraryFiles.swift` |
| `filter` on a dictionary | Keeps the key-value pairs for which the closure is true, and returns a dictionary | — | `MXGraph.swift` (`MXPort.metadata`) |
| `switch` as an expression | `let t = switch x { case .a: "A" case .b: "B" }`: the value of the chosen case | A ternary over many cases | `ViewportSettings.swift` |
| `Float.exponent`, `Float(sign:exponent:significand:)` | A float's binary exponent, and building `2^e` exactly | `frexp`, `ldexp` | `StudioEnvironment.swift` (`rgbe`) |
| `static let x = { ... }()` | A constant computed by a closure, once, on first use | A function-local static initialised by a lambda | `StudioEnvironment.swift` (`fileURL`) |
| `[T](repeating:count:)` | An array of n copies of a value | `std::vector<T>(n, v)` | `ViewTransformTests.swift` (now `DisplayPassTests.swift`) |
| `Dictionary(uniqueKeysWithValues:)` | Builds a dictionary from (key, value) pairs; traps on a repeated key (`uniquingKeysWith:` decides instead) | Filling a `std::map` from a vector of pairs | `GraphPanel.swift` (`requestSwatches`) |
| An initializer as a function | `String.init` is String's initializer, passable where a function is expected: `.map(String.init)` is `.map { String($0) }` | A function pointer to a constructor (which C++ doesn't have) | `ViewportPanel.swift` |
| `WritableKeyPath` and `value[keyPath:]` | `\.x` names a property; `v[keyPath: path]` reads or writes it, so one function can edit any component | A pointer to member, `&T::x` | `ColorPickerPopover.swift` (`channel`) |
| `simd_max`, `simd_min` on vectors | Component-wise maximum and minimum of two vectors | `std::max` per component | `ColorPicking.swift` |
| `String(format:)`, `Int(_:radix:)` | printf-style formatting (`%02X`), and parsing in another base | `snprintf`, `strtol(s, nil, 16)` | `ColorPicking.swift` (`hex`) |
| `Hasher` | Swift's hash function, used by hand: `combine` values, then `finalize()` to an `Int`. Seeded randomly per process, so hashes are only compared within one run | `std::hash` combined with `boost::hash_combine` | `SwatchPlan.swift` |
| `Float16` | A 16-bit float, the same as Metal's `half` | `_Float16` | `SwatchEnvironment.swift` |
| CryptoKit's `SHA256` | Hashes bytes into a digest; here, to key a cache by a long text without keeping it | CommonCrypto's `CC_SHA256` | `SwatchRenderer.swift` (`key(for:)`) |

| `String.utf8`, `UInt8(ascii:)`, `elementsEqual` | A string's UTF-8 bytes (`Array(s.utf8)` to scan them by offset); the byte of an ASCII character; comparing two sequences element by element. A native string's `utf8` index moves by an offset in constant time | `const char *`, `'<'`, `memcmp` | `MXXMLText.swift` |
| `Array(string)` to index characters | A `String` can't be indexed by `Int` (characters vary in length in memory); an array of its `Character`s can, at the cost of a copy | `std::u32string` | `CommandPalette.swift` (`FuzzyMatch`) |
| `stride(from:to:by:)` | Counts from a start up to (not including) an end in steps | `for (i = 0; i < n; i += 7)` | `MXXMLEditTests.swift` |
| `Process` and `Pipe` | Runs another program with its arguments, no shell between, and collects what it prints; read the pipe before `waitUntilExit()`, or a chatty program blocks on a full pipe | `posix_spawn` with a pipe; Go's `exec.Command` | `MXShaderExport.swift` (`compileOSL`) |
| `UserDefaults.standard` directly | What `@AppStorage` wraps, for AppKit code; `object(forKey:)` is nil for a key never set, which `bool(forKey:)` (false) can't tell apart | `NSUserDefaults` | `MaterialXDocument.swift` (`OSLCompilerAccessory`) |
| `NSPathControl` and its delegate | A file path as a control; `.popUp` style with `isEditable` adds a "Choose…" menu item, whose open panel the delegate sets up | `NSPathControl` | `MaterialXDocument.swift` (`OSLCompilerAccessory`) |
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
| `reduce(into:)` | The same, with the value changed in place (`inout`) by the closure: no copy per element | A loop appending to an accumulator | `MXNodeGraphEdit.swift` (`stringVector`) |
| `@objc` and `#selector` | Expose a method to the Objective-C runtime and name it for target/action, checked at compile time | `@selector(tick:)` | `GraphBenchmark.swift` |
| An Objective-C class property | `@property (class) NSArray *x` is a `static` property in Swift, read on the type: `MGStormRenderer.availableRendererIDs` | `+ (NSArray *)x` | `RendererPickerTests.swift` (M5e) |
| A `BOOL ... error:` method in Swift | `- (BOOL)setRendererID:(NSString *)id error:(NSError **)error` imports as `func setRendererID(_:) throws`: NO with an error becomes a thrown error, and the BOOL disappears | Checking the BOOL, then the NSError | `ViewportView.swift` (`useRenderer`, M5e) |
| A closure in a `let` | `let isSet: (MXPort) -> Bool = { ... }`, then `filter(isSet)`: a closure is a value, passed by name | A function pointer or `std::function` | `GraphBuilder.swift` |
| `NSMenu.popUp(positioning:at:in:)` | Shows a menu built in code and returns once it closes, after the chosen item's action ran | `-popUpMenuPositioningItem:atLocation:inView:` | `GraphEventView.swift` |
| `Selector(("name:"))` | A selector from its name, for actions with no Swift declaration | `NSSelectorFromString` | `MainMenu.swift` |
| Variadic parameters | `_ items: Item...`: any number of arguments, seen as an array | C `...`, but typed | `MainMenu.swift` |
| `withExtendedLifetime` | Keeps an object alive until a closure returns; Swift may free a local after its last use | — | `MargolariaApp.swift` |
| `Task.sleep(for:)` | Suspends a task for a while without blocking its thread | `dispatch_after` | `ViewportView.swift` (`cameraMoved`) |
| `Thread.sleep(forTimeInterval:)` | Blocks the calling thread for a while; only where blocking is the point (a test's wait), never on the main thread | `usleep` | `Snapshot.swift` (M5e) |
| Default arguments | `func graph(at path: String = "")`: callers may leave the argument out | C++ default arguments | `MXDocument.swift` |
| `@escaping` closures | A closure parameter that may run after the function returns must be marked; others can't outlive the call | A block copied to the heap | `MaterialXDocument.swift` (`edit`) |
| Closures with `inout` parameters | `(inout std.string) -> Bool`: the closure can write to the caller's variable | A lambda taking `T&` | `MXEdit.swift` (`perform`) |
| `@discardableResult` | A function whose result callers may ignore without a warning | — | `LayerGraphView.swift` (`drawText`) |
| `inout` on your own functions | `func apply(to model: inout GraphModel)`, called with `&model` | Non-const reference parameter | `GraphAutoLayout.swift` |
| Nested functions | A `func` inside a `func`; it can use the outer function's constants | A lambda assigned to a local | `MXCorpusTests.swift` |
| `enumerated()` | Pairs each element with its index | Go's `for i, x := range xs` | `DisplayPass.swift` |
| `joined(separator:)` | Concatenates strings | Go's `strings.Join` | `DisplayPass.swift` |
| `&variable` to a pointer parameter | Lends a C API a pointer to a `var` for the length of the call | `&x` in C | `DisplayPass.swift` (`setFragmentBytes`) |
| `withUnsafeMutableBytes` | Lends a writable raw pointer to an array's storage for the length of a closure | Passing `vec.data()` to a C function that fills it | `ViewTransformTests.swift` (now `DisplayPassTests.swift`) |
| `oldValue` in `didSet` | The value before the assignment; observers don't run for assignments in the type's own `init` | Comparing in a custom setter | `ViewportView.swift` (`StormMTKView.environment`) |
| Generic functions `func f<Item>(...)` | Work for any type; the body is checked once against what every type allows, not per use | C++ function templates, Go generics | `CommandPalette.swift` (`FuzzyMatch.rank`) |
| A closure stored in a struct | `let run: @MainActor () -> Void`: code as data, carrying what it captured; such structs can't be `Equatable` | A block property in ObjC | `CommandPalette.swift` (`PaletteCommand`) |
| `Set.insert(_:).inserted` | `insert` returns whether the element was new: filtering repeats in one line | `std::set::insert(...).second` | `ContentView.swift` (`unique`) |
| A nested function | A `func` inside a function: it can use and change the enclosing function's locals, like a closure with a name | A lambda capturing by reference | `MXShaderExport.swift` (`save`) |

## Protocols and extensions

| Concept | In one line | Closest thing you know | First appears |
|---|---|---|---|
| Protocols | A set of requirements a type promises to meet | Go interfaces, ObjC protocols | `MXError.swift` (`Error`) |
| Extending a generic type | `extension Array { ... }` adds members to arrays of every element type; `Element` names that type inside | A member template on `std::vector` (not possible in C++) | `MXValue.swift` |
| Extensions | Add members or conformances to any type, including Apple's and C++ ones | ObjC categories | `MXError.swift`, `CxxString.swift` |
| `Identifiable`, `Hashable`, `Equatable` | Standard protocols; the compiler writes `==` and `hash` for simple structs | `operator==` defaulted | `MXDocument.swift` |
| Associated types | A type placeholder inside a protocol, filled in by each conforming type | Template parameter | (was `Snapshot` in `MaterialXFileDocument.swift`, removed in M1a) |
| `some View` | An opaque return type: one concrete type, not named | `auto` return type | `ContentView.swift` |
| Subclassing and `override` | Swift classes can subclass ObjC ones; `override` is required and checked | ObjC subclassing, C++ `override` | `ViewportView.swift` (`StormMTKView: MTKView`) |
| Initializer rules | Set your own properties *before* `super.init`; `required init?(coder:)` must be provided | Reverse of `[super init]` first | `ViewportView.swift` |
| `RandomNumberGenerator` | Implement `next() -> UInt64` and every `random(in:using:)` API accepts your generator | — | `GraphModel.swift` (`SeededRandom`) |
| Subclassing `CALayer` | Override `draw(in:)`; also `init(layer:)`, which Core Animation uses to copy layers | ObjC `CALayer` subclass | `LayerGraphView.swift` (`NodeLayer`) |
| `CATextLayer`, `insertSublayer(_:at:)` | A layer that draws a string at `fontSize` and `contentsScale`, wrapped or truncated; `insertSublayer` places a layer in the stack where `addSublayer` puts it on top | The same Core Animation API in ObjC | `LayerGraphView.swift` (`BackdropLayer`, M4d) |
| Subclassing AppKit classes | `override func read(from:ofType:)`; `override class var` for class properties AppKit asks the type | ObjC subclassing | `MaterialXDocument.swift` |
| `UndoManager.registerUndo(withTarget:)` | Stores a closure to call on Undo; registering during an undo becomes the redo | `-registerUndoWithTarget:handler:` | `MaterialXDocument.swift` |
| `Codable` | Declaring `Codable` on a struct of Codable properties makes the compiler write its encoding and decoding (JSON, property lists) | Go's `encoding/json` struct tags, without the tags | `LibraryPanel.swift` (`NodeDefinitionDrag`) |
| `addObserver(_:selector:name:object:)` | Calls an `@objc` method of the observer for each matching notification; `object: nil` means from any sender | `-addObserver:selector:name:object:` | `MargolariaApp.swift` (colour panel) |
| `LocalizedError` | Gives an error the message alerts show (`errorDescription`) | `NSLocalizedDescriptionKey` | `MXError.swift` |
| `NSMenuItemValidation` in an extension | `validateMenuItem(_:)` enables or greys out the menu items whose actions the object receives; conforming in an extension keeps it beside its method | `-validateMenuItem:` (an informal protocol in ObjC) | `GraphEventView.swift` |

| `XMLParser` and its delegate | Foundation's event-driven XML parser; a delegate object (an `NSObject` subclass, held weakly) hears about each tag and error | `NSXMLParser`, SAX | `MXXMLEdit.swift` |
| Overriding an AppKit view's property and actions | `override var undoManager` with a computed one; `@objc func undo(_:)` answers the menu's action before the window does, and `validateUserInterfaceItem` enables and titles the item | An Objective-C subclass | `XMLTextView.swift` (`XMLEditingTextView`) |
| A coordinator as an AppKit delegate | The `NSViewRepresentable`'s coordinator (an `NSObject`) adopts `NSTextViewDelegate` and hears `textDidChange` | A controller as a view's delegate | `XMLTextView.swift` |
## Modules and access

| Concept | In one line | First appears |
|---|---|---|
| `import` | Imports a compiled module, not text | everywhere |
| Access levels | `public` > `internal` (default) > `fileprivate` > `private` | `CxxString.swift` |
| `@testable import` | Tests can see `internal` declarations | `MXDocumentTests.swift` |
| `public private(set)` | On a stored property: readable everywhere, settable only inside the type | — | `MXDocument.swift` (`hasDataLibrary`) |
| `public internal(set)`; `private` is per file | Readable everywhere, settable anywhere in the module. Swift's `private` means "this file", so an extension in another file can't use it | — | `MXDocument.swift` (`hasDataLibrary`) |
| Swift packages | `Package.swift` is Swift code describing targets and dependencies | `Packages/MargolariaKit/Package.swift` |
| `binaryTarget` | A prebuilt library (an xcframework) as a package target: linked, its headers on the include path, embedded by Xcode | `Packages/MargolariaKit/Package.swift` (OpenColorIO) |
| `@_exported import` | Re-export another module to everyone who imports this one | An umbrella header | `Snapshot.swift` |
| Public memberwise init | A `public` struct still only gets an `internal` automatic init; write `public init` | — | `ViewportView.swift` |
| `private(set)` | Readable at the property's access level, writable only inside the type | A public getter with a private setter | `GraphCanvasController.swift` (`marquee`) |
| `open` vs `public` | `open` classes can be subclassed outside the module; `public` ones only inside | — | `GraphEventView.swift` |
| `package` access | Between `internal` and `public`: every module of the same Swift package sees it, other packages and the app don't | A header shared by a library's own components but not installed | `MXDocument.swift` (`handle`), `CxxString.swift`, used by `ScriptKit/Python.swift` (M6a) |
| `Context.packageDirectory` | In `Package.swift`: the package's folder, for paths outside it (with `unsafeFlags`) | CMake's `CMAKE_CURRENT_SOURCE_DIR` | `Packages/MargolariaKit/Package.swift` (PythonBridge, M6a) |

## Concurrency (Swift 6)

| Concept | In one line | First appears |
|---|---|---|
| `withCheckedThrowingContinuation` | Turns a callback API into an `await`: the closure gets a continuation, and the callback resumes it, exactly once, with a value or an error (like waiting on a semaphore the callback signals, without blocking a thread) | `Spikes/M5aUSDZ/RealityKitRender.swift` |
| `Sendable` | Safe to share between threads; checked by the compiler | `MXError.swift` |
| `@unchecked Sendable` | "I checked this by hand." Always explain why. | `MXLibrary.swift` |
| `Task { @MainActor in }` | Schedule work to run later on the main thread | `dispatch_async(dispatch_get_main_queue(), ^{})` | `ViewportView.swift` |
| Global/static non-`Sendable` values | `static let x: SomeClass` is rejected: any thread could reach it. Make it an instance property, a computed `static var` (cheap values such as regex literals), or, if it is truly thread-safe, `nonisolated(unsafe)` with a comment | — | `SwatchRenderer.swift`, `MXXMLTextTests.swift`, `LayerGraphView.swift` |
| `@MainActor` on a type | Every property and method runs on the main thread; callers from elsewhere must `await` | "Main thread only" in the docs, but checked | `GraphCanvasController.swift`, `GraphCanvasControllerTests.swift` (suite) |
| `@MainActor` in a function type | `@MainActor (T) -> Void`: the closure runs on the main actor, so it may touch main-actor state | — | `GraphBenchmark.swift` (`Scenario`) |
| Function types as parameters | `(([Double], String, String) throws -> [Double])?`: an optional function; function types have no argument labels, so calls are `convert(a, b, c)` | A C function pointer or a C++ `std::function` | `MXWorkingSpace.swift` (`setWorkingSpace`) |
| `MainActor.assumeIsolated { }` | "I know I'm on the main thread" (e.g. in a main-run-loop Timer); checked at run time, traps if wrong | `assert([NSThread isMainThread])` | `GraphBenchmark.swift` |
| `@ObservationIgnored` | Excludes a property of an `@Observable` class from observation (callbacks, bookkeeping) | — | `GraphCanvasController.swift` |
| `nonisolated(unsafe)` | Turns off the concurrency check for one declaration (a thread-safe but non-`Sendable` value). Always explain why. | — | `LayerGraphView.swift` (`NodeLayer.titleFont`) |
| `actor` | A class whose methods never run at the same time; callers `await` their turn instead of blocking on a lock. Its code runs on background threads | An object guarded by one mutex, with a work queue | `SwatchService.swift` |
| Cancelling a `Task` | `let t = Task { ... }` keeps a handle; `t.cancel()` asks it to stop, and the code checks `Task.isCancelled` and returns (cooperative). `await t.value` waits for it | A cancellation flag polled by a worker | `SwatchService.swift` (`SwatchCache`) |
| `withTaskGroup` | Runs child tasks concurrently and waits for all; `for await` takes their results as they finish. No child outlives the group | `dispatch_group` with a results queue; Go's `errgroup` | `SwatchService.swift` (`render`) |
| `@MainActor @Sendable` closures | A closure that may be passed to another actor and always runs on the main thread: how background work hands results to the UI | A block dispatched to the main queue | `SwatchService.swift` (`deliver`) |
| Completion handlers as `async` | An Objective-C method with a completion block is also callable as `try await` (`makeLibrary(source:options:)`) | Wrapping a callback API in a future | `SwatchRenderer.swift` (`SwatchPipeline.compile`) |
| `nonisolated` on a member | One method of a `@MainActor` type that any thread may call, because it touches no state | A free function | `LayerGraphView.swift` (`cgColor`) |
| `Task.detached` from `.task(id:)` | The view's task awaits work run off the main actor; only `Sendable` values (strings, a `Result`) cross over, and `Task.isCancelled` drops a result the newer request replaced | `GeneratedShaderTab` in `BottomPanel.swift` |

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
| `.onReceive(NotificationCenter.default.publisher(for:))` | Runs a closure for each notification posted with that name, while the view is shown | `addObserver:selector:name:object:` | `LibraryPanel.swift` |
| `NSSavePanel` | The Save dialog: folder, file name and types to start with, as a sheet on the window | The same class in ObjC | `InspectorPanel.swift` (`saveToLibrary`) |
| A save panel's accessory view | `accessoryView` adds a view of our own under the file browser (a format popup); changing `allowedContentTypes` while the panel is open changes the type it saves | `setAccessoryView:` | `MaterialXDocument.swift` (`USDFormatAccessory`, M5b) |
| An `NSObject` subclass as a control's target | AppKit controls call an `@objc` method on a target object, not a closure; the control holds the target weakly, so something else must keep it alive (here, the panel's completion handler) | Target/action | `MaterialXDocument.swift` (`USDFormatAccessory`) |
| `Bindable(object).property` | A binding to a property of an `@Observable` object held in a plain `let`, as `$` gives one for `@State` | — | `ContentView.swift` (`previewMaterial`, M5c) |
| A throwing closure as a parameter | `(URL) throws -> Void`: the caller's `try` lines go in the closure, and the function that calls it catches what it throws | A block with an `NSError **` out-parameter | `MaterialXDocument.swift` (`runExportPanel`, M5c) |
| `super.init()` in a subclass's `init` | Every stored property set first, then `super.init()`, and only then may `self` be used (as a target): Swift's two-phase initialisation | `self = [super init]` first, in ObjC | `MaterialXDocument.swift` (`USDFormatAccessory`) |
| Tuples as list rows | `ForEach(rows, id: \.definition.name)`: a key path into a tuple's labelled part gives each row its identity | — | `LibraryPanel.swift` |
| `WindowGroup`, `.fileImporter` | A plain (non-document) window; the system Open panel | `Spikes/M0bViewport/ViewportSpikeApp.swift` |
| `LazyVGrid`, `ForEach` | A grid that creates cells as they scroll into view; one view per element of a collection | `Spikes/M0cSwatches/SwatchSpikeApp.swift` |
| `@Observable` | A class whose property reads are tracked; views that read a property redraw when it changes. Replaces `ObservableObject` + `@Published` | KVO, without the strings | `GraphCanvasController.swift` |
| `withObservationTracking` | Observe an `@Observable` from non-SwiftUI code: fires once, *before* the change, so re-register and read the new value later | A one-shot KVO observer | `LayerGraphView.swift` |
| `NotificationCenter` closures and `MainActor.assumeIsolated` | `addObserver(forName:object:queue:using:)` calls a closure; with `queue: .main` it runs on the main thread, and `assumeIsolated` lets it use main-actor state (checked at run time) | `addObserverForName:object:queue:usingBlock:` | `MainMenu.swift` (`shareCommandG`, M4d) |
| `Canvas` | Immediate-mode drawing into a `GraphicsContext`, redrawn whenever state it reads changes | `drawRect:` | `CanvasGraphView.swift` |
| `ZStack`, `.overlay` | Stack views on top of each other | Subviews in z order | `GraphSpikeApp.swift`, `CanvasGraphView.swift` |
| `Picker` + `.tag` | A choice control; `.tag(value)` is what selecting a row writes into the binding | `NSPopUpButton` + `representedObject` | `GraphSpikeApp.swift` |
| `UserDefaults` from the command line | `-key value` launch arguments appear as defaults | `NSArgumentDomain` | `GraphSpikeApp.swift` (`LaunchOptions`) |
| `@Binding` | A property that refers to state another view owns; `$state` passes one | A pointer to the owner's field | `GraphPanel.swift` |
| `.onChange(of:initial:)` | Run code when a value changes (and, with `initial: true`, on appear) | KVO observer | `GraphPanel.swift` |
| `ContentUnavailableView` | The standard "nothing to show" placeholder | — | `GraphPanel.swift` |
| `.id(_:)` | Gives a view an identity; changing it discards the view and its `@State` and builds a new one | — | `GraphPanel.swift` |
| `NSViewRepresentable` coordinator | `makeCoordinator()`: an object that lives as long as the AppKit view, for state the AppKit side remembers between updates | A view controller's ivars | `XMLTextView.swift` |
| `VSplitView`, `.contextMenu` | Views stacked with draggable dividers; a right-click menu on a view | `NSSplitView`; `menuForEvent:` | `ContentView.swift`, `BottomPanel.swift` |
| `HSplitView`, `Toggle` as a button | Side-by-side views with a draggable divider; a toolbar button that stays pressed | `NSSplitView`; a toggle `NSButton` | `ContentView.swift` |
| `@FocusState` | State kept in step with keyboard focus; `.focused($isFocused)` connects a field to it | `InspectorFields.swift` (`CommitTextField`) |
| `Binding(get:set:)` | A binding made of two closures instead of stored state: reading reads the document, writing makes an edit | `InspectorFields.swift` (`ScalarEditor`) |
| `Slider(onEditingChanged:)` | Reports when a drag starts (true) and ends (false); used to make a drag one undo step | `InspectorFields.swift` |
| `ColorPicker` with `CGColor` | A colour well bound to a Core Graphics colour; convert it to a known `CGColorSpace` before reading components | `InspectorFields.swift` (`ColorSpaceMapping`; replaced by our own popover in M3e) |
| `State(initialValue:)` | Sets a `@State` property's first value from an `init` argument; in `init` the property is its wrapper, `_name` | — | `ColorPickerPopover.swift` (`original`) |
| `TextField(value:format:)` | A text field that edits a number, parsed and shown with a format (`.number.precision(.fractionLength(0...4))`) | `NSNumberFormatter` on an `NSTextField` | `ColorPickerPopover.swift` |
| A custom control: shapes and a `DragGesture` | Draw the control from shapes in a `GeometryReader`, and map the pointer to a value with `DragGesture(minimumDistance: 0)` (which also takes a click) | Subclassing `NSControl` and overriding `mouseDown`/`mouseDragged` | `ColorPickerPopover.swift` (`ColorTrack`, `ColorField`) |
| `.presentationBackground` | What is behind a popover's or sheet's content; here opaque instead of the default glass | — | `ColorPickerPopover.swift` |
| A float bitmap | `CGContext` with 32-bit components and `CGBitmapInfo.floatComponents`, filled from a `[Float]`, to show computed colours (above 1 included) | `CGBitmapContextCreate` with `kCGBitmapFloatComponents` | `ColorPickerPopover.swift` (`fieldImage`) |
| `NSColorSampler` | The system's screen eyedropper; its handler gets the colour (or nil) | — | `ColorPickerPopover.swift` (`sampleScreen`) |
| `DisclosureGroup` | A collapsible section with a triangle; `isExpanded:` binds whether it is open | `InspectorPanel.swift` |
| `Transferable`, `.draggable`, `.dropDestination` | A value that can be dragged (or copied); a view that starts the drag; a view that accepts drops of that type, with the drop location | `LibraryPanel.swift`, `GraphPanel.swift` |
| `UTType(exportedAs:)` | A data type of our own for the pasteboard, also declared in Info.plist; `CodableRepresentation` carries a Codable value under it | `LibraryPanel.swift` |
| `Section(isExpanded:)` | A list section the user can fold, with its open state in a binding | `LibraryPanel.swift` |
| `.contextMenu(forSelectionType:primaryAction:)` | A list's row menu, plus the action for double-click and Return on the selected rows | `LibraryPanel.swift` |
| `.tag` on a `List` row | Gives a row that doesn't come from a `ForEach` the ID the list's selection uses | `LibraryPanel.swift` (`NodeGraphRow`) |
| `NSPasteboard` | `clearContents()`, then `setString(_:forType:)` once per type (our own UTI, and `.string` for other apps); `string(forType:)` reads | `GraphPanel.swift` (`NodePasteboard`) |
| `.popover(attachmentAnchor:)` | A popover pointing at a rectangle in the view (`.rect(.rect(r))`), not the whole view | `GraphPanel.swift` (node search) |
| `.onKeyPress` | Sees a key before the view does; `.handled` stops it, `.ignored` passes it on | `NodeSearchPopup.swift` |
| `ScrollViewReader` | A proxy that scrolls a `ScrollView` to the child with a given `.id` | `NodeSearchPopup.swift` |
| `.allowsHitTesting(false)` | Clicks go through the view to whatever is under it | `GraphPanel.swift` (empty-canvas hint) |
| `.keyboardShortcut(.defaultAction)` / `.cancelAction` | Return (or Escape) presses the button; the default one is drawn highlighted | `TemplateSheet.swift` |
| `.sheet(isPresented:)`, `@Environment(\.dismiss)` | A modal sheet over the window while a binding is true; inside it, `dismiss()` closes it | `-beginSheet:completionHandler:`, `-endSheet:` | `InspectorPanel.swift` (`NodeDefinitionSheet`) |
| `Form` | Lays labelled controls out in two columns, labels right-aligned, as in settings windows | An `NSGridView` of labels and fields | `InspectorPanel.swift` (`NodeDefinitionSheet`) |
| `TextField(axis: .vertical)` with `.lineLimit(2...4)` | A text field that grows to several lines as the text wraps | An `NSTextView` that resizes | `InspectorPanel.swift` (`NodeDefinitionSheet`) |
| `.buttonStyle(.plain)` | A button without the standard look, drawing only its label: for rows that show their own selection | `TemplateSheet.swift` |
| `let _ = x` in `body` | Reads a property so the view observes it, without using the value | `InspectorPanel.swift` (`document.revision`) |
| `@AppStorage("key")` | `@State` kept in user defaults: shared by every view that uses the key, and kept between launches (`NSUserDefaults`) | `ViewportPanel.swift` |
| `Section` in a menu-style `Picker` | Groups the menu's items under a heading, with a separator | `ViewportPanel.swift` (view transform) |
| `Menu` with an inline `Picker`, `.menuStyle(.borderlessButton)` | A pop-up menu button whose content mixes a checkmarked choice (`.pickerStyle(.inline)`), buttons and submenus; drawn as plain text with an arrow | `NSPopUpButton` with a pull-down menu | `InspectorFields.swift` (`ColorSpaceMenu`) |
| `.confirmationDialog(_:isPresented:presenting:)` | Asks a question with several buttons; `presenting` hands each button the value it is about | `NSAlert` with several buttons | `WorkingSpaceMenu.swift` |

| `.alert(_:isPresented:actions:message:)` | An alert sheet while a binding is true; its buttons are views, and the one with `role: .cancel` is Escape's | `XMLTextView.swift` (`XMLTab`) |
| Debouncing with `.task(id:)` and `Task.sleep` | A task that sleeps first, restarted whenever `id` changes: only the last of a burst of changes gets past the sleep | `XMLTextView.swift` (`XMLTab`) |
| `.safeAreaInset` vs `HSplitView`/`VSplitView` | An inset only makes room in views that respect safe areas; the split views (NSSplitView underneath) don't, and run under it. A `VStack` makes room for anything | `ContentView.swift` (`LibraryStatusBar`) |
| `PreferenceKey`, `.transformPreference`, `.overlayPreferenceValue` | Values passed *up* the view tree: views add theirs under a key, `reduce` combines siblings', and an ancestor reads the result to build an overlay | `NodeSearchPopup.swift` (`PaletteCommandsKey`), `ContentView.swift` |
| `.onExitCommand` | Runs on Escape (AppKit's `cancelOperation:`) in the focused view | `NodeSearchPopup.swift` (`CommandPalette`) |
| `LazyVStack` | Makes its rows only as they scroll into view, for long lists | `NodeSearchPopup.swift` (`CommandPalette`) |
| `@objc` action on an `NSDocument` | The document is in its window's responder chain, after the views, window and controller: a menu item's action reaches it from wherever the focus is | `MaterialXDocument.swift` (`showCommandPalette`) |
| `@AppStorage` of an enum | An enum with `String` raw values is stored as its raw value and read back with `init(rawValue:)` | `BottomPanel.swift` (`GeneratedShaderTab`) |
## Swift ↔ C++

| Concept | In one line | First appears |
|---|---|---|
| C++ interop mode | `.interoperabilityMode(.Cxx)` / `SWIFT_OBJC_INTEROP_MODE = objcxx`; every importer of a C++-using module needs it too | `Package.swift`, `Config/Base.xcconfig` |
| `std.string` | `std::string` in Swift. Make one with `std.string(swiftString)`; convert back with `.swiftString` (our helper) | `CxxString.swift` |
| `std::vector` | Imported as a Swift collection, so `for x in v` works | `MXDocument.swift` |
| C++ template instances | Swift can't write `std::vector<float>` itself; give it a name with `using FloatVector = std::vector<float>;` in the header. Imported vectors can be made from a Swift array: `FloatVector([1, 2, 3])` | `ColorBridge.h`, `ColorConverter.swift` |
| Filling a C++ vector | `var v = mxbridge.StringVector(); v.push_back(std.string(s))`: the C++ methods, called from Swift | `MXNodeGraphEdit.swift` |
| C++ classes are structs | Copying a Swift value copies the C++ object (copy constructor) | `MXBridge.h` |
| `const` ↔ `mutating` | Non-const C++ methods are `mutating`, so they need a `var` | `MXDocument.swift` |
| C++ exceptions | Can't be caught in Swift; one that escapes terminates the process. Catch them in C++. | `MXBridge.cpp` |
| `CGContext` drawing | Core Graphics' C API with Swift names: `CGContext(data:width:...)`, `context.fill(rect)`, `makeImage()` | `CGBitmapContextCreate`, `CGContextFillRect` | `BuildFromNothingTests.swift` |
| Objective-C classes | Import as Swift classes: `-initWithX:error:` becomes `init(x:) throws`, `nullable` becomes `?` | `MGStormRenderer.h`, `Snapshot.swift` |
| Out-parameter structs | A C++ `T&` parameter is an `inout` argument: pass a `var` with `&` | `MXDocument.swift` (`generateMSL`) |
| `Array(cxxVector)` | Copies an imported C++ vector into a Swift array, so it outlives the C++ object | `GPUShader.swift` |
| Option dictionaries | Objective-C APIs taking `NSDictionary` options take `[Key: Any]` in Swift; enum values go in as their `rawValue` | `MTKTextureLoader` in `SwatchRenderer.swift` (`image(at:)`) |
| Toll-free bridging `as CFString` | Swift `String` ↔ `CFString` (and `URL` ↔ `CFURL`) convert for free; useful to keep a `Sendable` String and convert at the call, like ObjC's `(__bridge CFStringRef)` | `ViewportSettings.swift` (since M3c `ViewTransform.swift`) |
| C++ `enum class` | Imported as a type whose cases are static members (`mxbridge.ShaderLanguage.msl`), not a Swift enum (C++ may hold values with no case), so a Swift enum mirrors it and converts | `MXShader.swift` (`MXShaderLanguage.bridgeValue`) |

## Testing

| Concept | In one line | First appears |
|---|---|---|
| `@Test`, `#expect`, `@Suite` | Swift Testing: a test function, a checked condition, a group of tests | `MXDocumentTests.swift` |
| `#require` | Like `#expect`, but stops the test on failure, and unwraps an optional | `MXGraphTests.swift` |
| Parameterized tests | `@Test(arguments: list)` runs once per element, each reported separately | `MXCorpusTests.swift` |
| Two argument lists | `@Test(arguments: files, [false, true])` runs every combination, with one parameter per list | `StormCorpusTests.swift` (`previewTextMatchesFile`) |
| Traits | `.serialized`, `.enabled(if:)`: change how a test or suite runs | `StormRendererTests.swift`, `MXCorpusTests.swift` |
| `Issue.record` | Records a failure with a message, without stopping the test | `MXCorpusTests.swift` |
| `#filePath` | The path of the current source file, like `__FILE__` | `MXCorpusTests.swift` |
| `@MainActor async` tests | A parameterized test marked `@MainActor` and `async`: it awaits main-thread-only APIs (RealityKit) directly | `USDZExportTests.swift` (M5c) |
| `Array.max()` / `min()` | Return an optional: an empty array has neither; `!` unwraps when it can't be empty | `USDZExportTests.swift` (`expectGreyTexture`, M5c) |
| `async` tests, collecting from callbacks | A test can be `async` and `await`; results from a `@Sendable` callback go into a `@MainActor` class instance (a `var` can't be captured) | `SwatchCacheTests.swift` (`Collected`) |
