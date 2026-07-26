import Foundation
import SwiftUI

// MARK: - Time Window

struct TimeWindow: Identifiable, Codable, Equatable, Hashable {
    /// Stable identifier. For defaults: "Morning", "Afternoon", etc.
    let id: String
    /// User-facing display name (editable).
    var name: String
    /// SF Symbol name.
    var icon: String
    /// Hex color string (e.g. "#FF9500").
    var colorHex: String
    /// Hour (24-hr) when this window opens.
    var openHour: Int
    /// Minute when this window opens.
    var openMinute: Int
    /// Hour (24-hr) when this window closes.
    var closeHour: Int
    /// Minute when this window closes.
    var closeMinute: Int
    /// Sort order among all windows.
    var sortOrder: Int

    // MARK: Equatable / Hashable by id only

    static func == (lhs: TimeWindow, rhs: TimeWindow) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: Computed

    var color: Color { Color(hex: colorHex) }

    var timeRangeText: String {
        "\(formattedTime(openHour, openMinute)) – \(formattedTime(closeHour, closeMinute))"
    }

    var isCurrentWindow: Bool {
        isCurrent(at: Date())
    }

    func isCurrent(at now: Date) -> Bool {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let nowMinutes = hour * 60 + minute
        let openMinutes = openHour * 60 + self.openMinute
        let closeMinutes = closeHour * 60 + self.closeMinute
        return nowMinutes >= openMinutes && nowMinutes < closeMinutes
    }

    private func formattedTime(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let h = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour)
        if minute == 0 {
            return "\(h) \(suffix)"
        }
        return "\(h):\(String(format: "%02d", minute)) \(suffix)"
    }
}

// MARK: Default Windows

extension TimeWindow {
    static let defaultWindows: [TimeWindow] = [
        TimeWindow(id: "Morning",   name: "Morning",   icon: "sunrise.fill",  colorHex: "#FF9500",
                   openHour: 7,  openMinute: 0, closeHour: 10, closeMinute: 0, sortOrder: 0),
        TimeWindow(id: "Afternoon", name: "Afternoon", icon: "sun.max.fill",  colorHex: "#FFCC00",
                   openHour: 12, openMinute: 0, closeHour: 14, closeMinute: 0, sortOrder: 1),
        TimeWindow(id: "Dinner",    name: "Dinner",    icon: "fork.knife",    colorHex: "#34C759",
                   openHour: 17, openMinute: 0, closeHour: 19, closeMinute: 0, sortOrder: 2),
        TimeWindow(id: "Bedtime",   name: "Bedtime",   icon: "moon.fill",     colorHex: "#5856D6",
                   openHour: 20, openMinute: 0, closeHour: 22, closeMinute: 0, sortOrder: 3),
    ]
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Color Palette for Time Window Editor

enum TimeWindowColor: String, CaseIterable, Identifiable {
    case orange = "#FF9500"
    case yellow = "#FFCC00"
    case green  = "#34C759"
    case indigo = "#5856D6"
    case blue   = "#007AFF"
    case red    = "#FF3B30"
    case pink   = "#FF2D55"
    case teal   = "#5AC8FA"
    case purple = "#AF52DE"
    case mint   = "#00C7BE"

    var id: String { rawValue }
    var color: Color { Color(hex: rawValue) }
}

// MARK: - Medication

struct Medication: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var dosage: String
    var instructions: String
    var timeWindowIDs: [String]
    /// Canadian Drug Identification Number (8 digits)
    var din: String?
    /// US National Drug Code (10 digits)
    var ndc: String?
    var notes: String?
    var isActive: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, dosage, instructions, din, ndc, notes, isActive
        case timeWindowIDs = "timeWindows"
    }
}

// MARK: - Adherence

enum AdherenceStatus: String, Codable {
    case taken, missed, skipped
}

struct AdherenceRecord: Identifiable, Codable {
    var id = UUID()
    var medicationId: UUID
    var medicationName: String
    var dosage: String
    var windowID: String
    /// Start-of-day date (used as the "day" key for this record).
    var scheduledDate: Date
    var takenAt: Date?
    var status: AdherenceStatus

    enum CodingKeys: String, CodingKey {
        case id, medicationId, medicationName, dosage, scheduledDate, takenAt, status
        case windowID = "window"
    }
}
