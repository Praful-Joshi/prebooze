import Foundation

/// Run a CPU-bound transform over items on all performance cores, keeping order.
public enum ParallelMap {
    public static func run<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let r = transform(items[i])
            lock.lock()
            results[i] = r
            lock.unlock()
        }
        return results.map { $0! }
    }
}
