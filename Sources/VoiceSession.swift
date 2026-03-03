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

        // 5. Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
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

        // 7. Install audio tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        // 8. Start audio engine
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

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        recognizer = nil
    }
}
