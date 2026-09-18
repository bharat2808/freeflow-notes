import Foundation

enum PersistentWhisperWorkerTests {
    static func run() async throws {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/WhisperWorkerFixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelPath = directory.appendingPathComponent("synthetic-model").path
        let worker = PersistentWhisperWorker()
        defer { worker.shutdown() }
        let config = PersistentWhisperWorker.Configuration(
            executableURL: helper, modelPath: modelPath, language: "en"
        )
        func request(_ value: Float = 0, timeout: TimeInterval = 2) async throws -> String {
            try await worker.transcribe(samples: [value], configuration: config, timeout: timeout, startupTimeout: 2)
        }
        func expectRequest(_ expected: String) async throws {
            let result = try await request()
            TestSupport.expectEqual(result, expected)
        }
        try await expectRequest("synthetic-1")
        try await expectRequest("synthetic-2")
        // A process exit must not kill or poison the client.
        do { _ = try await request(9); fatalError("Expected helper failure") } catch {}
        try await expectRequest("synthetic-1")
        do { _ = try await request(7); fatalError("Expected malformed response failure") } catch {}
        try await expectRequest("synthetic-1")
        do { _ = try await request(8, timeout: 0.1); fatalError("Expected timeout") } catch {}
        try await expectRequest("synthetic-1")

        let slow = Task { try await request(6) }
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: modelPath + ".busy") {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        TestSupport.expect(FileManager.default.fileExists(atPath: modelPath + ".busy"), "Slow inference started")
        let queued = Task { try await request() }
        queued.cancel()
        do { _ = try await queued.value; fatalError("Expected queued cancellation") } catch is CancellationError {}
        slow.cancel()
        do { _ = try await slow.value; fatalError("Expected cancellation") } catch is CancellationError {}
        // Canceled inference may finish privately; a healthy model stays loaded.
        try await expectRequest("synthetic-3")

        let changed = PersistentWhisperWorker.Configuration(
            executableURL: helper, modelPath: "synthetic-other-model", language: "en"
        )
        let changedResult = try await worker.transcribe(samples: [0], configuration: changed, timeout: 2, startupTimeout: 2)
        TestSupport.expectEqual(changedResult, "synthetic-1")
        let hung = PersistentWhisperWorker.Configuration(
            executableURL: helper, modelPath: "startup-hang", language: nil
        )
        do {
            _ = try await worker.transcribe(samples: [0], configuration: hung, timeout: 2, startupTimeout: 0.1)
            fatalError("Expected startup timeout")
        } catch {}
        try await expectRequest("synthetic-1")
    }
}
