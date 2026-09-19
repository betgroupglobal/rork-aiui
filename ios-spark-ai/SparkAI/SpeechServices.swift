//
//  SpeechServices.swift
//  SparkAI
//
//  Dictation (Speech framework + AVAudioEngine) for voice prompts and
//  text-to-speech playback of assistant replies.
//

import AVFoundation
import Foundation
import Speech

/// Live microphone dictation, streaming partial transcripts into a binding.
@Observable
@MainActor
final class DictationService {
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var handler: ((String) -> Void)?

    private(set) var isRecording = false
    private(set) var statusMessage: String?

    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func toggleDictation(handler: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            start(handler: handler)
        }
    }

    func start(handler: @escaping (String) -> Void) {
        guard !isRecording else { return }
        statusMessage = nil
        self.handler = handler

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.statusMessage = "Speech recognition is off — enable it in Settings."
                    return
                }
                self.requestMicrophoneAccess()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        teardown()
    }

    // MARK: - Internals

    private func requestMicrophoneAccess() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.statusMessage = "Microphone access is off — enable it in Settings."
                    return
                }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                Task { @MainActor [weak self] in
                    self?.handler?(text)
                }
            }
            isRecording = true
        } catch {
            statusMessage = "Microphone unavailable."
            teardown()
        }
    }

    private func teardown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Text-to-speech playback for assistant messages, tracked per message ID.
@Observable
@MainActor
final class SpeechSynthesisService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesisService()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var speakingMessageID: UUID?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(for messageID: UUID, rawText: String) {
        if speakingMessageID == messageID {
            stop()
            return
        }
        stop()

        let text = speakableText(rawText)
        guard !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        speakingMessageID = messageID
    }

    func stop() {
        guard synthesizer.isSpeaking else {
            speakingMessageID = nil
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageID = nil
    }

    /// Strips fenced code blocks and inline markdown so only prose is read.
    private func speakableText(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if !inCode {
                lines.append(String(line))
            }
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speakingMessageID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speakingMessageID = nil }
    }
}
