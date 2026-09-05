import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var phase: AssistantPhase = .off
    @Published private(set) var transcript = "Ready when you are."
    @Published var playbackVolume: Double = 1

    private let audio = AudioController()
    private var realtimeClient: RealtimeClient?
    private var desiredVoiceMode = false
    private var canSendMicrophoneAudio = false
    private var responseHasAudio = false

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
        desiredVoiceMode.toggle()

        if desiredVoiceMode {
            canSendMicrophoneAudio = false
            responseHasAudio = false
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
            phase = .failed(failure)
            transcript = failure.message
        }
    }

    private func stopVoiceMode() async {
        let client = realtimeClient
        realtimeClient = nil
        canSendMicrophoneAudio = false
        responseHasAudio = false
        audio.stop()
        await client?.disconnect()
        phase = .off
        transcript = "Ready when you are."
    }

    private func handle(_ event: RealtimeEvent) async {
        guard desiredVoiceMode else { return }

        switch event {
        case .connected:
            #if targetEnvironment(simulator)
            transcript = Self.listeningPrompt
            #else
            transcript = "Connected. You can speak."
            #endif

        case .reconnecting:
            canSendMicrophoneAudio = false
            responseHasAudio = false
            phase = .connecting
            transcript = "Reconnecting…"
            await audio.renewAudioSession()

        case .listening:
            canSendMicrophoneAudio = true
            phase = .listening
            transcript = Self.listeningPrompt

        case .userStartedSpeaking:
            guard canSendMicrophoneAudio else { return }
            phase = .listening
            transcript = "Listening…"

        case .userStoppedSpeaking:
            canSendMicrophoneAudio = false
            responseHasAudio = false
            phase = .thinking
            transcript = "One moment…"

        case .searching:
            canSendMicrophoneAudio = false
            phase = .searching
            transcript = "Looking that up…"

        case .assistantAudio(let data):
            canSendMicrophoneAudio = false
            responseHasAudio = true
            if phase != .speaking {
                transcript = ""
            }
            phase = .speaking
            audio.play(pcm16: data)

        case .assistantTranscriptDelta:
            canSendMicrophoneAudio = false
            phase = .speaking
            transcript = ""

        case .responseFinished:
            if !responseHasAudio {
                canSendMicrophoneAudio = true
                phase = .listening
                transcript = Self.listeningPrompt
            }

        case .disconnected:
            desiredVoiceMode = false
            canSendMicrophoneAudio = false
            responseHasAudio = false
            audio.stop()
            realtimeClient = nil
            phase = .off

        case .failed(let failure):
            desiredVoiceMode = false
            canSendMicrophoneAudio = false
            responseHasAudio = false
            audio.stop()
            let client = realtimeClient
            realtimeClient = nil
            phase = .failed(failure)
            transcript = failure.message
            await client?.disconnect()
        }
    }

    private func playbackFinished() {
        guard desiredVoiceMode, responseHasAudio else { return }
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
