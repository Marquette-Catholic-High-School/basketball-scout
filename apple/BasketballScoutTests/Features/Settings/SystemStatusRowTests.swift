import Foundation
import Testing
@testable import BasketballScout

/// The System status rows (07 §3.8; 02 §9.3): the web's labels, values and green/red rules, plus the two
/// health fields the web leaves out.
struct SystemStatusRowTests {
    private func rows(_ fixture: String, change: (inout HealthStatus) -> Void = { _ in }) throws -> [String: SystemStatusRow] {
        var health = try Fixture.decode(HealthStatus.self, fixture)
        change(&health)
        return Dictionary(uniqueKeysWithValues: SystemStatusRow.rows(for: health).map { ($0.label, $0) })
    }

    @Test func theRowsComeInTheWebsOrderThenTheOtherFields() throws {
        let health = try Fixture.decode(HealthStatus.self, "health.json")
        #expect(SystemStatusRow.rows(for: health).map(\.label) == [
            "Overall", "Version", "Video processor", "Job queue", "Modal (GPU)", "Claude reports", "Worker last seen", "ffmpeg",
            "Sign-in", "Largest film",
        ])
    }

    @Test func aHealthyDemoServer() throws {
        let rows = try rows("health.json")
        #expect(rows["Overall"] == SystemStatusRow(label: "Overall", value: "OK", tone: .success))
        #expect(rows["Version"] == SystemStatusRow(label: "Version", value: "0.1.0", tone: nil))
        #expect(rows["Video processor"]?.value == "mock")
        #expect(rows["Video processor"]?.tone == nil)
        #expect(rows["Job queue"] == SystemStatusRow(label: "Job queue", value: "sqlite OK", tone: .success))
        // Not the GPU processor: Modal does not matter, so it is green although not configured.
        #expect(rows["Modal (GPU)"] == SystemStatusRow(label: "Modal (GPU)", value: "Not configured", tone: .success))
        #expect(rows["Claude reports"] == SystemStatusRow(label: "Claude reports", value: "Not configured", tone: .danger))
        #expect(rows["Worker last seen"] == SystemStatusRow(label: "Worker last seen", value: "26 s ago", tone: .success))
        #expect(rows["ffmpeg"] == SystemStatusRow(label: "ffmpeg", value: "Missing", tone: .danger))
        #expect(rows["Sign-in"]?.value == "Password required")
        #expect(rows["Largest film"]?.value == "12.0 GB")
    }

    @Test func aServerThatNeedsAttention() throws {
        let rows = try rows("health_degraded.json") {
            $0.processor = "modal"
            $0.queueOK = false
            $0.queueBackend = "redis"
        }
        #expect(rows["Overall"] == SystemStatusRow(label: "Overall", value: "Needs attention", tone: .danger))
        #expect(rows["Job queue"] == SystemStatusRow(label: "Job queue", value: "redis down", tone: .danger))
        #expect(rows["Modal (GPU)"]?.tone == .danger)
        #expect(rows["Worker last seen"] == SystemStatusRow(label: "Worker last seen", value: "2 min ago", tone: .danger))
    }

    @Test func aWorkerNeverSeen() throws {
        let rows = try rows("health.json") {
            $0.workerLastSeenS = nil
            $0.authEnabled = false
            $0.maxUploadBytes = nil
        }
        #expect(rows["Worker last seen"] == SystemStatusRow(label: "Worker last seen", value: "never", tone: .danger))
        #expect(rows["Sign-in"]?.value == "Off (no password)")
        #expect(rows["Largest film"]?.value == "–")
    }

    @Test func theOneLineSummary() throws {
        #expect(SystemStatusRow.overall(for: nil) == "–")
        #expect(SystemStatusRow.overall(for: try Fixture.decode(HealthStatus.self, "health.json")) == "OK")
        #expect(SystemStatusRow.overall(for: try Fixture.decode(HealthStatus.self, "health_degraded.json")) == "Needs attention")
    }
}
