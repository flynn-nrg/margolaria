// ScriptRun.swift
//
// A script running on a worker thread (M6c), so the window can offer to
// stop it: the main thread can't notice a click or ⌘. while Python holds
// it (PLAN.md §8.7, Threads).
//
// The document stays the main thread's: the script changes it on the
// worker, and the main thread doesn't touch it until the run ends. The
// script's calls to Swift (`margolaria.selection()`, `issues()`, the
// exports) are answered on the main thread, while the worker waits:
//
//   worker thread                      main thread
//   pybridge.Interpreter.run(...)      start(): waits up to `timeout`,
//     margolaria.issues()                answering calls as they come
//       Channel.ask(call) ──────────▶  Channel.pump(): HostCalls answers
//       waits for the answer ◀──────     the call, on the document
//     ...                              (or, after `timeout`, the run loop
//   returns: Channel.finish(result)      runs, and each call and the end
//       ──────────────────────────▶      arrive as a block on the main queue)
//
// Most scripts end within `timeout`, so the window never notices; a longer
// one returns control to the window, which shows a "Running… Stop" sheet
// (MaterialXDocument).
//
// Introduces (SWIFT): `Thread` with a stack size; `NSCondition` (a lock
// with a condition variable); `DispatchQueue.main.async`.

import Foundation
import MXBridge
import MXKit
import PythonBridge

/// A script started with `Python.start`, running or ended.
///
/// SWIFT: `@MainActor`: made, stopped and ended on the main thread; only
/// its Channel is shared with the worker.
@MainActor
public final class ScriptRun {
    /// The run in progress, if any: one at a time, in the whole app, as
    /// Python's `margolaria` module works on one document at a time.
    public private(set) static var current: ScriptRun? = nil

    /// What is running. Kept here also to keep its Console's namespace
    /// until it ends.
    public let script: Script

    /// What is running, for the sheet: "brick.py", "Console".
    public var name: String {
        script.name
    }

    /// True until the script has ended and `finished` has been called.
    public private(set) var isRunning: Bool = true

    /// True once `stop()` was called.
    public private(set) var isStopping: Bool = false

    private let channel: Channel

    /// This run's number for PythonBridge, larger than every earlier run's.
    private let id: Int64

    /// The last run's number.
    private(set) static var lastID: Int64 = 0

    /// Called once, on the main thread, when the run ends.
    private var finished: ((pybridge.RunResult) -> Void)?

    /// Starts `script` on a worker thread (see `Python.start`).
    init(script: Script, document: MXDocument, calls: HostCalls, finished: @escaping (pybridge.RunResult) -> Void) {
        self.script = script
        self.finished = finished
        Self.lastID += 1
        id = Self.lastID
        channel = Channel(answer: { call in calls.answer(call) })
        Self.current = self
        // SWIFT: `[weak self]`: the channel doesn't keep the run alive;
        // `current` does, until it ends.
        channel.ended = { [weak self] in
            self?.end()
        }

        // SWIFT: The thread's closure is `@Sendable`: it may only capture
        // values that are safe on another thread. A C++ value type such as
        // `mxbridge.Document` isn't marked so, nor is the channel's pointer
        // to `calls`: they go through a struct marked `@unchecked
        // Sendable`, which tells the compiler we have made sure. Here we
        // have: the main thread doesn't touch the document, nor `calls`'
        // object (outside `pump`), until the run ends.
        let work = Work(code: std.string(script.code), filename: std.string(script.filename),
                        stepName: std.string(script.stepName), console: script.console?.id ?? 0, id: id,
                        document: document.handle, channel: channel)
        let thread = Thread {
            let result: pybridge.RunResult = pybridge.Interpreter.run(work.code, work.filename, work.stepName,
                                                                      work.console, work.id, work.document,
                                                                      Channel.function, work.channel.context)
            work.channel.finish(result)
        }
        // SWIFT: A `Thread` (NSThread) is a real thread of its own, rather
        // than a task on a shared pool, as Python expects: a script may
        // wait or block. Its stack is 8 MB, as the main thread's is:
        // other threads get 512 KB by default, which deep Python recursion
        // (or MaterialX's) would overflow, crashing the app.
        thread.name = "Python: \(script.name)"
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// Waits up to `timeout` seconds (`.infinity`: until it ends) for the
    /// script to end, answering its calls meanwhile. True if it ended (and
    /// `finished` was called).
    func wait(upTo timeout: TimeInterval) -> Bool {
        let deadline: Date = timeout.isFinite ? Date.now.addingTimeInterval(timeout) : .distantFuture
        if channel.pump(until: deadline) {
            end()
        }
        return !isRunning
    }

    /// Stops the script: raises KeyboardInterrupt in it. It ends at its
    /// next line of Python, with its changes taken back.
    public func stop() {
        guard isRunning, !isStopping else {
            return
        }
        isStopping = true
        pybridge.Interpreter.interrupt(id)
    }

    /// The script has ended (the channel has its result): hands it on,
    /// once. Called from `wait`, or from the main queue later.
    private func end() {
        guard isRunning, let result = channel.result else {
            return
        }
        isRunning = false
        if Self.current === self {
            Self.current = nil
        }
        let finished = self.finished
        self.finished = nil
        finished?(result)
    }
}

/// What the worker thread needs: the run's arguments, and the channel.
private struct Work: @unchecked Sendable {
    let code: std.string
    let filename: std.string
    let stepName: std.string
    let console: Int32
    let id: Int64
    let document: mxbridge.Document
    let channel: Channel
}

/// Between the worker thread and the main thread: the script's call
/// waiting for an answer, and the run's result once it ends.
///
/// SWIFT: `@unchecked Sendable`: used from both threads, which the
/// compiler can't check; `condition` guards every `var` below, which is
/// what makes that safe. `NSCondition` is a lock with a condition
/// variable, like a `pthread_mutex_t` with a `pthread_cond_t`: `wait`
/// unlocks, sleeps until `broadcast`, and locks again.
final class Channel: @unchecked Sendable {
    private let condition = NSCondition()
    /// The call the worker is waiting on an answer for.
    private var call: UnsafeMutablePointer<pybridge.HostCall>? = nil
    private var answered: Bool = false
    /// The run's result, once it has ended.
    private var finalResult: pybridge.RunResult? = nil

