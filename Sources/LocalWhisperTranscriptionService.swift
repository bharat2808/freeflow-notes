import AVFoundation
import Foundation
import os.lock
import os.log

private let localWhisperLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "LocalWhisperPreview"
)

enum LocalWhisperModelDownloader {
    static let baseEnglishModelURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin?download=true"
    )!

    static var baseEnglishModelPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper/ggml-base.en.bin")
    }

    static func downloadBaseEnglishModel(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = baseEnglishModelPath
        if FileManager.default.fileExists(atPath: destination.path) {
            progress(1)
            return destination
        }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = try await downloadToTemporaryFile(progress: progress)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        progress(1)
        return destination
    }

    private static func downloadToTemporaryFile(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowWhisperDownload", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(
                destinationURL: temporaryURL,
                progress: progress,
                continuation: continuation
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: baseEnglishModelURL)
            task.resume()
        }
    }
}

enum LocalWhisperInstaller {
    static var brewURL: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var installedExecutableURL: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func installWhisperCpp(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> URL {
        if let installedExecutableURL { return installedExecutableURL }
        guard let brewURL else {
            throw LocalWhisperError.installerNotFound
        }

        progress("Installing whisper-cpp with Homebrew…")
        let process = Process()
        process.executableURL = brewURL
        process.arguments = ["install", "whisper-cpp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let reader = pipe.fileHandleForReading
        while process.isRunning {
            if let data = try? reader.read(upToCount: 4096), let output = String(data: data, encoding: .utf8), !output.isEmpty {
                progress(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let remaining = try? reader.readToEnd()
        if let remaining, let output = String(data: remaining, encoding: .utf8), !output.isEmpty {
            progress(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard process.terminationStatus == 0, let executableURL = installedExecutableURL else {
            throw LocalWhisperError.installFailed
        }
        progress("whisper-cpp installed")
        return executableURL
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destinationURL: URL
    let progress: @Sendable (Double) -> Void
    let continuation: CheckedContinuation<URL, Error>
    var session: URLSession?
    private var downloadedURL: URL?
    private var downloadError: Error?

    init(
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.destinationURL = destinationURL
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.removeItem(at: destinationURL)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Expected for the first download.
        } catch {
            downloadError = error
            return
        }

        do {
            try FileManager.default.copyItem(at: location, to: destinationURL)
            downloadedURL = destinationURL
        } catch {
            downloadError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.invalidateAndCancel() }
        if let error = error ?? downloadError {
            continuation.resume(throwing: error)
        } else if let downloadedURL {
            continuation.resume(returning: downloadedURL)
        } else {
            continuation.resume(throwing: URLError(.cannotDecodeContentData))
        }
    }
}

enum LocalWhisperError: LocalizedError {
    case executableNotFound(String)
    case modelNotFound(String)
    case processLaunchFailed(String)
    case processFailed(Int32, String)
    case timedOut(TimeInterval)
    case emptyTranscript
    case installerNotFound
    case installFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Local Whisper executable was not found at \(path). Set the executable path in Settings."
        case .modelNotFound(let path):
            return "Local Whisper model was not found at \(path). Set the model path in Settings."
        case .processLaunchFailed(let message):
            return "Could not start local Whisper: \(message)"
        case .processFailed(let status, let output):
            let detail = output.isEmpty ? "No diagnostic output was returned." : output
            return "Local Whisper exited with status \(status): \(detail)"
        case .timedOut(let seconds):
            return "Local Whisper timed out after \(Int(seconds)) seconds. Try a smaller model or shorter recording."
        case .emptyTranscript:
            return "Local Whisper returned no transcript."
        case .installerNotFound:
            return "Homebrew was not found. Install Homebrew first, or set a custom whisper-cli path in Settings."
        case .installFailed:
            return "Homebrew could not install whisper-cpp. Install it manually, then choose whisper-cli in Settings."
        }
    }
}

final class LocalWhisperTranscriptionService: AudioTranscriber {
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let process = self.process
            lock.unlock()
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }

    private let executableURL: URL
    private let modelURL: URL
    private let language: String?
    private let timeoutSeconds: TimeInterval
    private let helperConfiguration: PersistentWhisperWorker.Configuration?
    private let worker: PersistentWhisperWorker

    init(
        executablePath: String,
        modelPath: String,
        language: String? = nil,
        timeoutSeconds: TimeInterval = 120,
        helperExecutableURL: URL? = Bundle.main.url(forResource: "freeflow-whisper-worker", withExtension: nil),
        worker: PersistentWhisperWorker = .shared
    ) throws {
        let executable = Self.resolvePath(executablePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalWhisperError.executableNotFound(executable.path)
        }

        let model = Self.resolvePath(modelPath)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw LocalWhisperError.modelNotFound(model.path)
        }

        self.executableURL = executable
        self.modelURL = model
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLanguage = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        self.language = resolvedLanguage
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.worker = worker
        self.helperConfiguration = helperExecutableURL.map {
            PersistentWhisperWorker.Configuration(
                executableURL: $0, modelPath: model.path, language: resolvedLanguage
            )
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if let helperConfiguration,
           let samples = try Self.readRecordingSamples(fileURL) {
            do {
                return try await transcribeWithHelper(samples, configuration: helperConfiguration)
            } catch PersistentWhisperWorker.WorkerError.unsupported {
                // Headerless builds or unsupported local libraries retain CLI support.
            }
        }
        return try await transcribeUsingCLI(fileURL: fileURL)
    }

    private func transcribeUsingCLI(fileURL: URL) async throws -> String {
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    try await self.runProcess(fileURL: fileURL, processBox: processBox)
                }
                group.addTask { [timeoutSeconds] in
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw LocalWhisperError.timedOut(timeoutSeconds)
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else {
                        throw LocalWhisperError.emptyTranscript
                    }
                    return result
                } catch {
                    processBox.terminate()
                    throw error
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    /// Transcribes a short in-memory PCM16 snapshot. AudioRecorder emits the
    /// same 16 kHz mono PCM16 used by the saved recording.
    func transcribePCM16(_ samples: Data, sampleRate: Int = 16_000) async throws -> String {
        guard !samples.isEmpty else { throw LocalWhisperError.emptyTranscript }
        if sampleRate == 16_000, let helperConfiguration {
            let floats = samples.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768.0 }
            }
            do {
                return try await transcribeWithHelper(floats, configuration: helperConfiguration)
            } catch PersistentWhisperWorker.WorkerError.unsupported {
                // Preserve custom/unsupported installations via the configured CLI.
            }
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-whisper-preview-\(UUID().uuidString).wav")
        try Self.makeWAVData(pcm16: samples, sampleRate: sampleRate).write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try await transcribeUsingCLI(fileURL: temporaryURL)
    }

    private func transcribeWithHelper(
        _ samples: [Float], configuration: PersistentWhisperWorker.Configuration
    ) async throws -> String {
        let result = try await worker.transcribe(
            samples: samples, configuration: configuration, timeout: timeoutSeconds
        )
        guard !result.isEmpty else { throw LocalWhisperError.emptyTranscript }
        return result
    }

    /// The recorder and chunker produce mono 16 kHz WAVs. Other audio formats
    /// continue through the CLI's existing decoding path.
    private static func readRecordingSamples(_ url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 300 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PersistentWhisperWorker.WorkerError.invalidAudio
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            throw PersistentWhisperWorker.WorkerError.invalidAudio
        }
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    func makeLivePreviewSession(
        onUpdate: @escaping @Sendable (String) -> Void
    ) -> LocalWhisperPreviewSession {
        LocalWhisperPreviewSession(
            transcribe: { [self] samples, sampleRate in
                try await transcribePCM16(samples, sampleRate: sampleRate)
            },
            onUpdate: onUpdate
        )
    }

    static func makeWAVData(pcm16: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(min(UInt64(pcm16.count), UInt64(UInt32.max)))

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLittleEndian(UInt32(36) &+ dataSize)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.appendLittleEndian(UInt32(16)) // PCM fmt chunk size
        wav.appendLittleEndian(UInt16(1)) // PCM format
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLittleEndian(dataSize)
        wav.append(pcm16.prefix(Int(dataSize)))
        return wav
    }

    private func runProcess(fileURL: URL, processBox: ProcessBox) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments(for: fileURL)
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        processBox.set(process)

        do {
            try process.run()
        } catch {
            throw LocalWhisperError.processLaunchFailed(error.localizedDescription)
        }

        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalWhisperError.processFailed(process.terminationStatus, cleanDiagnosticOutput(output))
        }

        let transcript = Self.cleanTranscript(output)
        guard !transcript.isEmpty else { throw LocalWhisperError.emptyTranscript }
        return transcript
    }

    private func arguments(for fileURL: URL) -> [String] {
        var arguments = ["-m", modelURL.path, "-f", fileURL.path, "-nt", "-np"]
        if let language { arguments += ["-l", language] }
        return arguments
    }

    private static func resolvePath(_ value: String) -> URL {
        let requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (requested as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        // Finder-launched apps often receive a reduced PATH that omits
        // Homebrew. Keep PATH support for custom installs, then search the
        // standard macOS/Homebrew locations explicitly.
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirectories = environmentPath.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let names = expanded.isEmpty ? ["whisper-cli", "whisper-cpp"] : [expanded]
        for name in names {
            for directory in Set(searchDirectories) {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
            }
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func cleanTranscript(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\s*\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("whisper_") && !trimmed.hasPrefix("main:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanDiagnosticOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        return String(trimmed.prefix(239)) + "…"
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

/// Decides whether a provisional preview window is worth transcribing.
///
/// Microphone gain varies by orders of magnitude, so a fixed amplitude
/// threshold can silently disable the live preview: a real low-gain recording
/// measured its first 3 s window at rms 0.00701 with a peak of 0.0377 — just
/// under the previous rms 0.008 / peak 0.04 constants — while the same audio
/// transcribed without trouble at stop time. These floors only reject digital
/// silence and pure room tone and sit far below speech captured at a low input
/// gain (3 % of full scale measures rms 0.00346 / peak 0.0201).
struct PreviewSpeechGate {
    private let minimumRMS: Double
    private let minimumPeak: Double
    /// A window this many times quieter than the loudest window of this
    /// recording is treated as a pause. Comparing against the recording's own
    /// level keeps pause skipping useful on quiet microphones, where absolute
    /// thresholds cannot separate speech from room tone.
    private let dynamicRangeFactor: Double
    private var loudestRMS = 0.0

    init(
        minimumRMS: Double = 0.001,
        minimumPeak: Double = 0.0045,
        dynamicRangeFactor: Double = 16
    ) {
        self.minimumRMS = minimumRMS
        self.minimumPeak = minimumPeak
        self.dynamicRangeFactor = dynamicRangeFactor
    }

    mutating func containsSpeech(rms: Double, peak: Double) -> Bool {
        guard peak >= minimumPeak || rms >= minimumRMS else { return false }
        let reference = loudestRMS
        loudestRMS = max(loudestRMS, rms)
        // The first window above the noise floors is taken at face value:
        // nothing louder has been measured yet to compare it against.
        guard reference > 0 else { return true }
        return rms * dynamicRangeFactor >= reference
    }

    /// Walks every sample, so callers keep this off the audio callback and the
    /// session state lock.
    static func levels(of samples: Data) -> (rms: Double, peak: Double) {
        let values = samples.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
        guard !values.isEmpty else { return (0, 0) }
        var sumOfSquares = 0.0
        var peak = 0.0
        for value in values {
            let normalized = abs(Double(value)) / 32_768.0
            sumOfSquares += normalized * normalized
            peak = max(peak, normalized)
        }
        return (sqrt(sumOfSquares / Double(values.count)), peak)
    }
}

/// Incremental local Whisper preview used while a note is still recording.
/// It deliberately treats each result as provisional: the complete recording
/// is transcribed again after stop, so preview latency never changes the
/// authoritative note contents.
final class LocalWhisperPreviewSession: @unchecked Sendable {
    private struct PreviewSnapshot {
        let audio: Data
    }

    private let transcribe: @Sendable (Data, Int) async throws -> String
    private let onUpdate: @Sendable (String) -> Void
    private let stateLock = OSAllocatedUnfairLock(initialState: ())
    private var audio = Data()
    private var pendingPreviewBytes = 0
    private var stopped = false
    private var workerRunning = false
    private var workerTask: Task<Void, Never>?
    private var speechGate = PreviewSpeechGate()

    private let sampleRate = 16_000
    private let chunkFrames = 16_000 * 3
    private let maxBufferedFrames = 16_000 * 20
    /// How much *new* audio a rejected window waits for before the next
    /// attempt. Retrying on every microphone callback would re-walk the whole
    /// window far too often.
    private let rejectedWindowRetryFrames = 16_000

    private var chunkBytes: Int {
        chunkFrames * MemoryLayout<Int16>.size
    }

    init(
        transcribe: @escaping @Sendable (Data, Int) async throws -> String,
        onUpdate: @escaping @Sendable (String) -> Void
    ) {
        self.transcribe = transcribe
        self.onUpdate = onUpdate
    }

    func appendPCM16(_ samples: Data) {
        guard !samples.isEmpty else { return }
        let shouldStartWorker = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            audio.append(samples)
            pendingPreviewBytes += samples.count
            guard !workerRunning, pendingPreviewBytes >= chunkBytes else { return false }
            workerRunning = true
            return true
        }

        guard shouldStartWorker else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainAudio()
        }
        stateLock.withLock {
            workerTask = task
        }
    }

    func stop() {
        stateLock.withLock {
            stopped = true
            workerTask?.cancel()
            workerTask = nil
            workerRunning = false
        }
    }

    private func nextPreviewSnapshotLocked() -> PreviewSnapshot? {
        let bytesPerFrame = MemoryLayout<Int16>.size
        guard pendingPreviewBytes >= chunkBytes, audio.count >= chunkBytes else { return nil }
        pendingPreviewBytes = 0
        let maxBytes = maxBufferedFrames * bytesPerFrame
        if audio.count > maxBytes {
            // Trim once per inference instead of shifting a 20-second Data
            // buffer on every microphone callback after the window fills.
            audio = Data(audio.suffix(maxBytes))
        }
        return PreviewSnapshot(audio: audio)
    }

    /// Re-counts most of a chunk that the speech gate rejected, so the next
    /// attempt needs only `rejectedWindowRetryFrames` of new audio.
    private func rearmAfterSilentWindow() {
        stateLock.withLock {
            guard !stopped else { return }
            let retryBytes = rejectedWindowRetryFrames * MemoryLayout<Int16>.size
            pendingPreviewBytes = max(0, chunkBytes - retryBytes)
        }
    }

    private func drainAudio() async {
        while !Task.isCancelled {
            let snapshot: PreviewSnapshot? = stateLock.withLock {
                guard !stopped else {
                    workerRunning = false
                    return nil
                }
                return nextPreviewSnapshotLocked()
            }

            guard let snapshot else {
                let hasPendingChunk: Bool = stateLock.withLock {
                    guard !stopped else {
                        workerRunning = false
                        workerTask = nil
                        return false
                    }
                    // Audio that filled the chunk while this iteration looked
                    // away still needs transcribing; simply exiting would leave
                    // it waiting for a microphone callback that may never come.
                    guard pendingPreviewBytes < chunkBytes else { return true }
                    workerRunning = false
                    workerTask = nil
                    return false
                }
                if hasPendingChunk { continue }
                return
            }
            await process(snapshot)
        }

        stateLock.withLock {
            workerRunning = false
            workerTask = nil
        }
    }

    private func process(_ snapshot: PreviewSnapshot) async {
        let startedAt = CFAbsoluteTimeGetCurrent()
        // Level analysis stays off the state lock: it walks up to 20 s of
        // samples and must not stall the microphone callback.
        let levels = PreviewSpeechGate.levels(of: snapshot.audio)
        let containsSpeech = stateLock.withLock {
            speechGate.containsSpeech(rms: levels.rms, peak: levels.peak)
        }
        do {
            // Avoid invoking Whisper for clearly silent chunks.  This keeps
            // long recordings inexpensive while preserving the recorder's
            // complete audio for final transcription.
            if containsSpeech {
                let transcript = try await transcribe(snapshot.audio, sampleRate)
                try Task.checkCancellation()
                let preview = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    // Each snapshot is a rolling window and may revise words
                    // from the prior result. Replacing the provisional preview
                    // avoids duplicating those revised overlapping passages.
                    onUpdate(preview)
                    os_log(
                        .info,
                        log: localWhisperLog,
                        "preview updated audio=%.1fs elapsed=%.0fms",
                        Double(snapshot.audio.count) / Double(sampleRate * MemoryLayout<Int16>.size),
                        (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    )
                }
            } else {
                // The audio stays in the rolling buffer, so retry after a short
                // slice of new audio instead of forfeiting the whole chunk:
                // clearing it made a recording that opened quietly wait another
                // full chunk for its next chance, and a short note produced no
                // preview text at all.
                rearmAfterSilentWindow()
                os_log(
                    .info,
                    log: localWhisperLog,
                    "preview skipped silent window rms=%.5f peak=%.4f elapsed=%.0fms",
                    levels.rms,
                    levels.peak,
                    (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                )
            }
        } catch is CancellationError {
            // Recording cancellation is expected and should not surface as an error.
        } catch {
            // Preview failures are non-fatal; the final stop-time transcription
            // still reports actionable errors to the user.
            os_log(
                .error,
                log: localWhisperLog,
                "preview failed after %.0fms: %{public}@",
                (CFAbsoluteTimeGetCurrent() - startedAt) * 1000,
                error.localizedDescription
            )
        }
    }
}
