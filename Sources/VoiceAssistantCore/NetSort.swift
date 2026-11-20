/// `List<T>.Sort(Comparison<T>)`: .NET's introspective sort (dotnet/runtime `ArraySortHelper<T>`), so that items the
/// comparison calls equal, and items it orders inconsistently (reading order isn't transitive), come out in the same
/// order as in C#. Swift's `sort` is another algorithm and orders such items differently.
enum NetSort {
    /// Sorts `items` in place. `compare` returns a negative number, zero or a positive number, as C#'s comparisons do.
    static func sort<T>(_ items: inout [T], by compare: (T, T) -> Int) {
        if items.count > 1 {
            let log2 = Int.bitWidth - 1 - items.count.leadingZeroBitCount
            introSort(&items, 0, items.count, 2 * (log2 + 1), compare)
        }
    }

    private static let sizeThreshold = 16

    /// Sorts `count` items from `lo`.
    private static func introSort<T>(
        _ keys: inout [T],
        _ lo: Int,
        _ count: Int,
        _ depth: Int,
        _ compare: (T, T) -> Int
    ) {
        var size = count
        var depth = depth
        while size > 1 {
            if size <= sizeThreshold {
                if size == 2 {
                    swapIfGreater(&keys, compare, lo, lo + 1)
                    return
                }

                if size == 3 {
                    swapIfGreater(&keys, compare, lo, lo + 1)
                    swapIfGreater(&keys, compare, lo, lo + 2)
                    swapIfGreater(&keys, compare, lo + 1, lo + 2)
                    return
                }

                insertionSort(&keys, lo, size, compare)
                return
            }

            if depth == 0 {
                heapSort(&keys, lo, size, compare)
                return
            }

            depth -= 1
            let p = pickPivotAndPartition(&keys, lo, size, compare)
            introSort(&keys, lo + p + 1, size - p - 1, depth, compare)
            size = p
        }
    }

    private static func swapIfGreater<T>(_ keys: inout [T], _ compare: (T, T) -> Int, _ i: Int, _ j: Int) {
        if compare(keys[i], keys[j]) > 0 {
            keys.swapAt(i, j)
        }
    }

    private static func pickPivotAndPartition<T>(
        _ keys: inout [T],
        _ lo: Int,
        _ count: Int,
        _ compare: (T, T) -> Int
    ) -> Int {
        let hi = count - 1
        let middle = hi >> 1

        // Median of three, which also partitions those three.
        swapIfGreater(&keys, compare, lo, lo + middle)
        swapIfGreater(&keys, compare, lo, lo + hi)
        swapIfGreater(&keys, compare, lo + middle, lo + hi)

        let pivot = keys[lo + middle]
        keys.swapAt(lo + middle, lo + hi - 1)
        var left = 0
        var right = hi - 1
        while left < right {
            // The scans make .NET's comparisons, in the same order: the pivot (now at hi - 1) stops the left one, and
            // the first item, no greater than it, the right one. The bounds only keep a comparison that orders those
            // the other way from running off the array, where .NET throws.
            repeat {
                left += 1
            } while left < hi && compare(keys[lo + left], pivot) < 0

            repeat {
                right -= 1
            } while right >= 0 && compare(pivot, keys[lo + right]) < 0

            if left >= right {
                break
            }

            keys.swapAt(lo + left, lo + right)
        }

        if left != hi - 1 {
            keys.swapAt(lo + left, lo + hi - 1)
        }

        return left
    }

    private static func heapSort<T>(_ keys: inout [T], _ lo: Int, _ count: Int, _ compare: (T, T) -> Int) {
        var i = count >> 1
        while i >= 1 {
            downHeap(&keys, lo, i, count, compare)
            i -= 1
        }

        var n = count
        while n > 1 {
            keys.swapAt(lo, lo + n - 1)
            downHeap(&keys, lo, 1, n - 1, compare)
            n -= 1
        }
    }

    private static func downHeap<T>(_ keys: inout [T], _ lo: Int, _ start: Int, _ n: Int, _ compare: (T, T) -> Int) {
        let d = keys[lo + start - 1]
        var i = start
        while i <= n >> 1 {
            var child = 2 * i
            if child < n && compare(keys[lo + child - 1], keys[lo + child]) < 0 {
                child += 1
            }

            if !(compare(d, keys[lo + child - 1]) < 0) {
                break
            }

            keys[lo + i - 1] = keys[lo + child - 1]
            i = child
        }

        keys[lo + i - 1] = d
    }

    private static func insertionSort<T>(_ keys: inout [T], _ lo: Int, _ count: Int, _ compare: (T, T) -> Int) {
        for i in 0..<(count - 1) {
            let t = keys[lo + i + 1]
            var j = i
            while j >= 0 && compare(t, keys[lo + j]) < 0 {
                keys[lo + j + 1] = keys[lo + j]
                j -= 1
            }

            keys[lo + j + 1] = t
        }
    }

    /// `Double.CompareTo`: NaN first, then by value.
    static func compare(_ a: Double, _ b: Double) -> Int {
        if a < b {
            return -1
        }

        if a > b {
            return 1
        }

        if a == b {
            return 0
        }

        return a.isNaN ? (b.isNaN ? 0 : -1) : 1
    }
}
