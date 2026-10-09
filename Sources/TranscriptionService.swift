import Foundation
import os.log

private let transcriptionLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Transcription")

class TranscriptionService {
    private let apiKey: String
    private let baseURL: URL
    private let transcriptionModel: String
    private let language: String?
    private let transcriptionResponseFormat = "verbose_json"
    private let maxTranscriptionAttempts = 3
    private let transcriptionRetryBackoffs: [TimeInterval] = [2, 5]
    private var transcriptionTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
        return override > 0 ? override : 120
    }

    private struct HTTPTranscriptionFailure: Error {
        let status: Int
        let message: String
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        transcriptionModel: String = "whisper-large-v3",
        language: String? = nil
    ) throws {
        self.apiKey = apiKey
        self.baseURL = try Self.normalizedBaseURL(from: baseURL)
        let trimmedModel = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcriptionModel = trimmedModel.isEmpty ? "whisper-large-v3" : trimmedModel
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let baseURL = try? normalizedBaseURL(from: baseURL) else { return false }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await LLMAPITransport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        do {
            return try await transcribeAudio(fileURL: fileURL)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw TranscriptionError.transcriptionTimedOut(transcriptionTimeoutSeconds)
        }
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL) async throws -> String {
        return try await transcribeAudioWithURLSession(fileURL: fileURL)
    }

    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        for attempt in 1...maxTranscriptionAttempts {
            try Task.checkCancellation()
            do {
                return try await performTranscriptionUpload(fileURL: fileURL, attempt: attempt)
            } catch let failure as HTTPTranscriptionFailure {
                guard attempt < maxTranscriptionAttempts, Self.isRetriableHTTPStatus(failure.status) else {
                    throw TranscriptionError.submissionFailed(failure.message)
                }
                await sleepBeforeRetry(attempt: attempt, fileURL: fileURL, reason: failure.message)
            } catch let urlError as URLError {
                guard attempt < maxTranscriptionAttempts, Self.isRetriableConnectionError(urlError) else {
                    if urlError.code == .timedOut {
                        throw TranscriptionError.transcriptionTimedOut(transcriptionTimeoutSeconds)
                    }
                    throw urlError
                }
                await sleepBeforeRetry(attempt: attempt, fileURL: fileURL, reason: urlError.localizedDescription)
            } catch {
                let nsError = error as NSError
                os_log(
                    .error,
                    log: transcriptionLog,
                    "URLSession upload failed for %{public}@ (attempt=%ld/%ld bytes=%{public}lld): domain=%{public}@ code=%ld desc=%{public}@",
                    fileURL.lastPathComponent,
                    attempt,
                    maxTranscriptionAttempts,
                    fileSizeBytes(for: fileURL),
                    nsError.domain,
                    nsError.code,
                    error.localizedDescription
                )
                guard attempt < maxTranscriptionAttempts, Self.isRetriableConnectionError(error) else {
                    throw error
                }
                await sleepBeforeRetry(attempt: attempt, fileURL: fileURL, reason: error.localizedDescription)
            }
        }

        throw TranscriptionError.transcriptionTimedOut(transcriptionTimeoutSeconds)
    }

    /// Per-request deadline for one upload attempt: the configured base timeout
    /// plus an allowance for actually pushing the bytes. Audio is 32 kbps mono
    /// AAC (~4 KB/s), so even a 45-minute note is only ~11 MB; the allowance
    /// assumes a pessimistic 100 KB/s uplink and is clamped so a wedged
    /// connection still fails in reasonable time.
    private func uploadTimeout(forFileAt fileURL: URL) -> TimeInterval {
        let bytes = fileSizeBytes(for: fileURL)
        guard bytes > 0 else { return transcriptionTimeoutSeconds }
        let assumedUplinkBytesPerSecond = 100_000.0
        let transferAllowance = Double(bytes) / assumedUplinkBytesPerSecond
        return min(transcriptionTimeoutSeconds + transferAllowance, 240)
    }

    /// Stall (idle) timeout for the first attempt on the pooled connection, so a
    /// silently dead connection fails in seconds rather than the full timeout.
    /// Measured Groq server time: 132s note ~0.9s, 315s note 8.2s, so scale ~2.5x
    /// over that (bytes/100KB at ~4 KB/s audio): 1.3MB note -> 23s.
    private func firstAttemptStallTimeout(forFileAt fileURL: URL) -> TimeInterval {
        let bytes = Double(fileSizeBytes(for: fileURL))
        return min(10 + bytes / 100_000, uploadTimeout(forFileAt: fileURL))
    }

    private func performTranscriptionUpload(fileURL: URL, attempt: Int) async throws -> String {
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Scale the deadline with upload size. A flat timeout has to be either too
        // tight for a 45-minute note on a slow link or needlessly loose for the
        // 2-second case; long recordings are the single largest bucket in real use,
        // and killing one at a flat 30s throws away the whole upload and restarts it.
        request.timeoutInterval = attempt == 1
            ? firstAttemptStallTimeout(forFileAt: fileURL)
            : uploadTimeout(forFileAt: fileURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let multipartFileURL = try makeMultipartBodyFile(
            audioFileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            model: transcriptionModel,
            responseFormat: transcriptionResponseFormat,
            language: language,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartFileURL) }

        // Attempt 1 reuses the warm pooled connection; retries open a fresh one so a
        // silently dead pooled connection cannot eat every attempt.
        let (data, response) = attempt == 1
            ? try await LLMAPITransport.upload(for: request, fromFile: multipartFileURL)
            : try await LLMAPITransport.uploadOnFreshConnection(for: request, fromFile: multipartFileURL)
        return try validateTranscriptionResponse(data: data, response: response, fileURL: fileURL, attempt: attempt)
    }

    private func validateTranscriptionResponse(data: Data, response: URLResponse, fileURL: URL, attempt: Int) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (attempt=%ld/%ld bytes=%{public}lld) body=%{public}@",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                attempt,
                maxTranscriptionAttempts,
                fileSizeBytes(for: fileURL),
                responseBody
            )
            throw HTTPTranscriptionFailure(
                status: httpResponse.statusCode,
                message: Self.friendlyHTTPMessage(
                    status: httpResponse.statusCode,
                    host: baseURL.host
                )
            )
        }

        return try parseTranscript(from: data)
    }

    private func sleepBeforeRetry(attempt: Int, fileURL: URL, reason: String) async {
        let delaySeconds = transcriptionRetryBackoffs[min(attempt - 1, transcriptionRetryBackoffs.count - 1)]
        os_log(
            .info,
            log: transcriptionLog,
            "Retrying transcription upload for %{public}@ after attempt %ld/%ld in %.0fs: %{public}@",
            fileURL.lastPathComponent,
            attempt,
            maxTranscriptionAttempts,
            delaySeconds,
            reason
        )
        try? await Task.sleep(for: .seconds(delaySeconds))
    }

    private static func isRetriableHTTPStatus(_ status: Int) -> Bool {
        (500..<600).contains(status)
    }

    private static func isRetriableConnectionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return isRetriableConnectionError(urlError)
    }

    private static func isRetriableConnectionError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotParseResponse,
             .badServerResponse,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .cannotLoadFromNetwork,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func makeMultipartBodyFile(
        audioFileURL: URL,
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        boundary: String
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-transcription-multipart.body")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: tempURL)

        do {
            try appendMultipartString("--\(boundary)\r\n", to: output)
            try appendMultipartString("Content-Disposition: form-data; name=\"model\"\r\n\r\n", to: output)
            try appendMultipartString("\(model)\r\n", to: output)

            try appendMultipartString("--\(boundary)\r\n", to: output)
            try appendMultipartString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n", to: output)
            try appendMultipartString("\(responseFormat)\r\n", to: output)

            if let language, !language.isEmpty {
                try appendMultipartString("--\(boundary)\r\n", to: output)
                try appendMultipartString("Content-Disposition: form-data; name=\"language\"\r\n\r\n", to: output)
                try appendMultipartString("\(language)\r\n", to: output)
            }

            try appendMultipartString("--\(boundary)\r\n", to: output)
            try appendMultipartString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n", to: output)
            try appendMultipartString("Content-Type: \(audioContentType(for: fileName))\r\n\r\n", to: output)
            try appendFile(audioFileURL, to: output)
            try appendMultipartString("\r\n--\(boundary)--\r\n", to: output)
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return tempURL
    }

    private func appendMultipartString(_ value: String, to output: FileHandle) throws {
        try output.write(contentsOf: Data(value.utf8))
    }

    private func appendFile(_ fileURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        while true {
            guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            try output.write(contentsOf: chunk)
        }
    }

    /// Map a non-200 HTTP status into a one-line user-readable message.
    /// Used for transcription submission failures so the menu bar shows
    /// "Invalid API key for api.openai.com" instead of raw JSON.
    static func friendlyHTTPMessage(status: Int, host: String?) -> String {
        let provider = host ?? "the provider"
        switch status {
        case 401:
            return "Invalid API key for \(provider). Open Settings to fix it."
        case 403:
            return "Key lacks permission for this endpoint at \(provider) (HTTP 403). Check the key's scopes."
        case 404:
            return "Endpoint not found at \(provider) (HTTP 404). Base URL is likely wrong for this provider."
        case 413:
            return "Audio file too large for \(provider) (HTTP 413). Try a shorter recording."
        case 429:
            return "Rate limit reached at \(provider) (HTTP 429). Wait a moment and try again."
        case 500..<600:
            return "Provider error at \(provider) (HTTP \(status)). Try again in a moment."
        default:
            return "Request failed at \(provider) (HTTP \(status))."
        }
    }

    private static func normalizedBaseURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL is empty.")
        }

        guard var components = URLComponents(string: trimmed) else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TranscriptionError.invalidBaseURL("Provider URL must use http or https.")
        }

        guard let host = components.host, !host.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL must include a host.")
        }

        components.scheme = scheme
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
        }

        guard let normalizedURL = components.url else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        return normalizedURL
    }

    // Whisper-large-v3 hallucinates common short phrases on silence/background
    // noise. Drop them when whisper itself reports a high no_speech_prob.
    // Add a new (phrase, minNoSpeechProb) pair here to filter more hallucinations.
    //
    // Thresholds tuned on ~500 samples from quiet and noisy environments, including
    // both positive cases (real "thank you" speech) and empty-audio cases. Kept
    // conservative to minimize false positives (filtering real user speech).
    // Normal speech included audios have very low no_speech_prob.
    private let hallucinationPhrases = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
        "you"
    ]

    private let hallucinationNoSpeechThreshold = 0.1

    private func parseTranscript(from data: Data) throws -> String {
        // We always request `verbose_json`, so anything else is not a transcript:
        // an empty or garbled 200 (seen on reused connections) must be retried on a
        // fresh connection, never pasted. URLError keeps it on the retry path.
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = json["text"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        if isHallucination(text: text, json: json) {
            return ""
        }
        return text
    }

    private func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return false
        }

        // We are here ONLY because the entire transcript is a known junk phrase
        // ("thank you", "you", "please subscribe", ...). A user virtually never
        // dictates one of these in isolation into a coding/voice tool — so when
        // the provider's no_speech metadata is missing, fail CLOSED (drop it)
        // rather than open (leak it). Missing metadata was the live bug: Right
        // Option spammed "thank you" because every guard returned false on
        // absent segments/no_speech_prob. Real multi-word speech never reaches
        // this branch (it fails the hallucinationPhrases membership check above).
        guard let segments = json["segments"] as? [[String: Any]] else {
            os_log(
                .info,
                log: transcriptionLog,
                "Dropping bare junk phrase '%{public}@': no segments metadata (fail-closed)",
                normalized
            )
            return true
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptionLog,
                "Dropping bare junk phrase '%{public}@': no no_speech_prob metadata (fail-closed)",
                normalized
            )
            return true
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let msg): return "Invalid provider URL: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
