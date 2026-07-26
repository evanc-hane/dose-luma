import Testing
@testable import DoseLuma

// MARK: - DrugDatabase Tests

@Suite("DrugDatabase")
struct DrugDatabaseTests {

    // ── Availability ─────────────────────────────────────────────────────────

    @Test("Database file is bundled and opens successfully")
    func databaseIsAvailable() {
        #expect(DrugDatabase.shared.isAvailable,
                "DoseLumaDrugs.sqlite must be added to the app target. Run scripts/seed_drug_database.py then drag the file into Xcode.")
    }

    // ── NDC lookup ───────────────────────────────────────────────────────────

    @Test("Tylenol found by NDC (formatted)")
    func ndcFormattedLookup() throws {
        let result = DrugDatabase.shared.drug(forNDC: "50580-488-10")
        #expect(result != nil, "Seed DB must contain Tylenol NDC 50580-488-10")
        #expect(result?.brandName.lowercased().contains("tylenol") == true)
    }

    @Test("NDC lookup is case/dash insensitive")
    func ndcNormalisedLookup() {
        let withDashes    = DrugDatabase.shared.drug(forNDC: "50580-488-10")
        let withoutDashes = DrugDatabase.shared.drug(forNDC: "5058048810")
        #expect(withDashes?.brandName == withoutDashes?.brandName)
    }

    @Test("Unknown NDC returns nil")
    func unknownNDC() {
        let result = DrugDatabase.shared.drug(forNDC: "00000-000-00")
        #expect(result == nil)
    }

    // ── DIN lookup ───────────────────────────────────────────────────────────

    @Test("Tylenol found by DIN")
    func dinLookup() {
        let result = DrugDatabase.shared.drug(forDIN: "02238493")
        #expect(result != nil, "Seed DB must contain DIN 02238493 (Tylenol)")
        #expect(result?.din == "02238493")
    }

    @Test("Unknown DIN returns nil")
    func unknownDIN() {
        let result = DrugDatabase.shared.drug(forDIN: "00000000")
        #expect(result == nil)
    }

    // ── Imprint lookup ───────────────────────────────────────────────────────

    @Test("Exact imprint match")
    func exactImprintLookup() {
        let results = DrugDatabase.shared.drugs(forImprint: "ADVIL")
        #expect(!results.isEmpty, "Imprint 'ADVIL' should match Advil in seed DB")
        #expect(results.first?.brandName.lowercased().contains("advil") == true)
    }

    @Test("Imprint lookup is case-insensitive")
    func imprintCaseInsensitive() {
        let upper = DrugDatabase.shared.drugs(forImprint: "BAYER")
        let lower = DrugDatabase.shared.drugs(forImprint: "bayer")
        #expect(upper.count == lower.count)
    }

    @Test("Imprint + shape filter narrows results")
    func imprintShapeFilter() {
        let all      = DrugDatabase.shared.drugs(forImprint: "BAYER")
        let filtered = DrugDatabase.shared.drugs(forImprint: "BAYER", shape: "round")
        #expect(filtered.count <= all.count)
    }

    @Test("Unknown imprint returns empty array")
    func unknownImprint() {
        let results = DrugDatabase.shared.drugs(forImprint: "XXXXXXXX99")
        #expect(results.isEmpty)
    }

    // ── DrugRecord → MedicationMatch conversion ──────────────────────────────

    @Test("toMatch produces correct fields")
    func toMatch() {
        let record = DrugRecord(brandName: "TestDrug", genericName: "testgeneric",
                                strength: "10 mg", dosageForm: "tablet",
                                manufacturer: "TestCo", ndc: "12345-678-90", din: nil)
        let match = record.toMatch(confidence: 0.9, source: .imprintDatabase)
        #expect(match.drugName    == "TestDrug")
        #expect(match.genericName == "testgeneric")
        #expect(match.strength    == "10 mg")
        #expect(match.ndc         == "12345-678-90")
        #expect(match.confidence  == 0.9)
        #expect(match.matchSource == .imprintDatabase)
    }
}

// MARK: - BarcodeNDCIdentifier Tests

@Suite("BarcodeNDCIdentifier")
struct BarcodeNDCIdentifierTests {

    private func makeAnalysis(fullText: String) -> PillAnalysis {
        PillAnalysis(shape: .unknown, dominantColor: "Unknown",
                     secondaryColor: nil, imprint: nil,
                     topClassifications: [], fullText: fullText)
    }

