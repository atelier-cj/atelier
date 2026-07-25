package atelier.event

import std.collection.concurrent.*
import std.sync.*

enum StreamSignal<R> {
    | Value(R)
    | Error(Exception)
}

public class EventStream<T, R> {
    let eventQueue: LinkedBlockingQueue<T>
    let signalQueue: LinkedBlockingQueue<StreamSignal<R>>
    let closed: AtomicBool

    public init() {
        eventQueue = LinkedBlockingQueue<T>()
        signalQueue = LinkedBlockingQueue<StreamSignal<R>>(1)
        closed = AtomicBool(false)
    }

    public func emit(event: T): Bool {
        if (closed.load()) { return false }
        eventQueue.add(event)
        true
    }

    public func receive(): T {
        eventQueue.remove()
    }

    public func receive(timeout: Duration): Option<T> {
        eventQueue.remove(timeout)
    }

    public func setResult(r: R): Bool {
        signalQueue.tryAdd(StreamSignal.Value(r))
    }

    public func setError(e: Exception): Bool {
        signalQueue.tryAdd(StreamSignal.Error(e))
    }

    public func result(): R {
        let signal = signalQueue.remove()
        match (signal) {
            case Value(r) => r
            case Error(e) => throw e
        }
    }

    public func close() {
        closed.store(true)
    }
}
