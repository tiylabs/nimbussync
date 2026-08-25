import Foundation

public enum CloudreveLocalization {
    public static let supportedLocales = ["en-US", "zh-CN", "zh-TW", "ja", "de", "fr", "es", "ko", "ru", "pl", "it"]
    public static func locale(for identifier: String?) -> Locale { Locale(identifier: supportedLocales.contains(identifier ?? "") ? identifier! : "en-US") }
    public static func format(bytes: Int64, locale: Locale = .current) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