    @Test("Extracts NDC from formatted barcode payload")
    func extractNDCFormatted() async {
        let analysis = makeAnalysis(fullText: "50580-488-10")
        let matches  = await BarcodeNDCIdentifier().identify(analysis: analysis)
        #expect(!matches.isEmpty)
        let m = matches[0]
        #expect(m.matchSource == .barcodeNDC)
        // If DB is available it resolves to Tylenol; if not it returns code-only
        #expect(m.ndc != nil || m.drugName.contains("50580"))
    }

    @Test("Extracts DIN from 8-digit string")
    func extractDIN() async {
        let analysis = makeAnalysis(fullText: "DIN 02238493")
        let matches  = await BarcodeNDCIdentifier().identify(analysis: analysis)
        #expect(!matches.isEmpty)
        #expect(matches[0].matchSource == .barcodeNDC)
    }

    @Test("No codes in text returns empty")
    func noCodesReturnsEmpty() async {
        let analysis = makeAnalysis(fullText: "Take one tablet daily")
        let matches  = await BarcodeNDCIdentifier().identify(analysis: analysis)
        #expect(matches.isEmpty)
    }
}

// MARK: - ImprintDatabaseIdentifier Tests

@Suite("ImprintDatabaseIdentifier")
struct ImprintDatabaseIdentifierTests {

    private func makeAnalysis(imprint: String?,
                               shape: PillAnalysis.Shape = .round,
                               color: String = "white") -> PillAnalysis {
        PillAnalysis(shape: shape, dominantColor: color,
                     secondaryColor: nil, imprint: imprint,
                     topClassifications: [], fullText: imprint ?? "")
    }

    @Test("Known imprint returns matches when DB is available")
    func knownImprint() async {
        guard DrugDatabase.shared.isAvailable else { return }
        let analysis = makeAnalysis(imprint: "ADVIL", shape: .oval, color: "brown")
        let matches  = await ImprintDatabaseIdentifier().identify(analysis: analysis)
        #expect(!matches.isEmpty)
        #expect(matches[0].matchSource == .imprintDatabase)
        #expect(matches[0].confidence > 0.5)
    }

    @Test("Nil imprint returns empty")
    func nilImprintReturnsEmpty() async {
        let analysis = makeAnalysis(imprint: nil)
        let matches  = await ImprintDatabaseIdentifier().identify(analysis: analysis)
        #expect(matches.isEmpty)
    }

    @Test("Confidence higher when shape and color match")
    func confidenceScaling() async {
        guard DrugDatabase.shared.isAvailable else { return }
        let withAttrs    = makeAnalysis(imprint: "ADVIL", shape: .oval, color: "brown")
        let withoutAttrs = makeAnalysis(imprint: "ADVIL", shape: .unknown, color: "Unknown")
        let mWith    = await ImprintDatabaseIdentifier().identify(analysis: withAttrs)
        let mWithout = await ImprintDatabaseIdentifier().identify(analysis: withoutAttrs)
        if let c1 = mWith.first?.confidence, let c2 = mWithout.first?.confidence {
            #expect(c1 >= c2)
        }
    }
}

// MARK: - CompositeMedicationIdentifier Tests

@Suite("CompositeMedicationIdentifier")
struct CompositeIdentifierTests {

    @Test("Returns deduplicated results across backends")
    func deduplication() async {
        // Both barcode and imprint backends could return the same NDC drug.
        // Composite must deduplicate by NDC.
        let analysis = PillAnalysis(
            shape: .oval, dominantColor: "brown",
            secondaryColor: nil, imprint: "ADVIL",
            topClassifications: [],
            fullText: "ADVIL 50580-140-50"  // has both imprint and NDC
        )
        let composite = await CompositeMedicationIdentifier()
        let matches   = await composite.identify(analysis: analysis)

        // Check no duplicate drug names
        let names = matches.map { $0.drugName }
        let unique = Set(names)
        #expect(names.count == unique.count, "Composite must deduplicate results")
    }

    @Test("Results sorted by descending confidence")
    func sortedByConfidence() async {
        guard DrugDatabase.shared.isAvailable else { return }
        let analysis = PillAnalysis(
            shape: .round, dominantColor: "white",
            secondaryColor: nil, imprint: "BAYER",
            topClassifications: [], fullText: "59011-034-10"
        )
        let composite = await CompositeMedicationIdentifier()
        let matches   = await composite.identify(analysis: analysis)
        let confs     = matches.map { $0.confidence }
        #expect(confs == confs.sorted(by: >), "Matches must be sorted descending by confidence")
    }
}

