import Foundation
import Synchronization
import Testing
@testable import BasketballScout

/// The job panel's polling (03 §7.5, 07 §6 loop 3, 09 B8): every 3 s, retryable failures retried, give up
/// after 5 in a row or the first non-retryable, finish after a terminal job.
nonisolated struct JobPollerTests {
    /// Answers each request with the next response (the last one repeats).
    private func server(_ responses: [StubResponse]) -> StubServer {
        let counter = ServiceCounter()
        return StubServer { _ in responses[min(counter.next(), responses.count - 1)] }
    }

    @Test func followsAJobUntilItEnds() async throws {
        let server = server([
            .fixture("job_analyze_1_running_gpu_processing.json"),
            .fixture("job_analyze_2_running_downloading_results.json"),
            .fixture("job_analyze_4_succeeded_done.json"),
            .fixture("job_get.json"),
        ])
        let client = try TestServer.client(for: server)
        let sleeper = RecordingSleeper()
        var statuses: [JobStatus] = []
        for try await job in JobPoller.updates(jobID: "j_ffaf913e4144", client: client, sleeper: sleeper.sleeper) {
            statuses.append(job.status)
        }
        #expect(statuses == [.running, .running, .succeeded])
        #expect(sleeper.recorded == [.seconds(3), .seconds(3)])
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.path == "/api/jobs/j_ffaf913e4144" })
        #expect(server.requests.allSatisfy { $0.header("Authorization") == TestServer.expectedAuthorization })
    }

    @Test func theIntervalCanBeChanged() async throws {
        let server = server([.fixture("job_analyze_1_running_gpu_processing.json"), .fixture("job_analyze_4_succeeded_done.json")])
        let sleeper = RecordingSleeper()
        let stream = JobPoller.updates(jobID: "j_ffaf913e4144", client: try TestServer.client(for: server), every: .seconds(5), sleeper: sleeper.sleeper)
        for try await _ in stream {}
        #expect(sleeper.recorded == [.seconds(5)])
    }

    @Test func retryableFailuresAreRetriedAndTheCountResets() async throws {
        let gateway = StubResponse.text(502, "<html>502 Bad Gateway</html>")
        let server = server([
            gateway, gateway, gateway, gateway,
            .fixture("job_analyze_1_running_gpu_processing.json"),
            gateway, gateway, gateway, gateway,
            .fixture("job_analyze_4_succeeded_done.json"),
        ])
        let sleeper = RecordingSleeper()
        var jobs: [Job] = []
        for try await job in JobPoller.updates(jobID: "j_ffaf913e4144", client: try TestServer.client(for: server), sleeper: sleeper.sleeper) {
            jobs.append(job)
        }
        #expect(jobs.map(\.status) == [.running, .succeeded])
        #expect(server.requests.count == 10)
        #expect(sleeper.recorded.count == 9)
    }

    @Test func givesUpAfterFiveFailuresInARow() async throws {
        let server = StubServer(always: .failure(URLError(.notConnectedToInternet)))
        let sleeper = RecordingSleeper()
        let stream = JobPoller.updates(jobID: "j_ffaf913e4144", client: try TestServer.client(for: server), sleeper: sleeper.sleeper)
        let error = await #expect(throws: APIError.self) {
            for try await _ in stream {}
        }
        #expect(error?.urlError?.code == .notConnectedToInternet)
        #expect(server.requests.count == 5)
        #expect(sleeper.recorded == Array(repeating: .seconds(3), count: 4))
    }

    @Test func aFailureThatIsNotRetryableEndsAtOnce() async throws {
        let server = StubServer(always: .fixture("err_404_job_unknown.json", status: 404))
        let stream = JobPoller.updates(jobID: "j_000000000000", client: try TestServer.client(for: server), sleeper: RecordingSleeper().sleeper)
        let error = await #expect(throws: APIError.self) {
            for try await _ in stream {}
        }
        #expect(error?.code == "NOT_FOUND")
        #expect(server.requests.count == 1)
    }

    /// 09 R6: a 401 is never retried (each retry with a wrong password counts toward the lockout).
    @Test func aRejectedPasswordIsNeverRetried() async throws {
        let server = StubServer(always: .fixture(
            "err_401_wrong_password.json", status: 401, headers: ["WWW-Authenticate": #"Basic realm="Basketball Scout""#]))
        let stream = JobPoller.updates(jobID: "j_ffaf913e4144", client: try TestServer.client(for: server), sleeper: RecordingSleeper().sleeper)
        let error = await #expect(throws: APIError.self) {
            for try await _ in stream {}
        }
        #expect(error?.isAuthFailure == true)
        #expect(server.requests.count == 1)
        #expect(!JobPoller.shouldRetry(.unauthorized(nil)))
        #expect(!JobPoller.shouldRetry(.throttled(retryAfter: 300, info: nil)))
        #expect(!JobPoller.shouldRetry(.cancelled))
        #expect(JobPoller.shouldRetry(.notJSON(status: 504)))
    }

    @Test func droppingTheStreamStopsPolling() async throws {
        let server = StubServer(always: .fixture("job_analyze_1_running_gpu_processing.json"))
        let sleeper = BlockingSleeper()
        let client = try TestServer.client(for: server)
        // The stream is not kept: leaving the loop releases it, which ends the polling task.
        for try await job in JobPoller.updates(jobID: "j_ffaf913e4144", client: client, sleeper: sleeper.sleeper) {
            #expect(job.status == .running)
            break
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while !sleeper.wasCancelled, clock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(sleeper.wasCancelled)
        #expect(server.requests.count == 1)
    }
}

/// A sleeper that waits until its task is cancelled, and records that.
nonisolated final class BlockingSleeper: Sendable {
    private let cancelled = Mutex(false)

    var wasCancelled: Bool { cancelled.withLock { $0 } }

    var sleeper: Sleeper {
        Sleeper { [self] _ in
            do {
                while true { try await Task.sleep(for: .seconds(60)) }
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
        }
    }
}
