import XCTest
@testable import VoiceAssistantCore

/// Reading order is .NET's `List<T>.Sort`, an introspective sort that isn't stable, with a comparison that isn't
/// transitive (rows are grouped within half an element's height). Swift's `sort` orders such lists differently: in C#,
/// 1,220 of 2,000 generated lists come out differently from a stable sort. These lists (from the harness, `misc`) sort
/// as in C#: up to 16 items by insertion sort, more by quicksort partitions.
final class ReadingOrderTests: XCTestCase {
    private func order(_ rects: [(Double, Double, Double, Double)]) -> [Int] {
        let elements = rects.enumerated().map { i, r in
            UiElement(id: i + 1, name: "x", role: .button, rect: rect(r.0, r.1, r.2, r.3))
        }

        return TargetResolver.sortReadingOrder(elements).map { $0.id }
    }

    func testSmallListsSortAsInDotNet() {
        XCTAssertEqual([2, 1, 3], order([(452, 41, 120, 42), (601, 3, 120, 6), (602, 121, 320, 6)]))
        let sixteen: [(Double, Double, Double, Double)] = [
            (1050, 41, 220, 6), (2, 204, 220, 42), (151, 123, 20, 18), (750, 2, 320, 42), (601, 201, 120, 18),
            (600, 203, 220, 18), (750, 163, 120, 0), (450, 3, 220, 0), (900, 1, 320, 18), (301, 80, 220, 6),
            (451, 123, 320, 30), (1050, 1, 320, 30), (301, 81, 320, 6), (301, 160, 320, 30), (1050, 200, 120, 0),
            (902, 82, 220, 0),
        ]
        XCTAssertEqual([8, 4, 9, 12, 1, 10, 13, 16, 3, 11, 14, 7, 2, 6, 5, 15], order(sixteen))
    }

    func testLargerListsSortAsInDotNet() {
        let seventeen: [(Double, Double, Double, Double)] = [
            (602, 40, 320, 0), (302, 200, 20, 42), (0, 0, 320, 6), (2, 203, 20, 18), (452, 124, 320, 30),
            (750, 2, 320, 30), (602, 161, 20, 0), (450, 123, 220, 30), (1051, 202, 320, 30), (900, 80, 20, 6),
            (302, 3, 20, 18), (600, 42, 20, 0), (1050, 4, 120, 0), (1052, 1, 220, 6), (152, 121, 220, 0),
            (752, 0, 220, 18), (0, 81, 220, 0),
        ]
        XCTAssertEqual([3, 11, 6, 16, 13, 14, 12, 1, 17, 10, 15, 8, 5, 7, 4, 2, 9], order(seventeen))

        let twentyFour: [(Double, Double, Double, Double)] = [
            (902, 162, 20, 42), (1051, 81, 320, 6), (1, 124, 20, 18), (300, 201, 220, 42), (152, 83, 220, 30),
            (301, 42, 220, 6), (301, 161, 320, 18), (451, 81, 20, 30), (602, 42, 220, 42), (752, 121, 20, 42),
            (1, 81, 320, 6), (600, 202, 20, 30), (152, 81, 320, 0), (752, 200, 20, 18), (601, 0, 320, 0),
            (751, 44, 320, 18), (450, 81, 320, 18), (151, 200, 320, 0), (450, 42, 120, 42), (1, 201, 320, 6),
            (900, 200, 120, 30), (752, 82, 20, 18), (0, 164, 20, 30), (600, 162, 220, 18),
        ]
        XCTAssertEqual(
            [15, 6, 19, 9, 16, 11, 13, 5, 17, 8, 22, 2, 3, 10, 23, 7, 24, 1, 20, 18, 4, 12, 14, 21], order(twentyFour))

        let forty: [(Double, Double, Double, Double)] = [
            (1050, 42, 120, 30), (1, 203, 320, 42), (302, 201, 320, 42), (600, 83, 320, 6), (1050, 124, 120, 30),
            (600, 4, 20, 6), (452, 1, 20, 18), (302, 44, 20, 18), (1052, 162, 320, 6), (301, 202, 120, 0),
            (902, 202, 220, 42), (1, 42, 320, 42), (751, 80, 120, 18), (601, 42, 20, 42), (151, 43, 220, 18),
            (602, 121, 220, 18), (601, 83, 120, 18), (900, 160, 120, 6), (452, 1, 20, 42), (2, 160, 320, 6),
            (752, 163, 220, 6), (902, 164, 320, 18), (301, 121, 320, 0), (0, 124, 120, 18), (451, 123, 120, 18),
            (0, 201, 320, 6), (602, 82, 120, 18), (751, 3, 320, 6), (600, 202, 20, 30), (150, 2, 320, 18),
            (1, 41, 20, 30), (300, 80, 20, 42), (301, 202, 220, 30), (152, 203, 20, 18), (600, 201, 20, 0),
            (602, 201, 220, 30), (152, 121, 20, 30), (1051, 40, 120, 0), (902, 121, 220, 18), (2, 202, 320, 42),
        ]
        XCTAssertEqual(
            [
                30, 19, 7, 6, 28, 12, 31, 15, 8, 14, 1, 38, 32, 4, 17, 27, 13, 24, 37, 23, 25, 16, 39, 5, 20, 21, 18,
                22, 9, 26, 2, 40, 34, 10, 33, 3, 29, 35, 36, 11,
            ],
            order(forty))
    }

