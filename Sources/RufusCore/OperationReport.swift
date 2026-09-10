import Foundation

/// A snapshot of one operation, retained independently of subsequent UI selections.
public struct OperationReport: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let appVersion: String
    public let task: String
    public let sourceName: String?
    public let target: String
    public let options: [String]
    public private(set) var finishedAt: Date?
    public private(set) var succeeded: Bool?
    public private(set) var phase: String?
    public private(set) var error: String?

    public init(appVersion: String, task: String, sourceName: String?, target: String,
                options: [String], startedAt: Date = Date()) {
        self.appVersion = appVersion
        self.task = task
        self.sourceName = sourceName
        self.target = target
        self.options = options
        self.startedAt = startedAt
    }

    public mutating func finish(phase: String, error: String?, at date: Date = Date()) {
        guard finishedAt == nil else { return }
        finishedAt = date
        succeeded = error == nil
        self.phase = phase
        self.error = error
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
