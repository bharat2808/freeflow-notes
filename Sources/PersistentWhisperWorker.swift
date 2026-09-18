import Darwin
import Foundation

/// One process/model shared by previews and final transcriptions. All pipe I/O
/// runs on a serial background queue; no native Whisper code runs in the app.
final class PersistentWhisperWorker: @unchecked Sendable {
    static let shared = PersistentWhisperWorker()

    struct Configuration: Equatable, Sendable {
        let executableURL: URL
        let modelPath: String
        let language: String?
    }

    enum WorkerError: LocalizedError {
        case unavailable, unsupported, invalidAudio, invalidResponse, timedOut
        var errorDescription: String? {
            switch self {
            case .unsupported: return "The installed local Whisper library cannot be used by the helper."
            case .unavailable: return "The local Whisper helper stopped. Try recording again."
            case .invalidAudio: return "The local Whisper audio request is empty or too large."
            case .invalidResponse: return "The local Whisper helper returned an invalid response."
            case .timedOut: return "The local Whisper helper timed out. Try again or select a smaller model."
            }
        }
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var canceled = false

        func install(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            if canceled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        var isCanceled: Bool { lock.withLock { canceled } }

        func cancel() {
            lock.lock()
            canceled = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }

        func complete(_ result: Result<String, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private final class Connection: @unchecked Sendable {
        let configuration: Configuration
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        init(configuration: Configuration) throws {
            self.configuration = configuration
            process.executableURL = configuration.executableURL
            process.arguments = [configuration.modelPath, configuration.language ?? ""]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // A dead helper must yield a write error, never SIGPIPE in the app.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw WorkerError.unavailable
            }
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
        }

        func stop() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        deinit { stop() }

        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let part = try output.fileHandleForReading.read(upToCount: count - result.count),
                      !part.isEmpty else { throw WorkerError.unavailable }
                result.append(part)
            }
            return result
        }

        func readWord() throws -> UInt32 {
            let bytes = [UInt8](try read(4))
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
    }

    /// The watchdog's lock prevents an expired timer from killing a connection
    /// after its operation finished and the next request began.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var expired = false
        func expire(_ process: Process) {
            lock.withLock {
                guard !finished else { return }
                expired = true
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        func finish() -> Bool {
            lock.withLock { finished = true; return expired }
        }
    }

    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.whisper-worker", qos: .userInitiated)
    private var connection: Connection?
    private var unsupportedConfiguration: Configuration?
    private let lifecycleLock = NSLock()
    private var activeProcess: Process?
    private var shuttingDown = false

    func transcribe(
        samples: [Float],
        configuration: Configuration,
        timeout: TimeInterval,
        startupTimeout: TimeInterval = 120
    ) async throws -> String {
        guard !samples.isEmpty, samples.count <= 16_000 * 300 else { throw WorkerError.invalidAudio }
        let request = Request()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                queue.async { [self] in
                    guard !request.isCanceled else { return }
                    do {
                        guard !lifecycleLock.withLock({ shuttingDown }) else { throw WorkerError.unavailable }
                        let current = try connected(configuration, startupTimeout: startupTimeout)
                        guard !request.isCanceled else { return }
                        let text = try withDeadline(current, seconds: timeout) {
                            var count = UInt32(samples.count).littleEndian
                            let header = withUnsafeBytes(of: &count) { Data($0) }
                            try current.input.fileHandleForWriting.write(contentsOf: header)
                            let pcm = samples.withUnsafeBytes { Data($0) }
                            try current.input.fileHandleForWriting.write(contentsOf: pcm)
                            let length = try current.readWord()
                            guard length <= 1024 * 1024 else { throw WorkerError.invalidResponse }
                            guard let text = String(data: try current.read(Int(length)), encoding: .utf8) else {
                                throw WorkerError.invalidResponse
                            }
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        request.complete(.success(text))
                    } catch {
                        if case WorkerError.unsupported = error { unsupportedConfiguration = configuration }
                        connection?.stop()
                        connection = nil
                        request.complete(.failure(error))
                    }
                }
            }
        } onCancel: {
            // Keep a healthy in-flight helper warm. Its reply is drained on the
            // queue and discarded; canceled callers return immediately.
            request.cancel()
        }
    }

    private func connected(_ config: Configuration, startupTimeout: TimeInterval) throws -> Connection {
        if unsupportedConfiguration == config { throw WorkerError.unsupported }
        if let connection, connection.configuration == config, connection.process.isRunning {
            return connection
        }
        connection?.stop()
        connection = nil
        let next = try Connection(configuration: config)
        connection = next
        try lifecycleLock.withLock {
            if shuttingDown {
                next.stop()
                throw WorkerError.unavailable
            }
            activeProcess = next.process
        }
        try withDeadline(next, seconds: startupTimeout) {
            let status = try next.readWord()
            if status == 0x46574630 { throw WorkerError.unsupported }
            guard status == 0x46574631 else { throw WorkerError.invalidResponse }
        }
        return next
    }

    private func withDeadline<T>(_ connection: Connection, seconds: TimeInterval, body: () throws -> T) throws -> T {
        let deadline = Deadline()
        let watchdog = DispatchWorkItem { deadline.expire(connection.process) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.05, seconds), execute: watchdog)
        let result = Result { try body() }
        let expired = deadline.finish()
        watchdog.cancel()
        if expired { throw WorkerError.timedOut }
        return try result.get()
    }

    func shutdown() {
        lifecycleLock.withLock {
            shuttingDown = true
            if let activeProcess, activeProcess.isRunning {
                kill(activeProcess.processIdentifier, SIGKILL)
            }
            activeProcess = nil
        }
        queue.sync {
            connection?.stop()
            connection = nil
        }
    }
}
