import Foundation

public enum TranslationError: LocalizedError, Sendable {
    case notConfigured
    case emptyAPIKey
    case invalidResponse
    case httpStatus(Int)
    case countMismatch(expected: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "No translation provider is configured.", bundle: .module)
        case .emptyAPIKey: String(localized: "The translation provider needs an API key.", bundle: .module)
        case .invalidResponse: String(localized: "The translation service returned an invalid response.", bundle: .module)
        case let .httpStatus(status): String(localized: "The translation service returned HTTP \(status).", bundle: .module)
        case let .countMismatch(expected, received):
            String(localized: "The translation service returned \(received) results for \(expected) texts.", bundle: .module)
        }
    }
}

/// An independent translation service (spec §11). Providers come and go;
/// community content always keeps its original text and stores translations
/// separately, so this layer never becomes a content dependency.
public protocol TranslationService: Sendable {
    var providerID: String { get }
    /// Translates a batch of texts in a single request; results are returned
    /// in the same order as the input.
    func translate(_ texts: [String], to targetLanguage: String) async throws -> [String]
}

/// DeepL's official API. Free keys (ending in ":fx") use the free endpoint;
/// the batch of texts is sent as one request.
public struct DeepLTranslationService: TranslationService {
    public let providerID = "deepl"
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func translate(_ texts: [String], to targetLanguage: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw TranslationError.emptyAPIKey }
        guard !texts.isEmpty else { return [] }
        let host = apiKey.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        var request = URLRequest(url: URL(string: "\(host)/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RequestBody(text: texts, targetLang: normalized(targetLanguage))
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TranslationError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let translated = decoded.translations.map(\.text)
        guard translated.count == texts.count else {
            throw TranslationError.countMismatch(expected: texts.count, received: translated.count)
        }
        return translated
    }

    /// DeepL expects upper-case codes and treats "EN" specially; keep the
    /// caller-facing codes stable ("zh", "zh-Hant", "en", "ja").
    private func normalized(_ language: String) -> String {
        switch language.lowercased() {
        case "zh", "zh-hans": "ZH"
        case "zh-hant": "ZH"
        case "en": "EN-US"
        case "pt": "PT-BR"
        default: language.uppercased()
        }
    }

    private struct RequestBody: Encodable {
        let text: [String]
        let targetLang: String

        enum CodingKeys: String, CodingKey {
            case text
            case targetLang = "target_lang"
        }
    }

    private struct ResponseBody: Decodable {
        let translations: [Translation]

        struct Translation: Decodable {
            let detectedSourceLanguage: String?
            let text: String

            enum CodingKeys: String, CodingKey {
                case text
                case detectedSourceLanguage = "detected_source_language"
            }
        }
    }
}

public enum TranslationLanguage: String, CaseIterable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}
