import AVFoundation
import Foundation
import Speech
import os.log

private let onDeviceLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "OnDeviceTranscription")

enum AppleOnDeviceTranscriptionError: LocalizedError {
    case authorizationDenied(SFSpeechRecognizerAuthorizationStatus)
    case recognizerUnavailable(locale: String)
    case onDeviceModelUnavailable(locale: String)
    case cannotCreateRequest
    case cancelled
    case closedBeforeFinal

    var errorDescription: String? {
        switch self {
        case .authorizationDenied(let status):
            return "Speech recognition not authorized (status \(status.rawValue))"
        case .recognizerUnavailable(let locale):
            return "No speech recognizer available for locale \(locale)"
        case .onDeviceModelUnavailable(let locale):
            return "On-device speech model is not available for locale \(locale)"
        case .cannotCreateRequest:
            return "Could not create the on-device recognition request"
        case .cancelled:
            return "On-device recognition was cancelled"
        case .closedBeforeFinal:
            return "On-device recognition ended before emitting a final transcript"
        }
    }
}

/// On-device transcription via `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true`. Streams audio buffers DURING recording
/// and emits live partial transcripts through ``onPartialUpdate`` — the same
/// callback shape `RealtimeTranscriptionService` uses — so the existing
/// streaming-paste path in `AppState` lights up unchanged. On stop,
/// ``commitAndAwaitFinal()`` returns the final transcript with zero network use.
///
/// The producer surface (`appendPCM16`) accepts the same 24 kHz mono Int16 LE
/// PCM `Data` chunks `AudioRecorder.onPCM16Samples` already emits, so the audio
/// fan-out wiring in `AppState` is reused verbatim.
final class AppleOnDeviceTranscriptionService {
    struct Configuration {
        /// BCP-47 locale identifier (e.g. "en-US"). Empty → current locale.
        let localeIdentifier: String
    }

    /// Published on the main queue as partial transcript updates. The service
    /// forwards the recognizer's best-guess transcription string for each
    /// partial result — identical contract to `RealtimeTranscriptionService`.
    var onPartialUpdate: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private let locale: Locale

    private let stateQueue = DispatchQueue(label: "com.zachlatta.freeflow.ondevice.state")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript: String = ""
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var committed = false
    private var closed = false
    private var terminalError: Error?
    private var finalReceived = false

