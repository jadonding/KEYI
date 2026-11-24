import Foundation

public struct APIProviderConfiguration: Sendable {
    public let providerID: TranslationProviderID
    public let apiKey: String
    public let endpoint: URL
    public let model: String

    public init(
        providerID: TranslationProviderID,
        apiKey: String,
        endpoint: URL,
        model: String
    ) {
        self.providerID = providerID
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
    }
}

public struct OpenAICompatibleTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let session: URLSession
    private let usageRecorder: (@Sendable (TranslationProviderID, APITokenUsage) -> Void)?

    /// `usageRecorder` 收到每次成功返回里的 token 用量（统计费用用）；返回里没有 `usage` 时不调用。
    public init(
        configuration: APIProviderConfiguration,
        session: URLSession = .shared,
        usageRecorder: (@Sendable (TranslationProviderID, APITokenUsage) -> Void)? = nil
    ) {
        id = configuration.providerID
        apiKey = configuration.apiKey
        endpoint = configuration.endpoint
        model = configuration.model
        self.session = session
        self.usageRecorder = usageRecorder
    }

    public func translate(_ request: TextTranslationRequest) async throws -> String {
        guard !request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APITranslationError.emptySource
        }
        return try await complete(
            system: TranslationPromptBuilder.systemPrompt(for: request),
            user: TranslationPromptBuilder.userPrompt(for: request),
            temperature: request.scene == .faithful ? 0 : 0.2
        )
    }

    /// 个人术语表：请同一个大模型服务从这批「原文 → 译文」里挑出固定词对。用量照常记账。
    public func extractGlossary(from samples: [PersonalGlossary.Sample]) async throws -> [(source: String, target: String)] {
        guard !samples.isEmpty else { return [] }
        let reply = try await complete(
            system: PersonalGlossary.extractionSystemPrompt,
            user: PersonalGlossary.extractionUserPrompt(samples),
            temperature: 0
        )
        return PersonalGlossary.parseExtraction(reply)
    }

    private func complete(system: String, user: String, temperature: Double) async throws -> String {
        let body = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "system", content: system),
                    ChatMessage(role: "user", content: user)
                ],
                temperature: temperature
            )
        )

        let (data, statusCode) = try await send(body)

        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(
                APIErrorResponse.self,
                from: data
            ))?.error?.message
            throw APITranslationError.httpFailure(
                providerID: id,
                statusCode: statusCode,
                message: message
            )
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw APITranslationError.invalidResponse
        }
        // 截断、空结果也照样计费，所以先记用量再判断。
        if let usage = decoded.usage {
            usageRecorder?(id, APITokenUsage(
                inputTokens: usage.promptTokens ?? 0,
                outputTokens: usage.completionTokens ?? 0
            ))
        }
        let choice = decoded.choices.first
        guard choice?.finishReason != "length" else {
            throw APITranslationError.truncatedResponse(providerID: id)
        }
        let content = choice?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            throw APITranslationError.emptyResponse(providerID: id)
        }
        return content
    }

    private func send(_ body: Data) async throws -> (Data, Int) {
        let timeout: TimeInterval = 45
        if endpoint.scheme?.lowercased() == "http" {
            guard id == .relay else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
            return try await PlainHTTPModelClient.post(to: endpoint, apiKey: apiKey, body: body, timeout: timeout)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APITranslationError.invalidResponse
        }
        return (data, httpResponse.statusCode)
    }
}

private struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]
    let usage: Usage?

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct Choice: Decodable, Sendable {
        let message: ChatMessage
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}

private struct APIErrorResponse: Decodable, Sendable {
    let error: ErrorPayload?

    struct ErrorPayload: Decodable, Sendable {
        let message: String?
    }
}

/// 云端提供方错误只携带结构化数据；用户可见文案由 UI 层
/// （InterfaceLocalization 的扩展）按当前界面语言渲染。
public enum APITranslationError: Error {
    case emptySource
    case invalidResponse
    case emptyResponse(providerID: TranslationProviderID)
    case truncatedResponse(providerID: TranslationProviderID)
    case httpFailure(
        providerID: TranslationProviderID,
        statusCode: Int,
        message: String?
    )
}
