import Foundation

public enum CloudreveLocalization {
    public static let supportedLocales = ["en-US", "zh-CN", "zh-TW", "ja", "de", "fr", "es", "ko", "ru", "pl", "it"]
    public static func locale(for identifier: String?) -> Locale { Locale(identifier: supportedLocales.contains(identifier ?? "") ? identifier! : "en-US") }
    public static func format(bytes: Int64, locale: Locale = .current) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = [.naturalScale]
        formatter.unitStyle = .medium
        let measurement = Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
        return formatter.string(from: measurement)
    }
    public static func format(date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    public static func format(number: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