    /// 24 kHz mono Int16 interleaved — matches `AudioRecorder`'s `onPCM16Samples`
    /// output, so `Data` chunks can be wrapped into `AVAudioPCMBuffer`s directly.
    private let inputFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }()

    /// Returns `nil` when no `SFSpeechRecognizer` exists for the locale, so the
    /// caller can fall back to the cloud path before any recording starts.
    init?(config: Configuration) {
        let trimmed = config.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = trimmed.isEmpty ? Locale.current : Locale(identifier: trimmed)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            os_log(.info, log: onDeviceLog, "no SFSpeechRecognizer for locale %{public}@", locale.identifier)
            return nil
        }
        self.recognizer = recognizer
        self.locale = locale
    }

    /// True only when the recognizer reports it can run fully on-device for its
    /// locale. Checked before committing to the on-device path so we can fall
    /// back to the cloud when the model isn't downloaded/available.
    var isOnDeviceAvailable: Bool {
        recognizer.supportsOnDeviceRecognition
    }

    // MARK: Authorization

    /// Request (or read) speech-recognition authorization. Returns the granted
    /// status; the caller maps anything other than `.authorized` to a fallback.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: Lifecycle

    /// Authorize, verify the on-device model is available, and start a streaming
    /// recognition task. Throws (so the caller can fall back to cloud) when auth
    /// is denied or the on-device model is unavailable for the locale.
    func start() async throws {
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            throw AppleOnDeviceTranscriptionError.authorizationDenied(status)
        }
        guard recognizer.isAvailable else {
            throw AppleOnDeviceTranscriptionError.recognizerUnavailable(locale: locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleOnDeviceTranscriptionError.onDeviceModelUnavailable(locale: locale.identifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        try stateQueue.sync {
            guard !closed else {
                throw AppleOnDeviceTranscriptionError.cancelled
            }
            self.request = request
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleResult(result, error: error)
            }
            guard self.recognitionTask != nil else {
                self.request = nil
                throw AppleOnDeviceTranscriptionError.cannotCreateRequest
            }
        }
    }

    /// Cancel the recognition task and release the request. Safe to call twice.
    func cancel() {
        let (task, pending): (SFSpeechRecognitionTask?, CheckedContinuation<String, Error>?) = stateQueue.sync {
            let task = recognitionTask
            recognitionTask = nil
            request = nil
            let cont = finalContinuation
            finalContinuation = nil
            closed = true
            return (task, cont)
        }
        task?.cancel()
        pending?.resume(throwing: AppleOnDeviceTranscriptionError.cancelled)
    }

    // MARK: Producer

    /// Append a 24 kHz mono Int16 LE PCM chunk (as emitted by
    /// `AudioRecorder.onPCM16Samples`). Wraps it into an `AVAudioPCMBuffer` and
    /// feeds it to the recognition request while recording is in flight.
    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        let currentRequest: SFSpeechAudioBufferRecognitionRequest? = stateQueue.sync {
            committed || closed ? nil : request
        }
        guard let currentRequest else { return }
        guard let buffer = makePCMBuffer(from: data) else { return }
        currentRequest.append(buffer)
    }

    /// Signal end-of-input, wait for the recognizer's final result, return it.
    func commitAndAwaitFinal() async throws -> String {
        let immediate: Result<String, Error>? = stateQueue.sync {
            if let terminalError {
                return .failure(terminalError)
            }
            if finalReceived {
                return .success(latestTranscript)
            }
            if closed {
                return .failure(AppleOnDeviceTranscriptionError.closedBeforeFinal)
            }
            if !committed {
                committed = true
                request?.endAudio()
            }
            return nil
        }
        if let immediate {
            cancel()
            return try immediate.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolved: Result<String, Error>? = stateQueue.sync {
                    if let terminalError {
                        return .failure(terminalError)
                    }
                    if finalReceived {
                        return .success(latestTranscript)
                    }
                    if closed {
                        return .failure(AppleOnDeviceTranscriptionError.closedBeforeFinal)
                    }
                    finalContinuation = continuation
                    return nil
                }
                if let resolved {
                    continuation.resume(with: resolved)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    // MARK: Recognition callback

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let transcript = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            var pendingResume: (CheckedContinuation<String, Error>, String)?
            stateQueue.sync {
                latestTranscript = transcript
                if isFinal {
                    finalReceived = true
                    closed = true
                    if let cont = finalContinuation {
                        finalContinuation = nil
                        pendingResume = (cont, transcript)
                    }
                }
            }
            reportPartial(transcript)
            if let (cont, text) = pendingResume {
                cont.resume(returning: text)
            }
            return
        }

        if let error {
            var pendingResume: (CheckedContinuation<String, Error>, Result<String, Error>)?
            stateQueue.sync {
                // A non-empty transcript with a terminating error still counts as
                // a usable final (the recognizer routinely ends the stream with a
                // benign "no more audio" error after emitting the transcript).
                if finalReceived || !latestTranscript.isEmpty {
                    finalReceived = true
                    closed = true
                    if let cont = finalContinuation {
                        finalContinuation = nil
                        pendingResume = (cont, .success(latestTranscript))
                    }
                } else {
                    terminalError = error
                    closed = true
                    if let cont = finalContinuation {
                        finalContinuation = nil
                        pendingResume = (cont, .failure(error))
                    }
                }
            }
            if let (cont, outcome) = pendingResume {
                cont.resume(with: outcome)
            }
        }
    }

    private func reportPartial(_ text: String) {
        guard let handler = onPartialUpdate else { return }
        DispatchQueue.main.async {
            handler(text)
        }
    }

    // MARK: PCM helpers

    private func makePCMBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            memcpy(channelData, base, Int(frameCount) * MemoryLayout<Int16>.size)
        }
        return buffer
    }
}
