import Foundation

/// Interpolation keeps user data separate from translation keys and permits argument reordering.
public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let arguments: [String]
    public init(key: String, arguments: [String] = []) { self.key = key; self.arguments = arguments }
    public init(stringLiteral value: String) { self.init(key: value) }
    public init(stringInterpolation: StringInterpolation) {
        self.init(key: stringInterpolation.key, arguments: stringInterpolation.arguments)
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

public struct AppLanguageDefinition: Codable, Identifiable, Sendable {
    public let id: String
    public let nativeName: String
}

public struct LocalizationCatalog: Sendable {
    public let languages: [AppLanguageDefinition]
    private let translations: [String: [String: String]]

    public init() { self.init(bundle: .module) }

    public init(bundle: Bundle) {
        let decoder = JSONDecoder()
        languages = bundle.url(forResource: "languages", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode([AppLanguageDefinition].self, from: $0) } ?? []
        var tables: [String: [String: String]] = [:]
        for language in languages {
            if let url = bundle.url(forResource: language.id, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let table = try? decoder.decode([String: String].self, from: data) {
                tables[language.id] = table
            }
        }
        translations = tables
    }

    public func resolve(selection: String, preferredLanguages: [String]) -> String {
        if selection != "system", translations[selection] != nil { return selection }
        for preference in preferredLanguages {
            let canonical = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            if translations[canonical] != nil { return canonical }
            if let base = canonical.split(separator: "-").first, translations[String(base)] != nil {
                return String(base)
            }
        }
        return "en"
    }

    public func text(_ message: Message, language: String) -> String {
        let template = translations[language]?[message.key] ?? translations["en"]?[message.key] ?? message.key
        // Replace in a single pass: a filename containing "{1}" must remain literal data.
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = template as NSString
        var result = template
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let index = Int(source.substring(with: match.range(at: 1))), message.arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: message.arguments[index])
        }
        return result
    }

    public func table(for language: String) -> [String: String] { translations[language] ?? [:] }
}
