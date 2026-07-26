import Foundation

// MARK: - Parsed Medication Info
//
// Structured data extracted from OCR text

struct ParsedMedicationInfo {
    let drugName: String?
    let genericName: String?
    let strength: String?
    let frequency: String?           // e.g., "once daily", "twice daily"
    let instructions: String?        // Full instruction text
    let suggestedTimeWindows: [String]  // e.g., ["Morning", "Dinner"]
    let ndc: String?
    let din: String?
    let quantity: String?
    let expirationDate: String?
    let warnings: [String]
    
    var isEmpty: Bool {
        drugName == nil && genericName == nil && strength == nil
    }
    
    var confidenceScore: Double {
        var score: Double = 0.0
        var maxScore: Double = 0.0
        
        maxScore += 30
        if drugName != nil { score += 30 }
        
        maxScore += 25
        if strength != nil { score += 25 }
        
        maxScore += 20
        if frequency != nil || !instructions.isNilOrEmpty { score += 20 }
        
        maxScore += 15
        if ndc != nil || din != nil { score += 15 }
        
        maxScore += 10
        if genericName != nil { score += 10 }
        
        return maxScore > 0 ? score / maxScore : 0.0
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - Medication Text Parser
//
// Actor-based parser that extracts structured medication information from OCR text

actor MedicationTextParser {
    
    static let shared = MedicationTextParser()
    
    private init() {}
    
    // MARK: - Main parsing method

    func parse(_ text: String) async -> ParsedMedicationInfo {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var drugName: String?
        var genericName: String?
        var strength: String?
        var frequency: String?
        var instructions: String?
        var ndc: String?
        var din: String?
        var quantity: String?
        var expirationDate: String?
        var warnings: [String] = []
        var instructionLines: [String] = []

        for (index, line) in lines.enumerated() {
            let upperLine = line.uppercased()

            // Extract drug name from lines containing dosage units (mg, mcg, etc.)
            // These lines typically have the format: "DRUG NAME STRENGTH FORM"
            if drugName == nil && (line.contains("mg") || line.contains("mcg") || line.contains("mL") || line.contains("TAB") || line.contains("CAP")) {
                // Skip lines that are clearly not drug names (warnings, instructions, codes)
                if !upperLine.contains("WARNING") && !upperLine.contains("CAUTION") &&
                   !upperLine.contains("DIRECTION") && !upperLine.contains("NDC") &&
                   !upperLine.contains("DIN") && !upperLine.contains("LOT") &&
                   !upperLine.contains("EXP") && !upperLine.hasPrefix("#") &&
                   !upperLine.hasPrefix("RX") {
                    drugName = extractDrugName(from: line)
                }
            }

            // Extract strength (10mg, etc.) - skip lines starting with # (Rx numbers)
            if strength == nil && !line.hasPrefix("#") && !line.hasPrefix("Rx") {
                if let extracted = extractStrength(from: line) {
                    strength = extracted
                }
            }

            // Extract frequency and timing
            if let freq = extractFrequency(from: line) {
                frequency = freq
            }

            // Extract NDC
            if ndc == nil, let extracted = extractNDC(from: line) {
                ndc = extracted
            }

            // Extract DIN
            if din == nil, let extracted = extractDIN(from: line) {
                din = extracted
            }

            // Extract quantity
            if quantity == nil, let extracted = extractQuantity(from: line) {
                quantity = extracted
            }

            // Extract expiration
            if expirationDate == nil, let extracted = extractExpiration(from: line) {
                expirationDate = extracted
            }

            // Collect instruction lines
            if upperLine.contains("TAKE") || upperLine.contains("TABLET") ||
               upperLine.contains("DAILY") || upperLine.contains("MOUTH") {
                instructionLines.append(line)
            }

            // Collect warnings
            if upperLine.contains("WARNING") || upperLine.contains("MAY IMPAIR") ||
               upperLine.contains("CAUTION") || upperLine.contains("DO NOT") {
                warnings.append(line)
            }
        }
        
        // Combine instruction lines
        if !instructionLines.isEmpty {
            instructions = instructionLines.joined(separator: " ")
        }
        
        // Suggest time windows based on frequency
        let suggestedWindows = suggestTimeWindows(from: frequency ?? instructions ?? "")
        
        return ParsedMedicationInfo(
            drugName: drugName,
            genericName: genericName,
            strength: strength,
            frequency: frequency,
            instructions: instructions,
            suggestedTimeWindows: suggestedWindows,
            ndc: ndc,
            din: din,
            quantity: quantity,
            expirationDate: expirationDate,
            warnings: warnings
        )
    }
    
    // MARK: - Extraction helpers
    
    private func extractDrugName(from text: String) -> String? {
        // Look for medication name patterns
        // Example: "LISINOPRIL TAB 20MG" -> "Lisinopril"
        //          "AMLODIPINE 10MG" -> "Amlodipine"
        //          "METOPROLOL SUCCINATE ER TAB 50MG" -> "Metoprolol Succinate"

        var name = text

        // Remove strength at the end (e.g., "20MG", "10 mg", "50mcg")
        if let strengthRange = name.range(of: #"\d+\.?\d*\s*(?:mg|mcg|mL|g|meq|MCG|MG|ML|G)\b"#, options: .regularExpression) {
            name = String(name[..<strengthRange.lowerBound])
        }

        // Remove common form indicators (TAB, CAP, ER, SR, etc.)
        name = name.replacingOccurrences(of: #"\s+(TAB|CAP|ER|SR|LA|XL|XR|CR|IR)\b.*"#, with: "", options: .regularExpression)

        // Remove "Mouth" or other trailing words that aren't part of the drug name
        name = name.replacingOccurrences(of: #"\s+(Mouth|MOUTH|mouth)\b.*"#, with: "", options: .regularExpression)

        // Clean up
        name = name.trimmingCharacters(in: .whitespaces)

        // Title case the drug name for better readability
        if name.count >= 2 {
            let words = name.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            if !words.isEmpty {
                name = words.map { word in
                    word.prefix(1).uppercased() + word.dropFirst().lowercased()
                }.joined(separator: " ")
            }
        }

        // Must be at least 3 characters
        return name.count >= 3 ? name : nil
    }
    
    private func extractStrength(from text: String) -> String? {
        // Skip lines that start with # or Rx (these are prescription numbers, not strengths)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("Rx") || trimmed.hasPrefix("RX") {
            return nil
        }

        // Match: 10mg, 10 mg, 10MG, 20 meq, etc.
        let pattern = #"\b(\d+\.?\d*\s*(?:mg|mcg|mL|g|meq|MG|MCG|ML|G|MEQ))\b"#

        if let range = text.range(of: pattern, options: .regularExpression) {
            var strength = String(text[range])
            // Normalize: remove extra spaces, lowercase unit
            strength = strength.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            return strength
        }

        return nil
    }
    
    private func extractFrequency(from text: String) -> String? {
        let upperText = text.uppercased()
        
        // Check for common frequency patterns
        if upperText.contains("ONCE") && (upperText.contains("DAILY") || upperText.contains("DAY")) {
            return "Once daily"
        }
        if upperText.contains("TWICE") && (upperText.contains("DAILY") || upperText.contains("DAY")) {
            return "Twice daily"
        }
        if upperText.contains("THREE TIMES") || upperText.contains("3 TIMES") {
            return "Three times daily"
        }
        if upperText.contains("FOUR TIMES") || upperText.contains("4 TIMES") {
            return "Four times daily"
        }
        if upperText.contains("EVERY") && upperText.contains("HOURS") {
            if let match = text.range(of: #"every\s+(\d+)\s+hours"#, options: [.regularExpression, .caseInsensitive]) {
                return String(text[match])
            }
        }
        if upperText.contains("AT BEDTIME") || upperText.contains("BEFORE BED") {
            return "At bedtime"
        }
        if upperText.contains("IN THE MORNING") {
            return "In the morning"
        }
        if upperText.contains("WITH MEALS") || upperText.contains("BEFORE MEALS") {
            return "With meals"
        }
        
        // Check for "1 TABLET" pattern which often indicates once daily
        if (upperText.contains("1 TABLET") || upperText.contains("TAKE 1")) && 
           (upperText.contains("DAILY") || upperText.contains("DAY")) {
            return "Once daily"
        }
        
        return nil
    }
    
    private func extractNDC(from text: String) -> String? {
        let patterns = [
            #"\b(\d{5}-\d{4}-\d{2})\b"#,
            #"\b(\d{5}-\d{3}-\d{2})\b"#,
            #"\b(\d{4}-\d{4}-\d{2})\b"#,
            #"NDC[:\s]*(\d{10,11})"#
        ]
        
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                var ndc = String(text[range])
                // Clean up if has "NDC" prefix
                if let digitRange = ndc.range(of: #"\d[-\d]+"#, options: .regularExpression) {
                    ndc = String(ndc[digitRange])
                }
                return ndc
            }
        }
        
        return nil
    }
    
    private func extractDIN(from text: String) -> String? {
        // DIN: 8 digits, often prefixed
        if let range = text.range(of: #"DIN[:\s#]*(\d{8})"#, options: .regularExpression) {
            let match = String(text[range])
            if let digitRange = match.range(of: #"\d{8}"#, options: .regularExpression) {
                return String(match[digitRange])
            }
        }
        
        // Look for standalone 8-digit number prefixed with # or *#
        if let range = text.range(of: #"[*#]+\s*(\d{8})\b"#, options: .regularExpression) {
            let match = String(text[range])
            if let digitRange = match.range(of: #"\d{8}"#, options: .regularExpression) {
                return String(match[digitRange])
            }
        }
        
        return nil
    }
    
    private func extractQuantity(from text: String) -> String? {
        // Look for "Qty: 30" or "30 TAB" or "Remain: 90 TAB"
        let patterns = [
            #"(?:Qty|QTY)[:\s]*(\d+)"#,
            #"(?:Remain|REMAIN)[:\s]*(\d+)\s*TAB"#,
            #"\b(\d+)\s*(?:TAB|TABLET|CAPSULE)S?\b"#
        ]
        
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                if let numRange = match.range(of: #"\d+"#, options: .regularExpression) {
                    return String(match[numRange])
                }
            }
        }
        
