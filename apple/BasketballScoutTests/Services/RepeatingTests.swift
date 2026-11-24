import Foundation
import Testing
@testable import BasketballScout

/// Polling loops (07 §6): run at once, then after each pause, until told to stop or cancelled.
@MainActor
struct RepeatingTests {
    @Test func runsUntilTheBodySaysStop() async {
        let sleeper = RecordingSleeper()
        var runs = 0
        await Repeating.every(.seconds(5), sleeper: sleeper.sleeper) {
            runs += 1
            return runs < 3
        }
        #expect(runs == 3)
        #expect(sleeper.recorded == [.seconds(5), .seconds(5)])
    }

    @Test func stopsWhenItsTaskIsCancelled() async {
        let sleeper = RecordingSleeper()
        let counter = ServiceCounter()
        let task = Task { @MainActor in
            await Repeating.every(.seconds(5), sleeper: sleeper.sleeper) {
                if counter.next() == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            }
        }
        await task.value
        #expect(counter.count == 3)
        #expect(sleeper.recorded.count == 2)
    }

    @Test func aCancelledTaskDoesNotRunAtAll() async {
        let counter = ServiceCounter()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await Repeating.every(.seconds(1), sleeper: RecordingSleeper().sleeper) {
                _ = counter.next()
                return true
            }
        }
        await task.value
        #expect(counter.count == 0)
    }
}