    func testSixtyItemsSortAsInDotNet() {
        let sixty: [(Double, Double, Double, Double)] = [
            (151, 162, 320, 42), (300, 42, 220, 42), (602, 204, 320, 0), (302, 43, 220, 42), (451, 1, 220, 0),
            (901, 84, 220, 6), (151, 161, 220, 18), (451, 160, 220, 42), (451, 40, 320, 0), (300, 200, 20, 30),
            (901, 40, 20, 42), (902, 204, 320, 18), (600, 164, 220, 18), (450, 44, 320, 30), (1051, 120, 220, 30),
            (0, 164, 320, 6), (451, 40, 320, 30), (150, 42, 20, 18), (302, 41, 120, 0), (1051, 83, 20, 42),
            (602, 0, 320, 18), (1051, 203, 320, 42), (751, 83, 220, 0), (2, 42, 120, 30), (0, 2, 20, 42),
            (151, 0, 220, 42), (452, 2, 120, 6), (150, 200, 220, 42), (901, 123, 120, 0), (152, 81, 220, 30),
            (900, 41, 20, 0), (1, 200, 320, 18), (602, 200, 220, 42), (1, 162, 120, 0), (152, 121, 320, 42),
            (151, 204, 220, 18), (450, 202, 220, 42), (600, 2, 220, 30), (751, 123, 20, 0), (1050, 3, 120, 0),
            (0, 0, 20, 30), (1051, 202, 120, 30), (151, 122, 320, 0), (750, 124, 120, 0), (602, 81, 20, 0),
            (151, 163, 220, 0), (1052, 1, 120, 42), (2, 124, 120, 30), (1050, 84, 320, 0), (902, 204, 120, 0),
            (901, 42, 320, 6), (451, 200, 120, 30), (0, 80, 320, 0), (601, 44, 20, 42), (450, 200, 20, 6),
            (1051, 161, 220, 18), (152, 0, 20, 6), (1, 124, 320, 30), (150, 42, 320, 30), (151, 204, 120, 30),
        ]
        XCTAssertEqual(
            [
                41, 25, 26, 57, 5, 27, 38, 21, 40, 47, 24, 59, 18, 2, 19, 4, 14, 9, 17, 54, 31, 11, 51, 53, 30, 45,
                23, 6, 49, 20, 58, 48, 43, 35, 44, 39, 29, 15, 16, 34, 46, 1, 7, 8, 13, 56, 32, 28, 60, 36, 10, 55, 37,
                52, 33, 3, 50, 12, 42, 22,
            ],
            order(sixty))
    }

    func testTheSortMakesDotNetsComparisonsInDotNetsOrder() {
        // McIlroy's adversary decides the order as the sort asks, so that partitions are as uneven as they can be:
        // quicksort reaches its depth limit and heapsort finishes. Its answers depend on every comparison made, in
        // order, so any other sequence gives other counts and orders. (n, comparisons, hash of the order) from C#.
        let expected: [(Int, Int, String)] = [
            (5, 4, "a176050b82dc499b"), (16, 15, "863ce1cd59ee0d75"), (17, 33, "86688f647d5be7bc"),
            (40, 387, "b35665cf32a09ecb"), (200, 4822, "8c26595b46dff899"), (1000, 34864, "6940dc8d0ec54ffd"),
        ]
        for (n, comparisons, hash) in expected {
            let gas = n - 1
            var value = [Int](repeating: gas, count: n)
            var solid = 0
            var candidate = 0
            var made = 0
            var items = Array(0..<n)
            NetSort.sort(&items) { x, y in
                made += 1
                if value[x] == gas && value[y] == gas {
                    if x == candidate {
                        value[x] = solid
                    } else {
                        value[y] = solid
                    }

                    solid += 1
                }

                if value[x] == gas {
                    candidate = x
                } else if value[y] == gas {
                    candidate = y
                }

                return value[x] - value[y]
            }

            XCTAssertEqual(comparisons, made, "\(n)")
            XCTAssertEqual(hash, Serialized.hash(items.map { String($0) }.joined(separator: ",")), "\(n)")
        }
    }
}
