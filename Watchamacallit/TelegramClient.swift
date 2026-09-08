import Foundation

struct TelegramClient: Sendable {
    private let botToken: String
    private let chatID: String
    private let urlSession: URLSession

    init(botToken: String, chatID: String, urlSession: URLSession) {
        self.botToken = botToken
        self.chatID = chatID
        self.urlSession = urlSession
    }

    func sendReminders(_ items: [ReminderItem]) async -> String {
        guard isConfigured else {
            return Self.encode([
                "error": "Add telegramBotToken and telegramChatID in AppSecrets.swift."
            ])
        }

        guard !items.isEmpty else {
            return Self.encode([
                "ok": true,
                "count": 0,
                "sent": false
            ])
        }

        let text = Self.formatMessage(items)
        let endpoint = "https://api.telegram.org/bot\(botToken)/sendMessage"
        guard let url = URL(string: endpoint) else {
            return Self.encode(["error": "Invalid Telegram bot token."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatID,
            "text": text,
            "disable_web_page_preview": true
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if status >= 400 || object?["ok"] as? Bool != true {
                let description = (object?["description"] as? String)
                    ?? "Telegram send failed (\(status))."
                return Self.encode(["error": description])
            }

            return Self.encode([
                "ok": true,
                "count": items.count,
                "sent": true
            ])
        } catch is CancellationError {
            return Self.encode(["error": "The Telegram send was cancelled."])
        } catch {
            return Self.encode(["error": error.localizedDescription])
        }
    }

    private var isConfigured: Bool {
        let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !chat.isEmpty else { return false }
        guard token != "your-telegram-bot-token" else { return false }
        guard chat != "your-telegram-chat-id" else { return false }
        return true
    }

    private static func formatMessage(_ items: [ReminderItem]) -> String {
        var lines = ["Reminders (\(items.count)):"]
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). \(item.content)")
        }
        let text = lines.joined(separator: "\n")
        let limit = 4_096
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit - 1)
        return String(text[..<end]) + "…"
    }

    static func encode(_ object: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"Could not encode Telegram result.\"}"
        }
        return text
    }
}
