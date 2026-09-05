@preconcurrency import AVFAudio
import Foundation

@MainActor
final class AudioController {
    var onMicrophoneAudio: ((Data) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    var playbackVolume: Float = 1 {
        didSet {
            applyPlaybackVolume()
        }
    }

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: RealtimePCMConverter?
    private var playbackConverter: BufferPCMConverter?
    private var microphoneTapFormat: AVAudioFormat?
    private var microphoneTapInstalled = false
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration = 0
    private var playbackSettledTask: Task<Void, Never>?
    private var audioSessionRenewalTask: Task<Void, Never>?

    private let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        #if !targetEnvironment(simulator)
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            throw AudioControllerError.microphonePermissionDenied
        }

        try session.setCategory(.playAndRecord, mode: .voiceChat)
        #else
        try session.setCategory(.playback, mode: .default)
        #endif
        try await activate(session)

        #if targetEnvironment(simulator)
        try startSimulatorEngine()
        #else
        try configureDeviceEngine()
        try installMicrophoneTap()
        engine.prepare()
        try engine.start()
        #endif

        applyPlaybackVolume()
        startAudioSessionRenewal()
    }

    #if !targetEnvironment(simulator)
    private func configureDeviceEngine() throws {
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: realtimeFormat)
        }
        applyPlaybackVolume()

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        try installMicrophoneConverter(inputFormat: input.outputFormat(forBus: 0))
    }
    #endif

    #if targetEnvironment(simulator)
    private func startSimulatorEngine() throws {
        rebuildEngine()
        engine.attach(player)

        let graphFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: graphFormat)
        applyPlaybackVolume()

        guard
            let playbackConverter = BufferPCMConverter(
                inputFormat: realtimeFormat,
                outputFormat: graphFormat
            )
        else {
            throw AudioControllerError.unsupportedAudioFormat
        }
        self.playbackConverter = playbackConverter

        engine.prepare()
        try engine.start()
    }

    private func rebuildEngine() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        converter = nil
        playbackConverter = nil
        microphoneTapFormat = nil
    }
    #endif

    private func installMicrophoneTap() throws {
        guard let converter, let microphoneTapFormat, !microphoneTapInstalled else {
            throw AudioControllerError.unsupportedAudioFormat
        }

        let deliverAudio: @Sendable (Data) -> Void = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.onMicrophoneAudio?(data)
            }
        }
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: microphoneTapFormat,
            block: MicrophoneTap.make(
                converter: converter,
                deliverAudio: deliverAudio
            )
        )
        microphoneTapInstalled = true
    }

    private func installMicrophoneConverter(inputFormat: AVAudioFormat) throws {
        guard
            Self.isValid(inputFormat),
            let converter = RealtimePCMConverter(
                inputFormat: inputFormat,
                outputFormat: realtimeFormat
            )
        else {
            throw AudioControllerError.unsupportedAudioFormat
        }
        self.converter = converter
        microphoneTapFormat = inputFormat
    }

    private static func isValid(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func applyPlaybackVolume() {
        player.volume = min(max(playbackVolume, 0), 1)
    }

    private func activate(_ session: AVAudioSession) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: AudioControllerError.audioSessionActivationFailed
                    )
                }
            }
        }
    }

    func renewAudioSession() async {
        try? await activate(AVAudioSession.sharedInstance())
    }

    private func startAudioSessionRenewal() {
        audioSessionRenewalTask?.cancel()
        // Work around watchOS 26 revoking the TN3135 networking grant roughly
        // 36 seconds after audio-session activation (FB24377808).
        audioSessionRenewalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(25))
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else { return }
                await self.renewAudioSession()
            }
        }
    }

    func stop() {
        audioSessionRenewalTask?.cancel()
        audioSessionRenewalTask = nil
        if microphoneTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        resetPlaybackTracking()
        player.stop()
        engine.stop()
        converter = nil
        playbackConverter = nil
        microphoneTapFormat = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func play(pcm16 data: Data) {
        guard !data.isEmpty else { return }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard
            frameCount > 0,
            let source = AVAudioPCMBuffer(
                pcmFormat: realtimeFormat,
                frameCapacity: frameCount
            ),
            let channel = source.int16ChannelData?[0]
        else {
            return
        }

        source.frameLength = frameCount
        _ = data.copyBytes(
            to: UnsafeMutableBufferPointer(start: channel, count: Int(frameCount))
        )

        let buffer: AVAudioPCMBuffer
        if let playbackConverter {
            guard let converted = playbackConverter.convert(source) else { return }
            buffer = converted
        } else {
            buffer = source
        }

        pendingPlaybackBuffers += 1
        playbackSettledTask?.cancel()
        let generation = playbackGeneration
        let deliverCompletion: @Sendable (Int) -> Void = { [weak self] generation in
            Task { @MainActor [weak self] in
                self?.playbackBufferFinished(generation: generation)
            }
        }
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack,
            completionHandler: PlaybackCompletion.make(
                generation: generation,
                deliverCompletion: deliverCompletion
            )
        )

        if !player.isPlaying {
            player.play()
        }
    }

    private func playbackBufferFinished(generation: Int) {
        guard generation == playbackGeneration else { return }
        pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
        guard pendingPlaybackBuffers == 0 else { return }

        playbackSettledTask?.cancel()
        playbackSettledTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard
                !Task.isCancelled,
                let self,
                generation == playbackGeneration,
                pendingPlaybackBuffers == 0
            else {
                return
            }
            onPlaybackFinished?()
        }
    }

    private func resetPlaybackTracking() {
        playbackGeneration += 1
        pendingPlaybackBuffers = 0
        playbackSettledTask?.cancel()
        playbackSettledTask = nil
    }
}

private enum PlaybackCompletion {
    static func make(
        generation: Int,
        deliverCompletion: @escaping @Sendable (Int) -> Void
    ) -> AVAudioPlayerNodeCompletionHandler {
        { _ in
            deliverCompletion(generation)
        }
    }
}

private enum MicrophoneTap {
    static func make(
        converter: RealtimePCMConverter,
        deliverAudio: @escaping @Sendable (Data) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let data = converter.convert(buffer) {
                deliverAudio(data)
            }
        }
    }
}

private final class RealtimePCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(inputBuffer.frameLength) * ratio))
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if inputState.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard
            status != .error,
            conversionError == nil,
            outputBuffer.frameLength > 0,
            let channel = outputBuffer.int16ChannelData?[0]
        else {
            return nil
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel, count: byteCount)
    }
}

private final class BufferPCMConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(inputBuffer.frameLength) * ratio))
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            if inputState.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var supplied = false
}

enum AudioControllerError: LocalizedError {
    case microphonePermissionDenied
    case unsupportedAudioFormat
    case audioSessionActivationFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for voice mode."
        case .unsupportedAudioFormat:
            return "This device's microphone format could not be converted."
        case .audioSessionActivationFailed:
            return "The watch could not activate its audio session."
        }
    }
}