        return nil
    }
    
    private func extractExpiration(from text: String) -> String? {
        // Match patterns like "Exp:30-Jun", "30-Jun-2026", "Drug Exp.:30-Jun"
        let patterns = [
            #"(?:Exp|EXP)[.:\s]*(\d{1,2}-[A-Za-z]{3}(?:-\d{4})?)"#,
            #"(?:Expir|EXPIR)[^:]*:\s*(\d{1,2}[-/]\d{1,2}[-/]\d{2,4})"#,
            #"\b(\d{1,2}-[A-Za-z]{3}-\d{4})\b"#
        ]
        
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                // Extract just the date part
                if let dateRange = match.range(of: #"\d{1,2}[-/][A-Za-z\d]{3}(?:[-/]\d{2,4})?"#, options: .regularExpression) {
                    return String(match[dateRange])
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Time window suggestions
    
    private func suggestTimeWindows(from text: String) -> [String] {
        let upperText = text.uppercased()
        var windows: [String] = []
        
        if upperText.contains("ONCE") && (upperText.contains("DAILY") || upperText.contains("DAY")) {
            windows.append("Morning")
        } else if upperText.contains("TWICE") && (upperText.contains("DAILY") || upperText.contains("DAY")) {
            windows.append(contentsOf: ["Morning", "Dinner"])
        } else if upperText.contains("THREE TIMES") || upperText.contains("3 TIMES") {
            windows.append(contentsOf: ["Morning", "Afternoon", "Dinner"])
        } else if upperText.contains("FOUR TIMES") || upperText.contains("4 TIMES") {
            windows.append(contentsOf: ["Morning", "Afternoon", "Dinner", "Bedtime"])
        } else if upperText.contains("BEDTIME") || upperText.contains("BEFORE BED") || 
                  upperText.contains("AT NIGHT") {
            windows.append("Bedtime")
        } else if upperText.contains("MORNING") {
            windows.append("Morning")
        } else if upperText.contains("WITH MEALS") || upperText.contains("BEFORE MEALS") {
            windows.append(contentsOf: ["Afternoon", "Dinner"])
        } else if upperText.contains("1 TABLET") && upperText.contains("DAILY") {
            // Default to morning for once daily
            windows.append("Morning")
        }
        
        return windows
    }

    // MARK: - LLM-Powered OCR Refinement

    /// Parse OCR text with optional LLM fallback for low-confidence results.
    /// If the rule-based parser produces low confidence and OpenAI is configured,
    /// the LLM is called to refine the result.
    func parseWithLLMFallback(_ text: String) async -> ParsedMedicationInfo {
        let parserResult = await parse(text)
        let confidence = parserResult.confidenceScore

        // Only use LLM if confidence is low and OpenAI is configured
        guard confidence < 0.6, await LLMService.shared.isConfigured else {
            return parserResult
        }

        do {
            let llmResult = try await LLMService.shared.refineOCR(text, partialResult: parserResult)
            let merged = await LLMService.merge(llmResult: llmResult, with: parserResult)
            print("[MedicationTextParser] LLM refinement completed. Confidence: \(confidence) → \(merged.confidenceScore)")
            return merged
        } catch {
            print("[MedicationTextParser] LLM fallback failed: \(error.localizedDescription). Using parser result.")
            return parserResult
        }
    }
}
