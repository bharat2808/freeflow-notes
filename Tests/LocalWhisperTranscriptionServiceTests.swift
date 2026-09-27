import Foundation

enum LocalWhisperTranscriptionServiceTests {
    private final class PreviewTestState: @unchecked Sendable {
        private let lock = NSLock()
        private var transcriptionCount = 0
        private var updates = [String]()
        private var sampleByteCounts = [Int]()

        func nextTranscript(sampleByteCount: Int) -> String {
            lock.withLock {
                transcriptionCount += 1
                sampleByteCounts.append(sampleByteCount)
                return (1...transcriptionCount).map { "chunk \($0)" }.joined(separator: " ")
            }
        }

        func record(_ transcript: String) {
            lock.withLock {
                updates.append(transcript)
            }
        }

        var updateCount: Int {
            lock.withLock { updates.count }
        }

        var recordedUpdates: [String] {
            lock.withLock { updates }
        }

        var recordedSampleByteCounts: [Int] {
            lock.withLock { sampleByteCounts }
        }
    }

    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?

        Task {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let executable = directory.appendingPathComponent("mock-whisper")
                try "#!/bin/sh\necho '[00:00:00.000 --> 00:00:01.000] hello from local whisper'\n".write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                let model = directory.appendingPathComponent("model.bin")
                let audio = directory.appendingPathComponent("audio.wav")
                try Data().write(to: model)
                try Data().write(to: audio)

                let service = try LocalWhisperTranscriptionService(
                    executablePath: executable.path,
                    modelPath: model.path,
                    timeoutSeconds: 5,
                    helperExecutableURL: nil
                )
                let transcript = try await service.transcribe(fileURL: audio)
                TestSupport.expectEqual(transcript, "hello from local whisper")

                let pcm = Data(repeating: 0, count: 8)
                let wav = LocalWhisperTranscriptionService.makeWAVData(pcm16: pcm, sampleRate: 24_000)
                TestSupport.expectEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
                TestSupport.expectEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
                TestSupport.expectEqual(wav.count, 44 + pcm.count)
                let previewTranscript = try await service.transcribePCM16(pcm, sampleRate: 24_000)
                TestSupport.expectEqual(previewTranscript, "hello from local whisper")

                // The recorder emits 16 kHz PCM. This must still transcribe via
                // the CLI when the in-process session is unavailable.
                let recordingPreview = try await service.transcribePCM16(pcm)
                TestSupport.expectEqual(recordingPreview, "hello from local whisper")

                try await verifyServicesShareWarmHelper(directory: directory, executable: executable, model: model)
                try await PersistentWhisperWorkerTests.run()
                try await verifyPreviewContinuesAcrossChunks()
                try await verifyQuietRecordingStillPreviews()
                try await verifyRejectedWindowKeepsItsAudio()
                verifyPreviewSpeechGateSkipsOnlyPauses()

            } catch {
                failure = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let failure { fatalError("Local Whisper test failed: \(failure)") }
    }

    private static func verifyServicesShareWarmHelper(directory: URL, executable: URL, model: URL) async throws {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/WhisperWorkerFixture")
        let worker = PersistentWhisperWorker()
        defer { worker.shutdown() }
        let preview = try LocalWhisperTranscriptionService(
            executablePath: executable.path, modelPath: model.path,
            helperExecutableURL: helper, worker: worker
        )
        let pcm = Data(repeating: 0, count: 16_000 * 2)
        let first = try await preview.transcribePCM16(pcm)
        TestSupport.expectEqual(first, "synthetic-1")

        let recording = directory.appendingPathComponent("synthetic-recording.wav")
        try LocalWhisperTranscriptionService.makeWAVData(pcm16: pcm, sampleRate: 16_000).write(to: recording)
        let final = try LocalWhisperTranscriptionService(
            executablePath: executable.path, modelPath: model.path,
            helperExecutableURL: helper, worker: worker
        )
        let second = try await final.transcribe(fileURL: recording)
        TestSupport.expectEqual(second, "synthetic-2")
        let nextRecording = try await preview.transcribePCM16(pcm)
        TestSupport.expectEqual(nextRecording, "synthetic-3")

        let unsupported = directory.appendingPathComponent("unsupported-model.bin")
        try Data().write(to: unsupported)
        let fallback = try LocalWhisperTranscriptionService(
            executablePath: executable.path, modelPath: unsupported.path,
            helperExecutableURL: helper, worker: worker
        )
        let fallbackPreview = try await fallback.transcribePCM16(pcm)
        TestSupport.expectEqual(fallbackPreview, "hello from local whisper")
        let fallbackFinal = try await fallback.transcribe(fileURL: recording)
        TestSupport.expectEqual(fallbackFinal, "hello from local whisper")

    }

    private static func verifyPreviewContinuesAcrossChunks() async throws {
        let state = PreviewTestState()
        let session = LocalWhisperPreviewSession(
            transcribe: { samples, sampleRate in
                TestSupport.expectEqual(sampleRate, 16_000)
                return state.nextTranscript(sampleByteCount: samples.count)
            },
            onUpdate: { transcript in
                state.record(transcript)
            }
        )

        var sample: Int16 = 8_000
        let chunk = Data(bytes: &sample, count: MemoryLayout<Int16>.size)
        let threeSeconds = Data(repeating: chunk[0], count: 16_000 * 3 * MemoryLayout<Int16>.size)
        session.appendPCM16(threeSeconds)

        for _ in 0..<200 where state.updateCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.appendPCM16(threeSeconds)

        for _ in 0..<200 where state.updateCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let twentyOneSeconds = Data(
            repeating: chunk[0],
            count: 16_000 * 21 * MemoryLayout<Int16>.size
        )
        session.appendPCM16(twentyOneSeconds)

        for _ in 0..<200 where state.updateCount < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.stop()
        TestSupport.expectEqual(
            state.recordedUpdates,
            ["chunk 1", "chunk 1 chunk 2", "chunk 1 chunk 2 chunk 3"]
        )
        TestSupport.expectEqual(
            state.recordedSampleByteCounts,
            [
                threeSeconds.count,
                threeSeconds.count * 2,
                16_000 * 20 * MemoryLayout<Int16>.size,
            ]
        )
    }

