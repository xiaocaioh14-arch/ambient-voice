import Foundation
import AVFoundation
import Speech

final class VoiceSession: @unchecked Sendable {
    enum State {
        case idle, preparing, recording, finalizing
    }

    enum SessionError: Error, LocalizedError {
        case microphonePermissionDenied
        case speechRecognitionDenied
        case recognizerUnavailable
        case audioEngineFailure(Error)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission denied."
            case .speechRecognitionDenied:
                return "Speech recognition authorization denied."
            case .recognizerUnavailable:
                return "Speech recognizer is not available for zh-Hans."
            case .audioEngineFailure(let err):
                return "Audio engine failure: \(err.localizedDescription)"
            }
        }
    }

    private(set) var state: State = .idle
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var accumulator = TranscriptionAccumulator()

    var onStateChange: ((State) -> Void)?
    var onPartialResult: ((String) -> Void)?

    /// When true, saves audio to ~/.we/audio/ for distillation training data.
    var saveAudio: Bool = false

    /// Screen context keywords injected into SFSpeechRecognitionRequest.contextualStrings.
    /// This biases the recognizer at transcription time — prevention, not correction.
    var contextualStrings: [String] = []

    /// Path of saved audio file after recording stops.
    private(set) var savedAudioPath: String?
    private var audioFile: AVAudioFile?

    /// Continuation used to bridge the callback-based recognition task to async/await in `stop()`.
    private var finalResultContinuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        state = .preparing
        onStateChange?(.preparing)

        // 1. Check microphone permission
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else { throw SessionError.microphonePermissionDenied }

        // 2. Initialize SFSpeechRecognizer for zh-Hans
        let locale = Locale(identifier: "zh-Hans")
        let rec = SFSpeechRecognizer(locale: locale)
        guard let recognizer = rec, recognizer.isAvailable else {
            throw SessionError.recognizerUnavailable
        }
        self.recognizer = recognizer

        // 3. Check speech recognition authorization
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw SessionError.speechRecognitionDenied
        }

        // 4. Create AVAudioEngine
        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Validate audio format — some device configurations return invalid formats.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cleanup()
            throw SessionError.audioEngineFailure(
                NSError(domain: "VoiceSession", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format: sampleRate=\(format.sampleRate) channels=\(format.channelCount)"])
            )
        }

        // 5. Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        // Inject screen context keywords to bias recognition at transcription time.
        // This is "prevention, not correction" — the recognizer uses these strings
        // to prefer matching candidates when doing homophone disambiguation.
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
            DebugLog.log(.voice, "Injected \(contextualStrings.count) contextual strings into recognizer")
        }

        self.recognitionRequest = request

        // 6. Start recognition task
        accumulator.reset()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.accumulator.update(from: result)
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { [weak self] in
                    self?.onPartialResult?(text)
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                // Recognition ended — resume the stop() continuation if waiting
                DispatchQueue.main.async { [weak self] in
                    self?.finalResultContinuation?.resume()
                    self?.finalResultContinuation = nil
                }
            }
        }

        // 7. Set up audio file for saving (if distillation enabled)
        if saveAudio {
            setupAudioFile(format: format)
        }

        // 8. Install audio tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            // Write to file for distillation if enabled
            try? self?.audioFile?.write(from: buffer)
        }

        // 9. Start audio engine
        do {
            try engine.start()
        } catch {
            cleanup()
            throw SessionError.audioEngineFailure(error)
        }

        state = .recording
        onStateChange?(.recording)
    }

    func stop() async -> TranscriptionResult {
        guard state == .recording || state == .preparing else {
            return accumulator.finalize()
        }

        state = .finalizing
        onStateChange?(.finalizing)

        // 1. Stop audio tap and engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // 2. End recognition request — signals the recognizer to produce a final result
        recognitionRequest?.endAudio()

        // 3. Wait for final result callback
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if recognitionTask == nil {
                cont.resume()
            } else {
                finalResultContinuation = cont
                // Safety timeout — don't hang forever if callback never fires
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.finalResultContinuation?.resume()
                    self?.finalResultContinuation = nil
                }
            }
        }

        let result = accumulator.finalize()
        cleanup()

        state = .idle
        onStateChange?(.idle)
        return result
    }

    // MARK: - Private

    private func setupAudioFile(format: AVAudioFormat) {
        let fm = FileManager.default
        let audioDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/audio")
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let filename = "voice-\(ISO8601DateFormatter().string(from: Date())).caf"
        let url = audioDir.appendingPathComponent(filename)

        // Write in the input format; conversion to 16kHz mono can happen in the distill pipeline
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            savedAudioPath = url.path
        } catch {
            DebugLog.log(.voice, "Failed to create audio file: \(error)", level: .warning)
            audioFile = nil
            savedAudioPath = nil
        }
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        recognizer = nil
        audioFile = nil
    }
}