    /// Answers a call, on the main thread (HostCalls.answer).
    private let answer: @MainActor (UnsafeMutablePointer<pybridge.HostCall>) -> Void

    /// Called on the main thread once the result has arrived.
    @MainActor var ended: (() -> Void)? = nil

    init(answer: @escaping @MainActor (UnsafeMutablePointer<pybridge.HostCall>) -> Void) {
        self.answer = answer
    }

    /// This object as the bridge's `void *` context, for `function`.
    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// The run's result, once it has ended; nil before.
    var result: pybridge.RunResult? {
        condition.lock()
        defer { condition.unlock() }
        return finalResult
    }

    /// The C function pointer PythonBridge calls, on the worker thread:
    /// finds the channel in `context`, and asks the main thread.
    ///
    /// SWIFT: `pybridge.HostFunction` is the C++ `void (*)(void*,
    /// HostCall*)`, which Swift sees as a `@convention(c)` function type.
    /// A closure can become one only if it captures nothing (a C function
    /// pointer has nowhere to keep captured values), so the channel comes
    /// in through `context`. `Unmanaged` converts between an object and a
    /// raw pointer without changing its reference count, like an ObjC
    /// `(__bridge void *)` cast: the ScriptRun keeps the channel alive.
    static let function: pybridge.HostFunction = { context, call in
        guard let context, let call else {
            return
        }
        Unmanaged<Channel>.fromOpaque(context).takeUnretainedValue().ask(call)
    }

    /// On the worker: hands `call` to the main thread, and waits until it
    /// has been answered.
    private func ask(_ call: UnsafeMutablePointer<pybridge.HostCall>) {
        condition.lock()
        self.call = call
        answered = false
        condition.broadcast()
        condition.unlock()
        // If the main thread is waiting in `pump`, it answers; if it's back
        // in the run loop, this block does.
        //
        // SWIFT: `DispatchQueue.main.async` runs the block on the main
        // thread, soon; `MainActor.assumeIsolated` tells the compiler it
        // is there (and checks it).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = self.pump(until: .distantPast)
            }
        }
        condition.lock()
        while !answered {
            condition.wait()
        }
        condition.unlock()
    }

    /// On the worker: the run has ended.
    fileprivate func finish(_ result: pybridge.RunResult) {
        condition.lock()
        finalResult = result
        condition.broadcast()
        condition.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.ended?()
            }
        }
    }

    /// On the main thread: answers the script's calls until it ends, or
    /// until `deadline` (`.distantPast`: only the call waiting now, if
    /// any). True if it has ended.
    @MainActor
    fileprivate func pump(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while finalResult == nil {
            if let call {
                self.call = nil
                // Not holding the lock while answering: the answer may take
                // a while (an export), and the worker only waits for it.
                condition.unlock()
                answer(call)
                condition.lock()
                answered = true
                condition.broadcast()
            } else if !condition.wait(until: deadline) {
                // The deadline passed.
                break
            }
        }
        return finalResult != nil
    }
}
