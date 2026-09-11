import Foundation

public struct SetupPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: [String: String]
    public var driverNames: [String]
    public init(id: UUID = UUID(), name: String, settings: [String: String], driverNames: [String]) {
        self.id = id; self.name = name; self.settings = settings; self.driverNames = driverNames
    }
}

/// Atomic replacement leaves the previous valid file intact when a save fails.
public enum RecordFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let parts: [Int]
    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else { return nil }
        let numbers = components.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == components.count else { return nil }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
