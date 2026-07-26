import Foundation

// MARK: - LLM-Powered OCR Cleanup Service
//
// Sends raw OCR text to OpenAI's Chat Completions API to extract structured
// medication data. Used as a fallback when the rule-based parser has low
// confidence or is missing critical fields (drug name, dosage).

@MainActor
final class LLMService {

    static let shared = LLMService()

    private var apiKey: String {
        ServerConfiguration.shared.openAIAPIKey
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    private init() {}

    // MARK: - LLM Medication Refinement

    struct LLMRefinementResult: Codable {
        let medicationName: String?
        let dosage: String?
        let form: String?
        let frequency: String?
        let instructions: String?
        let ndc: String?
        let din: String?
        let confidence: Double

        enum CodingKeys: String, CodingKey {
            case medicationName = "medication_name"
            case dosage, form, frequency, instructions, ndc, din, confidence
        }
    }

    /// Send raw OCR text to OpenAI for structured medication extraction.
    /// Returns a LLMRefinementResult with corrected/extracted fields.
    func refineOCR(_ rawOCRText: String, partialResult: ParsedMedicationInfo? = nil) async throws -> LLMRefinementResult {
        guard isConfigured else {
            throw LLMError.notConfigured
        }

        var prompt = """
        You are a medication label OCR cleanup assistant. You receive noisy OCR text
        scanned from prescription pill bottles and medication packaging.

        RULES:
        1. ONLY correct obvious OCR errors (0→O, 1→l, €→e, etc.)
        2. NEVER invent medications that don't exist in the text
        3. If you can't determine a field, use null
        4. NDC numbers are 11 digits with dashes (XXX-XXXX-XX) or 10 digits
        5. DIN is 8 digits
        6. Dosages use standard units: mg, mcg, g, mL, units
        7. Common forms: tablet, capsule, liquid, injection, cream, patch, drops, suspension
        8. Frequency examples: once daily, twice daily, 3 times daily, as needed, every 8 hours

        Return ONLY valid JSON with this exact structure:
        {
          "medication_name": "corrected name or null",
          "dosage": "e.g. 500mg or null",
          "form": "tablet/capsule/liquid/etc or null",
          "frequency": "e.g. once daily or null",
          "instructions": "e.g. take with food or null",
          "ndc": "XXX-XXXX-XX or null",
          "din": "8 digits or null",
          "confidence": 0.0 to 1.0
        }

        """

        if let partial = partialResult {
            prompt += """
            A rule-based parser already extracted these partial results (confidence may be low).
            Use this as a hint but correct any errors:
            Name: \(partial.drugName ?? "unknown")
            Strength: \(partial.strength ?? "unknown")
            Frequency: \(partial.frequency ?? "unknown")
            Instructions: \(partial.instructions ?? "unknown")
            NDC: \(partial.ndc ?? "unknown")
            DIN: \(partial.din ?? "unknown")

            """
        }

        prompt += """
        OCR text:
        \(rawOCRText)
        """

        let body = OpenAIChatRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIMessage(role: "system", content: """
                You are a medication data extraction assistant. Return ONLY valid JSON.
                Never include explanations, markdown, or text outside the JSON object.
                If a field cannot be determined from the OCR text, set it to null.
                Be conservative — do not guess medication names.
                """),
                OpenAIMessage(role: "user", content: prompt)
            ],
            temperature: 0.1,
            maxTokens: 500,
            responseFormat: .jsonObject
        )

        let requestData = try JSONEncoder().encode(body)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = requestData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("No HTTP response")
        }

        if httpResponse.statusCode == 401 {
            throw LLMError.invalidAPIKey
        } else if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "no body"
            throw LLMError.apiError("OpenAI returned \(httpResponse.statusCode): \(errorText)")
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)

        guard let content = chatResponse.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }

        // Parse the JSON from the LLM response
        let jsonData: Data
        if let dataContent = content.data(using: .utf8) {
            jsonData = dataContent
        } else {
            throw LLMError.parseError("Could not decode LLM response as UTF-8")
        }

        let result = try JSONDecoder().decode(LLMRefinementResult.self, from: jsonData)
        return result
    }

    // MARK: - Merge LLM result with parser result

    static func merge(
        llmResult: LLMRefinementResult,
        with parserResult: ParsedMedicationInfo
    ) -> ParsedMedicationInfo {
        // Only override parser result if LLM confidence is high and parser field is missing/weak
        let llmThreshold = 0.7

        // Determine which values to use
        let drugName: String?
        let strength: String?
        let ndc: String?
        let din: String?
        let frequency: String?
        let instructions: String?

        if llmResult.confidence >= llmThreshold {
            drugName = parserResult.drugName ?? llmResult.medicationName
            strength = parserResult.strength ?? llmResult.dosage
            ndc = parserResult.ndc ?? llmResult.ndc
            din = parserResult.din ?? llmResult.din
            frequency = parserResult.frequency ?? llmResult.frequency
            instructions = parserResult.instructions ?? llmResult.instructions
        } else {
            // LLM confidence too low - use parser results only
            drugName = parserResult.drugName
            strength = parserResult.strength
            ndc = parserResult.ndc
            din = parserResult.din
            frequency = parserResult.frequency
            instructions = parserResult.instructions
        }

        // Create a new ParsedMedicationInfo with merged values
        return ParsedMedicationInfo(
            drugName: drugName,
            genericName: parserResult.genericName,
            strength: strength,
            frequency: frequency,
            instructions: instructions,
            suggestedTimeWindows: parserResult.suggestedTimeWindows,
            ndc: ndc,
            din: din,
            quantity: parserResult.quantity,
            expirationDate: parserResult.expirationDate,
            warnings: parserResult.warnings
        )
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case notConfigured
    case invalidAPIKey
    case networkError(String)
    case apiError(String)
    case emptyResponse
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenAI API key not configured. Go to Settings to add it."
        case .invalidAPIKey:
            return "Invalid OpenAI API key. Check your settings."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .apiError(let msg):
            return "API error: \(msg)"
        case .emptyResponse:
            return "OpenAI returned an empty response."
        case .parseError(let msg):
            return "Could not parse response: \(msg)"
        }
    }
}

// MARK: - OpenAI API Models

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }

    struct ResponseFormat: Encodable {
        let type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIChatResponse: Decodable {
    let choices: [OpenAIChoice]

    struct OpenAIChoice: Decodable {
        let message: OpenAIMessageContent
    }

    struct OpenAIMessageContent: Decodable {
        let content: String?
    }
}
