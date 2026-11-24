import Foundation

/// Follows one job until it ends: the web's job panel loop (03 §7.5, 07 §6 loop 3, 09 B8, api.js
/// `pollJob`).
///
/// - `GET /api/jobs/{id}` at once, then `interval` (3 s) after each answer; every answer is yielded.
/// - The stream finishes normally after yielding a job that is no longer `queued`/`running`
///   (`Job.isTerminal`). Reload the game, analysis, jobs and reports then (09 D1 #9).
/// - Retryable failures (network errors, 502–504, `retryable: true`) are retried after `interval`;
///   the stream throws the error after 5 failures in a row, or at once for a failure that is not
///   retryable (404 when the game was deleted, 401, 429 `AUTH_THROTTLED` …). Pass it through
///   `ServerSession.report(_:)` (lockout gate, 09 R6) and offer "Check again".
/// - Cancelling the consuming task (or dropping the stream) stops polling; the stream then just ends.
///
/// Poll only while the job is on screen and the app is active (09 R29).
nonisolated enum JobPoller {
    /// Consecutive failures after which polling gives up (api.js:120-135).
    static let maximumConsecutiveFailures = 5

    /// The job's states, `interval` apart, until it ends. The errors are `APIError`s.
    static func updates(
        jobID: String,
        client: APIClient,
        every interval: Duration = .seconds(3),
        sleeper: Sleeper = .live
    ) -> AsyncThrowingStream<Job, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await poll(jobID: jobID, client: client, interval: interval, sleeper: sleeper, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether a failed poll is tried again (api.js: `err.info.retryable`; network errors and 502–504
    /// count as retryable). Errors that stop every request (09 R6) never are.
    static func shouldRetry(_ error: APIError) -> Bool {
        !error.isCancellation && !error.stopsAllRequests && error.isRetryable
    }

    @concurrent
    private static func poll(
        jobID: String,
        client: APIClient,
        interval: Duration,
        sleeper: Sleeper,
        continuation: AsyncThrowingStream<Job, Error>.Continuation
    ) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let job = try await client.job(id: jobID)
                failures = 0
                continuation.yield(job)
                if job.isTerminal {
                    continuation.finish()
                    return
                }
            } catch {
                if error.isCancellation || Task.isCancelled {
                    continuation.finish()
                    return
                }
                failures += 1
                if !shouldRetry(error) || failures >= maximumConsecutiveFailures {
                    continuation.finish(throwing: error)
                    return
                }
            }
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                break
            }
        }
        continuation.finish()
    }
}
