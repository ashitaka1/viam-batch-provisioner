/// Waits until `condition` holds, checking every few milliseconds, for at most `seconds`.
@MainActor func poll(seconds: Double = 5, until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