// MARK: - MedicationStore Tests

@Suite("MedicationStore")
@MainActor
struct MedicationStoreTests {

    @Test("Add medication persists and publishes")
    func addMedication() {
        let store = MedicationStore()
        let before = store.medications.count
        let med = Medication(name: "TestMed", dosage: "10 mg",
                             instructions: "", timeWindows: [.morning])
        store.add(med)
        #expect(store.medications.count == before + 1)
        #expect(store.medications.last?.name == "TestMed")
    }

    @Test("Delete medication removes it")
    func deleteMedication() {
        let store = MedicationStore()
        let med = Medication(name: "DeleteMe", dosage: "5 mg",
                             instructions: "", timeWindows: [.afternoon])
        store.add(med)
        let countAfterAdd = store.medications.count
        store.delete(med)
        #expect(store.medications.count == countAfterAdd - 1)
        #expect(!store.medications.contains(where: { $0.id == med.id }))
    }

    @Test("logTaken creates adherence record with .taken status")
    func logTaken() {
        let store = MedicationStore()
        let med   = Medication(name: "LogTest", dosage: "10 mg",
                               instructions: "", timeWindows: [.morning])
        store.add(med)
        let before = store.adherenceRecords.count
        store.logTaken(med, window: .morning)
        #expect(store.adherenceRecords.count == before + 1)
        #expect(store.adherenceRecords.last?.status == .taken)
    }

    @Test("logSkipped creates adherence record with .skipped status")
    func logSkipped() {
        let store = MedicationStore()
        let med   = Medication(name: "SkipTest", dosage: "10 mg",
                               instructions: "", timeWindows: [.bedtime])
        store.add(med)
        store.logSkipped(med, window: .bedtime)
        #expect(store.adherenceRecords.last?.status == .skipped)
    }

    @Test("logTaken is idempotent for same window+day")
    func logTakenIdempotent() {
        let store = MedicationStore()
        let med   = Medication(name: "IdemTest", dosage: "10 mg",
                               instructions: "", timeWindows: [.dinner])
        store.add(med)
        store.logTaken(med, window: .dinner)
        let count1 = store.adherenceRecords.count
        store.logTaken(med, window: .dinner)   // second call — should replace, not append
        let count2 = store.adherenceRecords.count
        #expect(count1 == count2, "logTaken must upsert, not duplicate")
    }

    @Test("adherenceRate returns 1.0 for all taken")
    func adherenceRateAllTaken() {
        let store = MedicationStore()
        let med   = Medication(name: "RateTest", dosage: "5 mg",
                               instructions: "", timeWindows: [.morning])
        store.add(med)
        store.logTaken(med, window: .morning)
        let rate = store.adherenceRate(days: 1)
        #expect(rate == 1.0)
    }

    @Test("adherenceRate returns 0.0 when all skipped")
    func adherenceRateAllSkipped() {
        let store = MedicationStore()
        let med   = Medication(name: "SkipRateTest", dosage: "5 mg",
                               instructions: "", timeWindows: [.morning])
        store.add(med)
        store.logSkipped(med, window: .morning)
        let rate = store.adherenceRate(days: 1)
        #expect(rate == 0.0)
    }
}

// MARK: - MedicationMatch Tests

@Suite("MedicationMatch")
struct MedicationMatchTests {

    @Test("MatchSource raw values are human-readable")
    func matchSourceRawValues() {
        #expect(MedicationMatch.MatchSource.imprintDatabase.rawValue == "Imprint DB")
        #expect(MedicationMatch.MatchSource.barcodeNDC.rawValue      == "Barcode / NDC")
        #expect(MedicationMatch.MatchSource.visualML.rawValue        == "Visual ML")
        #expect(MedicationMatch.MatchSource.userConfirmed.rawValue   == "User Confirmed")
    }

    @Test("Each MedicationMatch gets a unique ID")
    func uniqueIDs() {
        let m1 = MedicationMatch(drugName: "Drug A", confidence: 0.9, matchSource: .barcodeNDC)
        let m2 = MedicationMatch(drugName: "Drug A", confidence: 0.9, matchSource: .barcodeNDC)
        #expect(m1.id != m2.id)
    }
}
