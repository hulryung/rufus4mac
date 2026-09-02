import Foundation

/// macOS locale → Windows locale (culture) name.
///
/// `Locale.current.identifier` is an ICU identifier (`en_KR`, `ko_KR@calendar=gregorian`), *not* a
/// Windows culture name. A Mac set to language English + region Korea yields `en-KR`, which no
/// Windows build knows; `Microsoft-Windows-International-Core-WinPE` then rejects the answer file
/// and Setup stops with **0x8007000D (ERROR_INVALID_DATA)**. So every value we emit is validated
/// against a list of real Windows locales first, and an unknown language-region pair falls back to
/// the language's default locale (`en-KR` → `en-US`).
public enum WindowsLocale {
    /// Windows culture names we are willing to emit. Not exhaustive — anything missing falls back
    /// to `languageDefault`, so an omission costs the regional variant, never a broken install.
    static let known: Set<String> = [
        "ar-SA", "ar-AE", "ar-EG", "bg-BG", "ca-ES", "cs-CZ", "da-DK",
        "de-DE", "de-AT", "de-CH", "el-GR",
        "en-US", "en-GB", "en-AU", "en-CA", "en-IE", "en-IN", "en-NZ", "en-SG", "en-ZA",
        "es-ES", "es-MX", "es-AR", "es-CL", "es-CO", "et-EE", "eu-ES", "fa-IR", "fi-FI",
        "fr-FR", "fr-BE", "fr-CA", "fr-CH", "gl-ES", "he-IL", "hi-IN", "hr-HR", "hu-HU",
        "id-ID", "it-IT", "it-CH", "ja-JP", "ko-KR", "lt-LT", "lv-LV", "ms-MY",
        "nb-NO", "nl-NL", "nl-BE", "nn-NO", "pl-PL", "pt-BR", "pt-PT", "ro-RO", "ru-RU",
        "sk-SK", "sl-SI", "sr-RS", "sv-SE", "sv-FI", "th-TH", "tr-TR", "uk-UA", "vi-VN",
        "zh-CN", "zh-TW", "zh-HK", "zh-SG",
    ]

    /// Default locale per language, for when the Mac's language-region pair is not a Windows locale.
    static let languageDefault: [String: String] = [
        "ar": "ar-SA", "bg": "bg-BG", "ca": "ca-ES", "cs": "cs-CZ", "da": "da-DK",
        "de": "de-DE", "el": "el-GR", "en": "en-US", "es": "es-ES", "et": "et-EE",
        "eu": "eu-ES", "fa": "fa-IR", "fi": "fi-FI", "fr": "fr-FR", "gl": "gl-ES",
        "he": "he-IL", "iw": "he-IL", "hi": "hi-IN", "hr": "hr-HR", "hu": "hu-HU",
        "id": "id-ID", "in": "id-ID", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
        "lt": "lt-LT", "lv": "lv-LV", "ms": "ms-MY", "nb": "nb-NO", "nl": "nl-NL",
        "nn": "nn-NO", "no": "nb-NO", "pl": "pl-PL", "pt": "pt-BR", "ro": "ro-RO",
        "ru": "ru-RU", "sk": "sk-SK", "sl": "sl-SI", "sr": "sr-RS", "sv": "sv-SE",
        "th": "th-TH", "tr": "tr-TR", "uk": "uk-UA", "vi": "vi-VN", "zh": "zh-CN",
    ]

    /// A real Windows locale for `language`/`region`, or nil when the language is unmapped.
    public static func windowsName(language: String?, region: String?) -> String? {
        guard let lang = language?.lowercased(), !lang.isEmpty else { return nil }
        if let r = region?.uppercased(), !r.isEmpty, known.contains("\(lang)-\(r)") {
            return "\(lang)-\(r)"
        }
        return languageDefault[lang]
    }

    /// The Windows locale matching this Mac's language & region, or nil when unmappable.
    public static func current(_ locale: Locale = .current) -> String? {
        windowsName(language: locale.language.languageCode?.identifier,
                    region: locale.region?.identifier)
    }

    /// "ko-kr" → "ko-KR". Windows locale names are language-lowercase, region-uppercase.
    static func canonical(_ s: String) -> String {
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return s.lowercased() }
        return "\(parts[0].lowercased())-\(parts[1].uppercased())"
    }
}

/// The UI languages a Windows install medium actually ships, read from `sources/lang.ini`.
///
/// `UILanguage` must name a language present in the image — a Korean ISO ships only `ko-KR`, so
/// asking it for `en-US` fails Setup exactly like an invalid locale does.
public enum WindowsImageLanguage {
    /// Locale names under `[Available UI Languages]` (e.g. `ko-kr = 3`), canonicalized.
    static func availableUILanguages(iniContents: String) -> [String] {
        var inSection = false
        var out: [String] = []
        for rawLine in iniContents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[available ui languages]"
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out.append(WindowsLocale.canonical(key)) }
        }
        return out
    }

    /// The UI language to request for the medium at `root`: `desired` when the image ships it,
    /// else the image's own first language. nil when `sources/lang.ini` is missing or empty —
    /// the caller then omits `UILanguage` and Setup uses the image default.
    public static func uiLanguage(root: String, desired: String?) -> String? {
        let ini = (root as NSString).appendingPathComponent("sources/lang.ini")
        guard let contents = readINI(atPath: ini) else { return nil }
        let available = availableUILanguages(iniContents: contents)
        if let d = desired.map(WindowsLocale.canonical), available.contains(d) { return d }
        return available.first
    }

    /// lang.ini is ASCII on most media but UTF-16LE on some, so try both.
    static func readINI(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
    }
}