    /// Regression: a quiet recording must still produce live preview text.
    ///
    /// Low-gain microphones deliver speech at window levels that sit just under
    /// the previous absolute gate (rms 0.008 / peak 0.04), so the preview
    /// silently produced nothing at all while the final transcript — which has
    /// no gate — came out fine.
    private static func verifyQuietRecordingStillPreviews() async throws {
        let state = PreviewTestState()
        let session = LocalWhisperPreviewSession(
            transcribe: { samples, sampleRate in
                TestSupport.expectEqual(sampleRate, 16_000)
                return state.nextTranscript(sampleByteCount: samples.count)
            },
            onUpdate: { transcript in
                state.record(transcript)
            }
        )

        // Six seconds with a single short burst: peak 0.038, window rms 0.008.
        // These are the levels measured from a real quiet recording.
        let fixture = quietBurstData(frames: 16_000 * 6, burstFrames: 4_000, peak: 0.0377)
        let levels = fixtureLevels(fixture)
        TestSupport.expect(levels.peak < 0.04, "fixture must stay under the old peak gate")
        TestSupport.expect(levels.rms < 0.008, "fixture must stay under the old rms gate")

        session.appendPCM16(fixture)
        for _ in 0..<300 where state.updateCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.stop()

        TestSupport.expectEqual(state.updateCount, 1)
    }

    /// Regression: a rejected silent window must not forfeit its whole chunk.
    ///
    /// The session used to clear its pending budget as soon as it handed a
    /// window to the gate, so a recording that started with quiet audio waited
    /// another full chunk before its next chance and a short note produced no
    /// preview text at all.
    private static func verifyRejectedWindowKeepsItsAudio() async throws {
        let state = PreviewTestState()
        let session = LocalWhisperPreviewSession(
            transcribe: { samples, sampleRate in
                TestSupport.expectEqual(sampleRate, 16_000)
                return state.nextTranscript(sampleByteCount: samples.count)
            },
            onUpdate: { transcript in
                state.record(transcript)
            }
        )

        // Three seconds of digital silence, then 1.2 s of quiet speech.
        let silence = Data(repeating: 0, count: 16_000 * 3 * MemoryLayout<Int16>.size)
        let speech = quietBurstData(frames: 19_200, burstFrames: 1_600, peak: 0.0377)
        session.appendPCM16(silence)
        for _ in 0..<100 where state.updateCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        TestSupport.expectEqual(state.updateCount, 0)

        session.appendPCM16(speech)
        for _ in 0..<200 where state.updateCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.stop()

        // Only ~1 s of new audio has arrived, so this needs the rejected
        // window's audio to stay counted toward the next attempt.
        TestSupport.expectEqual(state.updateCount, 1)
    }

    /// The gate lowers the speech floor without giving up pause skipping: a
    /// window far below the loudest window of this recording is a pause, while
    /// a quiet first window is speech.
    private static func verifyPreviewSpeechGateSkipsOnlyPauses() {
        var silence = PreviewSpeechGate()
        TestSupport.expectEqual(silence.containsSpeech(rms: 0, peak: 0), false)
        TestSupport.expectEqual(silence.containsSpeech(rms: 0.0004, peak: 0.002), false)

        // Levels measured from a real low-gain recording: both sat just under
        // the previous absolute gate (rms 0.008 / peak 0.04).
        var quiet = PreviewSpeechGate()
        TestSupport.expectEqual(quiet.containsSpeech(rms: 0.00701, peak: 0.0377), true)
        TestSupport.expectEqual(quiet.containsSpeech(rms: 0.01387, peak: 0.0609), true)

        // Speech at 3% of full scale is quiet but audible.
        var lowGain = PreviewSpeechGate()
        TestSupport.expectEqual(lowGain.containsSpeech(rms: 0.00346, peak: 0.0201), true)

        // After a loud window, a pause and then normal speech.
        var loud = PreviewSpeechGate()
        TestSupport.expectEqual(loud.containsSpeech(rms: 0.09, peak: 0.6), true)
        TestSupport.expectEqual(loud.containsSpeech(rms: 0.002, peak: 0.02), false)
        TestSupport.expectEqual(loud.containsSpeech(rms: 0.02, peak: 0.15), true)
    }

    /// One short burst inside an otherwise silent window: the shape of a real
    /// low-gain recording, so the window rms stays well below its peak.
    private static func quietBurstData(frames: Int, burstFrames: Int, peak: Double) -> Data {
        let amplitude = Int16((peak * 32_767).rounded())
        var samples = [Int16](repeating: 0, count: frames)
        for index in 0..<min(burstFrames, frames) {
            samples[index] = amplitude
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func fixtureLevels(_ samples: Data) -> (rms: Double, peak: Double) {
        let values = samples.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
        var sumOfSquares = 0.0
        var peak = 0.0
        for value in values {
            let normalized = abs(Double(value)) / 32_768.0
            sumOfSquares += normalized * normalized
            peak = max(peak, normalized)
        }
        guard !values.isEmpty else { return (0, 0) }
        return (sqrt(sumOfSquares / Double(values.count)), peak)
    }
}
