import Foundation

/// Rufus-style "Windows User Experience" options applied via a generated autounattend.xml.
public struct WindowsCustomization: Sendable, Equatable {
    public var bypassWin11: Bool
    /// nil = don't create an account. When set, a local Administrator with a BLANK password is created.
    public var localAccountUsername: String?
    public var skipPrivacy: Bool
    /// BCP-47 locale (e.g. "ko-KR"); nil = don't set region/language.
    public var regionLocale: String?
    /// Windows time-zone name (e.g. "Korea Standard Time"); nil = omit.
    public var regionTimeZone: String?
    public var disableBitLocker: Bool

    public init(bypassWin11: Bool = false, localAccountUsername: String? = nil, skipPrivacy: Bool = false,
                regionLocale: String? = nil, regionTimeZone: String? = nil, disableBitLocker: Bool = false) {
        self.bypassWin11 = bypassWin11
        self.localAccountUsername = localAccountUsername
        self.skipPrivacy = skipPrivacy
        self.regionLocale = regionLocale
        self.regionTimeZone = regionTimeZone
        self.disableBitLocker = disableBitLocker
    }

    public var isEmpty: Bool {
        !bypassWin11 && localAccountUsername == nil && !skipPrivacy
            && regionLocale == nil && !disableBitLocker
    }
}

/// Best-effort IANA → Windows time-zone name lookup for common zones.
public enum WindowsTimeZone {
    static let map: [String: String] = [
        "UTC": "UTC",
        "America/Los_Angeles": "Pacific Standard Time",
        "America/Denver": "Mountain Standard Time",
        "America/Chicago": "Central Standard Time",
        "America/New_York": "Eastern Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time",
        "Europe/London": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time",
        "Europe/Moscow": "Russian Standard Time",
        "Asia/Seoul": "Korea Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time",
        "Asia/Shanghai": "China Standard Time",
        "Asia/Kolkata": "India Standard Time",
        "Asia/Dubai": "Arabian Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time",
    ]
    public static func windowsName(forIANA iana: String) -> String? { map[iana] }
}
