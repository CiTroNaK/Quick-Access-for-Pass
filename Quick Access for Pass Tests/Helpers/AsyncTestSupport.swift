@MainActor
final class TestCallCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// Yields until a main-actor test condition becomes true or the finite retry budget is exhausted.
@MainActor
func waitForTestCondition(
    maxYields: Int = 10_000,
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<maxYields {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
