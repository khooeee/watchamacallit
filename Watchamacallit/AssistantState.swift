import Foundation

enum AssistantPhase: Equatable {
    case off
    case connecting
    case listening
    case thinking
    case searching
    case speaking
    case failed(AssistantFailure)

    var label: String {
        switch self {
        case .off:
            return "WELCOME"
        case .connecting:
            return "CONNECTING"
        case .listening:
            return "LISTENING"
        case .thinking:
            return "THINKING"
        case .searching:
            return "SEARCHING"
        case .speaking:
            return "SPEAKING"
        case .failed(let failure):
            return failure.label
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .searching, .speaking:
            return true
        case .off, .failed:
            return false
        }
    }
}

enum AssistantFailure: Equatable, Sendable {
    case connection(String)
    case rateLimited(String)
    case api(String)
    case configuration(String)
    case audio(String)

    var label: String {
        switch self {
        case .connection:
            return "CONNECTION ERROR"
        case .rateLimited:
            return "RATE LIMITED"
        case .api:
            return "API ERROR"
        case .configuration:
            return "SETUP ERROR"
        case .audio:
            return "AUDIO ERROR"
        }
    }

    var message: String {
        switch self {
        case .connection(let message),
             .rateLimited(let message),
             .api(let message),
             .configuration(let message),
             .audio(let message):
            return message
        }
    }
}

enum RealtimeEvent: Sendable {
    case connected
    case reconnecting
    case listening
    case userStartedSpeaking
    case userStoppedSpeaking
    case searching
    case assistantAudio(Data)
    case assistantTranscriptDelta(String)
    case responseFinished
    case disconnected
    case failed(AssistantFailure)
}
