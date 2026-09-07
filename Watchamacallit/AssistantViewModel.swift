import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var phase: AssistantPhase = .off
    @Published private(set) var transcript = "Tap on the mic to start."
    @Published var playbackVolume: Double = 1

    private let audio = AudioController()
    private var realtimeClient: RealtimeClient?
    private var desiredVoiceMode = false
    private var canSendMicrophoneAudio = false
    private var responseHasAudio = false
    private var ignoringAssistantOutput = false

    init() {
        audio.onMicrophoneAudio = { [weak self] data in
            guard
                let self,
                canSendMicrophoneAudio,
                let client = realtimeClient
            else {
                return
            }
            Task {
                await client.sendAudio(data)
            }
        }
        audio.onPlaybackFinished = { [weak self] in
            self?.playbackFinished()
        }
        audio.playbackVolume = Float(playbackVolume)
    }

    func setPlaybackVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        playbackVolume = clamped
        audio.playbackVolume = Float(clamped)
    }

    func toggleVoiceMode() {
        if phase == .speaking {
            interruptSpeaking()
            return
        }

        desiredVoiceMode.toggle()

        if desiredVoiceMode {
            canSendMicrophoneAudio = false
            responseHasAudio = false
            ignoringAssistantOutput = false
            phase = .connecting
            transcript = "Bringing systems online…"
            Task {
                await startVoiceMode()
            }
        } else {
            Task {
                await stopVoiceMode()
            }
        }
    }

    private func startVoiceMode() async {
        guard realtimeClient == nil else { return }

        let client = RealtimeClient(
            apiKey: AppSecrets.openAIAPIKey
        ) { [weak self] event in
            await self?.handle(event)
        }
        realtimeClient = client

        do {
            try await audio.start()
            guard desiredVoiceMode else {
                audio.stop()
                realtimeClient = nil
                return
            }

            try await client.connect()
            guard desiredVoiceMode else {
                await client.disconnect()
                audio.stop()
                realtimeClient = nil
                return
            }
        } catch {
            let failure: AssistantFailure
            if error is AudioControllerError {
                failure = .audio(error.localizedDescription)
            } else if error is RealtimeClientError {
                failure = .configuration(error.localizedDescription)
            } else {
                failure = .connection(error.localizedDescription)
            }
            desiredVoiceMode = false
            canSendMicrophoneAudio = false
            audio.stop()
            realtimeClient = nil
            ignoringAssistantOutput = false
            phase = .failed(failure)
            transcript = failure.message
        }
    }

    private func interruptSpeaking() {
        ignoringAssistantOutput = true
        responseHasAudio = false
        canSendMicrophoneAudio = true
        audio.stopPlayback()
        phase = .listening
        transcript = Self.listeningPrompt

        let client = realtimeClient
        Task {
            await client?.cancelResponse()
        }
    }

    private func stopVoiceMode() async {
        let client = realtimeClient
        realtimeClient = nil
        canSendMicrophoneAudio = false
        responseHasAudio = false
        ignoringAssistantOutput = false
        audio.stop()
        await client?.disconnect()
        phase = .off
        transcript = "Tap on the mic to start."
    }

    private func handle(_ event: RealtimeEvent) async {
        guard desiredVoiceMode else { return }

        switch event {
        case .connected:
            ignoringAssistantOutput = false
            #if targetEnvironment(simulator)
            transcript = Self.listeningPrompt
            #else
            transcript = "Connected. You can speak."
            #endif

        case .reconnecting:
            canSendMicrophoneAudio = false
            responseHasAudio = false
            ignoringAssistantOutput = false
            phase = .connecting
            transcript = "Reconnecting…"
            await audio.renewAudioSession()

        case .listening:
            // Only the first session.updated marks ready. Later instruction
            // refreshes (after memory tools) must not yank the UI back here.
            guard phase == .connecting else { return }
            canSendMicrophoneAudio = true
            phase = .listening
            transcript = Self.listeningPrompt

        case .userStartedSpeaking:
            guard canSendMicrophoneAudio else { return }
            ignoringAssistantOutput = false
            phase = .listening
            transcript = "Listening…"

        case .userStoppedSpeaking:
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            responseHasAudio = false
            phase = .thinking
            transcript = "One moment…"

        case .searching:
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            phase = .searching
            transcript = "Looking that up…"

        case .saving:
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            phase = .saving
            transcript = "Saving…"

        case .clearing:
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            phase = .clearing
            transcript = "Clearing…"

        case .assistantAudio(let data):
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            responseHasAudio = true
            if phase != .speaking {
                transcript = ""
            }
            phase = .speaking
            audio.play(pcm16: data)

        case .assistantTranscriptDelta:
            guard !ignoringAssistantOutput else { return }
            canSendMicrophoneAudio = false
            phase = .speaking
            transcript = ""

        case .responseFinished:
            guard !ignoringAssistantOutput else { return }
            if !responseHasAudio {
                canSendMicrophoneAudio = true
                phase = .listening
                transcript = Self.listeningPrompt
            }

        case .disconnected:
            desiredVoiceMode = false
            canSendMicrophoneAudio = false
            responseHasAudio = false
            ignoringAssistantOutput = false
            audio.stop()
            realtimeClient = nil
            phase = .off

        case .failed(let failure):
            desiredVoiceMode = false
            canSendMicrophoneAudio = false
            responseHasAudio = false
            ignoringAssistantOutput = false
            audio.stop()
            let client = realtimeClient
            realtimeClient = nil
            phase = .failed(failure)
            transcript = failure.message
            await client?.disconnect()
        }
    }

    private func playbackFinished() {
        guard desiredVoiceMode, responseHasAudio, !ignoringAssistantOutput else { return }
        responseHasAudio = false
        canSendMicrophoneAudio = true
        phase = .listening
        transcript = Self.listeningPrompt
    }

    private static var listeningPrompt: String {
        #if targetEnvironment(simulator)
        "Simulator has no mic. Use a physical Apple Watch to speak."
        #else
        "I'm listening."
        #endif
    }
}
