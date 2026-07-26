import SwiftUI

/// Add or edit a medication entry. OCR scanning pre-fills DIN, NDC, and dosage fields.
struct AddMedicationView: View {
    @EnvironmentObject var store: MedicationStore
    @Environment(\.dismiss) private var dismiss

    var editing: Medication? = nil
    var initialOCR: String? = nil
    var initialPill: PillAnalysis? = nil

    @State private var name            = ""
    
    // Dosage parts
    @State private var dosageInteger   = 0
    @State private var dosageDecimal   = 0 // 0, 25, 50, 75
    @State private var dosageUnit      = "mg"
    
    @State private var instructions    = ""
    @State private var din             = ""
    @State private var ndc             = ""
    @State private var notes           = ""
    @State private var selectedWindows: Set<TimeWindow> = []
    
    private let units = ["mg", "mcg", "g", "mL", "units", "IU", "%", "puff", "pill", "tablet"]
    private let decimals = [0, 25, 50, 75]

    @State private var scannedText: String?
    @State private var scannedRaw      = ""
    @State private var pillAnalysis: PillAnalysis?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Pushed inline into the medication tab's own NavigationStack (see
    // MedRoute in MedicationListView) rather than presented as a separate
    // sheet/window — and laid out as tappable boxes instead of Form rows
    // with Pickers, which is what made the old macOS sheet blow out past
    // its bounds in the first place.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !scannedRaw.isEmpty || pillAnalysis != nil {
                    scannedSummaryCard
                }

                EditorCard(title: "Medication Details") {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Drug name (required)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)

                        dosageEditor

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instructions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g., Take with food", text: $instructions)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes (optional)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Notes", text: $notes)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                EditorCard(
                    title: "Drug Identification",
                    footer: "DIN is issued by Health Canada; NDC by the FDA. Both are printed on the medication label."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DIN — 8 digits (Canada)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("DIN", text: $din)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NDC — 10 digits (US)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("NDC", text: $ndc)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                    }
                }

                EditorCard(title: "Administration Windows") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(store.sortedTimeWindows) { window in
                            TimeWindowBox(window: window, isSelected: selectedWindows.contains(window)) {
                                toggleWindow(window)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(editing == nil ? "Add Medication" : "Edit Medication")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!isValid)
            }
        }
        .onAppear {
            print("[DEBUG] AddMedicationView onAppear, initialOCR = \(initialOCR ?? "nil")")
            prefill()
            if let ocr = initialOCR {
                scannedText = ocr
                // Parse immediately with local parser (fast, reliable)
                applyScannedText()
            }
            if let pill = initialPill {
                pillAnalysis = pill
                applyPillAnalysis()
            }
        }
    }

    // MARK: - Boxed dosage entry (replaces the old Integer/Decimal/Unit
    // Pickers, whose macOS .menu label text was what overflowed the sheet)

    private var dosageEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dosage")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("0", value: $dosageInteger, format: .number)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: 64)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif

                Text(".")
                    .font(.title2.bold())

                HStack(spacing: 6) {
                    ForEach(decimals, id: \.self) { d in
                        SelectionChip(title: String(format: "%02d", d), isSelected: dosageDecimal == d) {
                            dosageDecimal = d
                        }
                    }
                }
            }

            Text("Unit")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(units, id: \.self) { u in
                        SelectionChip(title: u, isSelected: dosageUnit == u) { dosageUnit = u }
                    }
                }
            }
        }
    }

    private var scannedSummaryCard: some View {
        EditorCard(title: "Scanned Data") {
            VStack(alignment: .leading, spacing: 8) {
                if !scannedRaw.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scanned Label Data")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(scannedRaw)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                if let pa = pillAnalysis {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pill Analysis")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(pa.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func toggleWindow(_ window: TimeWindow) {
        if selectedWindows.contains(window) {
            selectedWindows.remove(window)
        } else {
            selectedWindows.insert(window)
        }
    }

    private func prefill() {
        guard let m = editing else { return }
        name            = m.name
        instructions    = m.instructions
        din             = m.din  ?? ""
        ndc             = m.ndc  ?? ""
        notes           = m.notes ?? ""
        selectedWindows = Set(m.timeWindowIDs.compactMap { store.timeWindow(byID: $0) })
        
        // Parse dosage into integer, decimal, and unit
        let components = m.dosage.components(separatedBy: " ")
        if components.count >= 2 {
            let valStr = components[0]
            let unitStr = components.dropFirst().joined(separator: " ")
            
            if let dVal = Double(valStr) {
                dosageInteger = Int(dVal)
                let dec = Int((dVal.truncatingRemainder(dividingBy: 1) * 100).rounded())
                // Snap to nearest allowed decimal
                dosageDecimal = decimals.min(by: { abs($0 - dec) < abs($1 - dec) }) ?? 0
            }
            if units.contains(unitStr) {
                dosageUnit = unitStr
            }
        }
    }

    private func save() {
        let orderedIDs = store.sortedTimeWindows.filter { selectedWindows.contains($0) }.map(\.id)
        
        let val: Double = Double(dosageInteger) + (Double(dosageDecimal) / 100.0)
        let valStr = dosageDecimal == 0 ? "\(dosageInteger)" : String(format: "%.2f", val)
        let fullDosage = val == 0 ? "" : "\(valStr) \(dosageUnit)"
        
        var med = Medication(
            name:         name.trimmingCharacters(in: .whitespaces),
            dosage:       fullDosage,
            instructions: instructions,
            timeWindowIDs: orderedIDs,
            din:          din.isEmpty   ? nil : din,
            ndc:          ndc.isEmpty   ? nil : ndc,
            notes:        notes.isEmpty ? nil : notes
        )
        if let e = editing {
            med.id = e.id
            store.update(med)
        } else {
            store.add(med)
        }
        dismiss()
    }

    /// Parse DIN, NDC, dosage, and drug name from OCR output.
    private func applyScannedText() {
        guard let text = scannedText else {
            print("[DEBUG] scannedText is nil")
            return
        }
        scannedRaw = text
        print("\n[DEBUG] ========== applyScannedText START ==========")
        print("[DEBUG] Raw input:\n---\n\(text)\n---")

        // Split into lines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        print("[DEBUG] Lines (\(lines.count)):")
        for (i, l) in lines.enumerated() {
            print("[DEBUG]   [\(i)] '\(l)'")
        }

        // === DIN ===
        if din.isEmpty,
           let m = text.range(of: #"\b\d{8}\b"#, options: .regularExpression) {
            din = String(text[m])
            print("[DEBUG] Found DIN: \(din)")
        }

        // === NDC ===
        if ndc.isEmpty,
           let m = text.range(of: #"\b(\d{5}-\d{4}-\d{2}|\d{10})\b"#, options: .regularExpression) {
            ndc = String(text[m])
            print("[DEBUG] Found NDC: \(ndc)")
        }

        // === Drug name + dosage ===
        // Find the first line that contains a dosage unit (mg, mcg, etc.)
        // This is almost always the drug label line
        for line in lines {
            let upper = line.uppercased()
            // Skip Rx numbers and warnings
            if upper.hasPrefix("#") || upper.hasPrefix("RX") ||
               upper.contains("WARNING") || upper.contains("CAUTION") {
                continue
            }

            if line.contains("mg") || line.contains("mcg") || line.contains("meq") {
                // Extract dosage number
                if dosageInteger == 0 && dosageDecimal == 0,
                   let match = line.range(
                    of: #"\b(\d+\.?\d*)\s*(mg|mcg|mL|g|meq|units?|IU|%)"#,
                    options: [.regularExpression, .caseInsensitive]
                   ) {
                    let found = String(line[match])
                    let valStr = found.prefix { "0123456789.".contains($0) }
                    if let dVal = Double(valStr) {
                        dosageInteger = Int(dVal)
                        let dec = Int((dVal.truncatingRemainder(dividingBy: 1) * 100).rounded())
                        dosageDecimal = decimals.min(by: { abs($0 - dec) < abs($1 - dec) }) ?? 0
                        print("[DEBUG] dosage = \(dosageInteger).\(dosageDecimal)")
                    }
                    let unitStr = found.drop { "0123456789. ".contains($0) }.lowercased()
                    if let u = units.first(where: { $0.lowercased() == unitStr }) {
                        dosageUnit = u
                        print("[DEBUG] unit = \(dosageUnit)")
                    }
                }

                // Extract drug name: everything before the FIRST dosage number
                if name.isEmpty,
                   let match = line.range(
                    of: #"\d+\.?\d*\s*(?:mg|mcg|mL|g|meq|MCG|MG|ML|G|MEQ)"#,
                    options: .regularExpression
                   ) {
                    var drugPart = String(line[..<match.lowerBound])
                        .trimmingCharacters(in: .whitespaces)

                    // Remove form indicators (TAB, CAP, ER, SR, etc.)
                    drugPart = drugPart.replacingOccurrences(
                        of: #"\s*\b(TAB|CAP|ER|SR|LA|XL|XR|CR|IR)\b\s*"#,
                        with: "",
                        options: .regularExpression
                    ).trimmingCharacters(in: .whitespaces)

                    print("[DEBUG] drugPart = '\(drugPart)'")

                    if drugPart.count >= 3 {
                        let words = drugPart.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        name = words.map { word in
                            word.prefix(1).uppercased() + word.dropFirst().lowercased()
                        }.joined(separator: " ")
                        print("[DEBUG] name = '\(name)'")
                    }
                }

                // === Instructions ===
                // Everything after the dosage on this line (and any subsequent instruction lines)
                if instructions.isEmpty {
                    if let match = line.range(
                        of: #"\d+\.?\d*\s*(?:mg|mcg|mL|g|meq|MCG|MG|ML|G|MEQ)"#,
                        options: .regularExpression
                    ) {
                        var after = String(line[match.upperBound...])
                            .trimmingCharacters(in: .whitespaces)

                        if !after.isEmpty {
                            after = fixOCRSpellingErrors(after)
                            instructions = after
                            print("[DEBUG] instructions = '\(instructions)'")
                        }
                    }
                }

                // === Time windows ===
                if selectedWindows.isEmpty {
                    selectedWindows = determineTimeWindows(from: text)
                    print("[DEBUG] time windows = \(selectedWindows.map(\.name))")
                }

                // Got what we need from the drug line, stop
                break
            }
        }

        // If instructions still empty, try to find instruction lines
        if instructions.isEmpty {
            for line in lines {
                let upper = line.uppercased()
                if upper.hasPrefix("#") || upper.hasPrefix("RX") { continue }
                if upper.contains("TAKE") || upper.contains("BY MOUTH") ||
                   upper.contains("TABLET") || upper.contains("CAPSULE") {
                    // Skip the drug+dosage line (already processed)
                    if line.contains("mg") || line.contains("mcg") { continue }
                    instructions = fixOCRSpellingErrors(line)
                    print("[DEBUG] instructions (from other line) = '\(instructions)'")
                    break
                }
            }
        }

        print("[DEBUG] ========== applyScannedText END ==========")
        print("[DEBUG] Results: name='\(name)', dosage=\(dosageInteger).\(dosageDecimal) \(dosageUnit), instr='\(instructions)', windows=\(selectedWindows.map(\.name))")
        print("================================================\n")
    }

    /// Determine time windows based on timing keywords in OCR text
    private func determineTimeWindows(from text: String) -> Set<TimeWindow> {
        let upper = text.uppercased()
        var windows: Set<TimeWindow> = []

        // Check for specific time keywords
        if upper.contains("MORNING") || upper.contains("AM") && !upper.contains("PM") ||
           upper.contains("BREAKFAST") {
            if let w = store.timeWindows.first(where: { $0.name == "Morning" }) {
                windows.insert(w)
            }
        }

        // "Noon" / "Lunch" / "Midday" → Afternoon window (12:00-14:00)
        if upper.contains("NOON") || upper.contains("MIDDAY") || upper.contains("LUNCH") ||
           upper.contains("12 PM") || upper.contains("12PM") {
            if let w = store.timeWindows.first(where: { $0.name == "Afternoon" }) {
                windows.insert(w)
            }
        }

        if upper.contains("AFTERNOON") || (upper.contains("PM") && !upper.contains("NOON") && !upper.contains("NIGHT")) {
            if let w = store.timeWindows.first(where: { $0.name == "Afternoon" }) {
                windows.insert(w)
            }
        }

        if upper.contains("DINNER") || upper.contains("EVENING") ||
           upper.contains("SUPPER") {
            if let w = store.timeWindows.first(where: { $0.name == "Dinner" }) {
                windows.insert(w)
            }
        }

        if upper.contains("BEDTIME") || upper.contains("BED ") || upper.contains("NIGHT") ||
           upper.contains("BEFORE SLEEP") || upper.contains("AT NIGHT") {
            if let w = store.timeWindows.first(where: { $0.name == "Bedtime" }) {
                windows.insert(w)
            }
        }

        // If "daily" or "once daily" but no specific time, default to Morning
        if windows.isEmpty && (upper.contains("ONCE DAILY") || upper.contains("DAILY")) {
            if let w = store.timeWindows.first(where: { $0.name == "Morning" }) {
                windows.insert(w)
            }
        }

        // If "twice daily", default to Morning + Dinner
        if upper.contains("TWICE DAILY") || upper.contains("TWO TIMES") || upper.contains("2 TIMES") {
            if let m = store.timeWindows.first(where: { $0.name == "Morning" }) {
                windows.insert(m)
            }
            if let d = store.timeWindows.first(where: { $0.name == "Dinner" }) {
                windows.insert(d)
            }
        }

        // If "three times daily", Morning + Afternoon + Dinner
        if upper.contains("THREE TIMES") || upper.contains("3 TIMES") || upper.contains("TID") {
            if let m = store.timeWindows.first(where: { $0.name == "Morning" }) {
                windows.insert(m)
            }
            if let a = store.timeWindows.first(where: { $0.name == "Afternoon" }) {
                windows.insert(a)
            }
            if let d = store.timeWindows.first(where: { $0.name == "Dinner" }) {
                windows.insert(d)
            }
        }

        // If "four times daily", all windows
        if upper.contains("FOUR TIMES") || upper.contains("4 TIMES") || upper.contains("QID") {
            for w in store.timeWindows {
                windows.insert(w)
            }
        }

        return windows
    }

    /// Fix common OCR misspellings of medication-related words
    private func fixOCRSpellingErrors(_ text: String) -> String {
        var result = text
        // Only fix words that OCR commonly mangles on medication labels
        let replacements: [(String, String)] = [
            ("daly", "daily"),
            ("evning", "evening"),
            ("bedtme", "bedtime"),
            ("nouth", "mouth"),
        ]
        for (wrong, right) in replacements {
            result = result.replacingOccurrences(
                of: " " + wrong + " ",
                with: " " + right + " ",
                options: .caseInsensitive
            )
        }
        return result
    }

    /// Applies pill image analysis: pre-fills notes with physical description
    /// and uses OCR full text for DIN/NDC/dosage if not already set.
    private func applyPillAnalysis() {
        guard let pa = pillAnalysis else { return }

        // Build physical description for notes
        var descParts = ["\(pa.shape.rawValue) \(pa.dominantColor.lowercased()) pill"]
        if let sec = pa.secondaryColor { descParts.append("/ \(sec)") }
        if let imp = pa.imprint, !imp.isEmpty { descParts.append("· imprint: \(imp)") }
        let description = descParts.joined(separator: " ")

        if notes.isEmpty {
            notes = description
        } else if !notes.contains(description) {
            notes += "; \(description)"
        }

        // Re-use full OCR text from the pill scan for code extraction
        if !pa.fullText.isEmpty {
            scannedText = pa.fullText
            applyScannedText()
        }
    }

    /// Parse OCR text using the rule-based parser with automatic LLM fallback.
    /// If the parser produces low-confidence results and OpenAI is configured,
    /// the LLM is called to refine the extraction.
    @MainActor
    private func applyScannedTextWithLLM() async {
        guard let text = scannedText else { return }

        // Run the rule-based parser with LLM fallback
        let parser = MedicationTextParser.shared
        let parsed = await parser.parseWithLLMFallback(text)

        // Apply extracted fields to form (only if fields are currently empty)
        await MainActor.run {
            // Update scanned label data to show LLM-cleaned version
            if !parsed.drugName.isNilOrEmpty || !parsed.strength.isNilOrEmpty {
                var cleanLabel = ""
                if let dn = parsed.drugName { cleanLabel += dn + " " }
                if let st = parsed.strength { cleanLabel += st + " " }
                if let ins = parsed.instructions { cleanLabel += ins + " " }
                if let d = parsed.din { cleanLabel += "DIN: " + d + " " }
                if let n = parsed.ndc { cleanLabel += "NDC: " + n }
                scannedRaw = cleanLabel.trimmingCharacters(in: .whitespaces)
                print("[LLM-OCR] Cleaned label text: \(scannedRaw)")
            }

            if name.isEmpty, let drugName = parsed.drugName {
                name = drugName
                print("[LLM-OCR] Set name from LLM: \(name)")
            }
            if din.isEmpty, let dinVal = parsed.din {
                din = dinVal
            }
            if ndc.isEmpty, let ndcVal = parsed.ndc {
                ndc = ndcVal
            }
            if instructions.isEmpty, let instr = parsed.instructions {
                instructions = instr
                print("[LLM-OCR] Set instructions from LLM: \(instructions)")
            }

            // Parse dosage if not already set
            if dosageInteger == 0, let strength = parsed.strength {
                parseDosageFromStrength(strength)
            }

            // Apply suggested time windows
            if selectedWindows.isEmpty && !parsed.suggestedTimeWindows.isEmpty {
                for windowName in parsed.suggestedTimeWindows {
                    if let window = store.timeWindows.first(where: { $0.name == windowName }) {
                        selectedWindows.insert(window)
                    }
                }
            }

            print("[LLM-OCR] Final: name=\(name), dosage=\(dosageInteger).\(dosageDecimal) \(dosageUnit), instr='\(instructions)', confidence=\(parsed.confidenceScore)")
        }
    }

    /// Parse a dosage string like "500mg" or "0.25mcg" into integer, decimal, and unit components.
    private func parseDosageFromStrength(_ strength: String) {
        let pattern = #"(\d+\.?\d*)\s*(mg|mcg|mL|g|meq|units?|IU|%)"#
        if let match = strength.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let found = String(strength[match])
            let valStr = found.prefix { "0123456789.".contains($0) }
            if let dVal = Double(valStr) {
                dosageInteger = Int(dVal)
                let dec = Int((dVal.truncatingRemainder(dividingBy: 1) * 100).rounded())
                dosageDecimal = decimals.min(by: { abs($0 - dec) < abs($1 - dec) }) ?? 0
                let unitStr = found.drop { "0123456789. ".contains($0) }.lowercased()
                if let u = units.first(where: { $0.lowercased() == unitStr }) {
                    dosageUnit = u
                }
            }
        }
    }
}

// MARK: - Boxed editor building blocks

/// A titled card grouping a set of fields — the "different boxes" that
/// replaced the Form/Section-in-a-sheet layout.
private struct EditorCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }
}

/// A single tappable choice — used for the dosage decimal/unit picks.
private struct SelectionChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// A selectable box for one administration window — replaces the old
/// Toggle-per-row list with a multi-select grid.
private struct TimeWindowBox: View {
    let window: TimeWindow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: window.icon)
                        .foregroundStyle(window.color)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(window.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(window.timeRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? window.color.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? window.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
