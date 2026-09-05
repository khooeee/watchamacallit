import Foundation

struct WebSearchClient: Sendable {
    private let apiKey: String
    private let urlSession: URLSession

    init(apiKey: String, urlSession: URLSession) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    func search(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.encoded(["error": "The search query was empty."])
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4.1-mini",
            "tools": [[
                "type": "web_search",
                "search_context_size": "low"
            ]],
            "tool_choice": "required",
            "input": """
            Search the live web for this query and return a brief factual summary \
            for a spoken watch assistant. Use 4 to 8 short sentences. Prefer current \
            facts, numbers, names, and dates. Do not use markdown. Query: \(trimmed)
            """
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if status >= 400 {
                let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                    ?? "Web search failed (\(status))."
                return Self.encoded(["error": message])
            }

            guard let text = Self.outputText(from: object), !text.isEmpty else {
                return Self.encoded(["error": "Web search returned no readable result."])
            }

            return Self.encoded(["result": Self.condensed(text)])
        } catch is CancellationError {
            return Self.encoded(["error": "The search was cancelled."])
        } catch {
            return Self.encoded(["error": error.localizedDescription])
        }
    }

    private static func outputText(from object: [String: Any]?) -> String? {
        guard let object else { return nil }

        if let text = object["output_text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard let output = object["output"] as? [Any] else { return nil }
        var parts: [String] = []

        for item in output {
            guard
                let dict = item as? [String: Any],
                dict["type"] as? String == "message",
                let content = dict["content"] as? [Any]
            else {
                continue
            }

            for part in content {
                guard
                    let partDict = part as? [String: Any],
                    let text = partDict["text"] as? String
                else {
                    continue
                }

                let type = partDict["type"] as? String
                if type == "output_text" || type == "text" {
                    parts.append(text)
                }
            }
        }

        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func condensed(_ text: String, limit: Int = 2_400) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    static func encoded(_ object: [String: String]) -> String {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"Could not encode search results.\"}"
        }
        return text
    }
}
