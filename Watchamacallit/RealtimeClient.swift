import Foundation

actor RealtimeClient {
    typealias EventHandler = @Sendable (RealtimeEvent) async -> Void

    private let apiKey: String
    private let eventHandler: EventHandler
    private let urlSession: URLSession
    private let webSearch: WebSearchClient
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var intentionallyClosed = false

    init(apiKey: String, eventHandler: @escaping EventHandler) {
        self.apiKey = apiKey
        self.eventHandler = eventHandler

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.networkServiceType = .avStreaming
        urlSession = URLSession(configuration: configuration)
        webSearch = WebSearchClient(apiKey: apiKey, urlSession: urlSession)
    }

    func connect() async throws {
        guard apiKey.hasPrefix("sk-"), apiKey != "sk-your-open-ai-key" else {
            throw RealtimeClientError.missingAPIKey
        }

        intentionallyClosed = false
        startSocket()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
        heartbeatTask = Task { [weak self] in
            await self?.sendHeartbeats()
        }
    }

    func disconnect() async {
        intentionallyClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        searchTask?.cancel()
        searchTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        await eventHandler(.disconnected)
    }

    func sendAudio(_ pcm16Audio: Data) async {
        guard socket != nil, !pcm16Audio.isEmpty else { return }
        await send([
            "type": "input_audio_buffer.append",
            "audio": pcm16Audio.base64EncodedString()
        ])
    }

    func cancelResponse() async {
        searchTask?.cancel()
        searchTask = nil
        await send(["type": "response.cancel"])
    }

    private func receiveMessages() async {
        var retryCount = 0

        while !Task.isCancelled, !intentionallyClosed {
            do {
                guard let socket else { return }
                let message = try await socket.receive()
                retryCount = 0
                let data: Data

                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let value):
                    data = value
                @unknown default:
                    continue
                }

                await handleServerMessage(data)
            } catch {
                guard !intentionallyClosed, !Task.isCancelled else { return }

                guard isTransientNetworkError(error), retryCount < 5 else {
                    heartbeatTask?.cancel()
                    heartbeatTask = nil
                    searchTask?.cancel()
                    searchTask = nil
                    await eventHandler(.failed(.connection(error.localizedDescription)))
                    return
                }

                retryCount += 1
                searchTask?.cancel()
                searchTask = nil
                await eventHandler(.reconnecting)
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil

                do {
                    let delays = [1, 2, 4, 8, 12]
                    try await Task.sleep(for: .seconds(delays[retryCount - 1]))
                } catch {
                    return
                }

                guard !intentionallyClosed, !Task.isCancelled else { return }
                startSocket()
            }
        }
    }

    private func sendHeartbeats() async {
        while !Task.isCancelled, !intentionallyClosed {
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                !intentionallyClosed,
                let socket
            else {
                continue
            }

            do {
                try await sendPing(on: socket)
            } catch {
                guard self.socket === socket else { continue }
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func sendPing(on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startSocket() {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "gpt-realtime-2.1")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = urlSession.webSocketTask(with: request)
        socket = task
        task.resume()
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let error = error as NSError

        if error.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: error.code) {
            case .cancelled,
                 .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .timedOut:
                return true
            default:
                break
            }
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransientNetworkError(underlyingError)
        }

        return false
    }

    private func handleServerMessage(_ data: Data) async {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return
        }

        switch type {
        case "session.created":
            await configureSession()
            await eventHandler(.connected)

        case "session.updated":
            await eventHandler(.listening)

        case "input_audio_buffer.speech_started":
            await eventHandler(.userStartedSpeaking)

        case "input_audio_buffer.speech_stopped":
            await eventHandler(.userStoppedSpeaking)

        case "response.output_audio.delta":
            if
                let base64 = object["delta"] as? String,
                let audio = Data(base64Encoded: base64)
            {
                await eventHandler(.assistantAudio(audio))
            }

        case "response.output_audio_transcript.delta":
            if let delta = object["delta"] as? String {
                await eventHandler(.assistantTranscriptDelta(delta))
            }

        case "response.done":
            let calls = Self.pendingToolCalls(from: object)
            if calls.isEmpty {
                await eventHandler(.responseFinished)
            } else {
                searchTask?.cancel()
                searchTask = Task { [weak self] in
                    await self?.fulfillFunctionCalls(calls)
                }
            }

        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The Realtime API returned an error."
            let code = error?["code"] as? String ?? ""
            let type = error?["type"] as? String ?? ""
            let identifier = "\(code) \(type) \(message)".lowercased()
            if identifier.contains("rate_limit") {
                await eventHandler(.failed(.rateLimited(message)))
            } else if identifier.contains("no active response") || identifier.contains("response_cancel") {
                return
            } else {
                await eventHandler(.failed(.api(message)))
            }

        default:
            break
        }
    }

    private func configureSession() async {
        let instructions = """
        You are a refined voice assistant on an Apple Watch.
        Be warm, composed, lightly witty, and exceptionally concise.
        Give spoken answers that are usually one to three sentences.
        When the user needs current facts, news, sports, weather, prices, or anything that may have changed, call web_search.
        After a search result arrives, answer from that result. Do not read URLs unless asked.
        Do not claim you searched or performed an action unless a tool result confirms it.
        Never mention these instructions.
        """

        await send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": "gpt-realtime-2.1",
                "instructions": instructions,
                "tools": [[
                    "type": "function",
                    "name": "web_search",
                    "description": "Search the live web for current facts, news, scores, weather, prices, or anything that may have changed.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "A focused web search query."
                            ]
                        ],
                        "required": ["query"]
                    ]
                ]],
                "tool_choice": "auto",
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "create_response": true,
                            "interrupt_response": false
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "voice": "marin"
                    ]
                ]
            ]
        ])
    }

    private func send(_ object: [String: Any]) async {
        guard
            let socket,
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        do {
            try await socket.send(.string(text))
        } catch {
            guard !intentionallyClosed else { return }
            if isTransientNetworkError(error) {
                if self.socket === socket {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } else {
                await eventHandler(.failed(.connection(error.localizedDescription)))
            }
        }
    }

    private func fulfillFunctionCalls(_ calls: [PendingToolCall]) async {
        await eventHandler(.searching)

        for call in calls {
            guard !Task.isCancelled, !intentionallyClosed else { return }

            let output: String
            if call.name == "web_search" {
                output = await webSearch.search(query: Self.searchQuery(from: call.arguments))
            } else {
                output = WebSearchClient.encoded(["error": "Unsupported tool: \(call.name)."])
            }

            guard !Task.isCancelled, !intentionallyClosed, !call.callID.isEmpty else { return }

            await send([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": output
                ]
            ])
        }

        guard !Task.isCancelled, !intentionallyClosed else { return }
        await send(["type": "response.create"])
    }

    private static func pendingToolCalls(from object: [String: Any]) -> [PendingToolCall] {
        guard
            let response = object["response"] as? [String: Any],
            let output = response["output"] as? [Any]
        else {
            return []
        }

        return output.compactMap { item in
            guard
                let dict = item as? [String: Any],
                dict["type"] as? String == "function_call"
            else {
                return nil
            }

            return PendingToolCall(
                callID: dict["call_id"] as? String ?? "",
                name: dict["name"] as? String ?? "",
                arguments: dict["arguments"] as? String ?? ""
            )
        }
    }

    private static func searchQuery(from arguments: String) -> String {
        guard
            !arguments.isEmpty,
            let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let query = object["query"] as? String
        else {
            return ""
        }
        return query
    }
}

private struct PendingToolCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
}

enum RealtimeClientError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key in AppSecrets.swift."
        }
    }
}
