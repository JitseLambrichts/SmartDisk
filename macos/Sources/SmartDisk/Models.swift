import Foundation

// Mirrors the JSON printed by `slim --json`. Keys are converted from snake_case.

struct DriveStatus: Decodable, Equatable {
    var daemonRunning: Bool
    var state: String
    var progressDone: Int
    var progressTotal: Int
    var current: String?
    var lastScan: Int?
    var mount: Mount?
    var filesTotal: Int
    var filesIndexed: Int
    var generation: Int
    var folders: [Folder]
    var config: DriveConfig
    var dataDir: String

    var isIndexing: Bool { state == "indexing" }
    var categories: [Folder] { folders.filter { $0.kind == "category" } }
    var smartFolders: [Folder] { folders.filter { $0.kind == "smart_folder" } }
}

struct Mount: Decodable, Equatable {
    var backend: String
    var path: String
}

struct Folder: Decodable, Equatable, Hashable, Identifiable {
    var name: String
    var kind: String
    var symbol: String
    var count: Int
    var chips: [String]

    var id: String { name }
    var isSmart: Bool { kind == "smart_folder" }
}

struct DriveConfig: Codable, Equatable {
    var folders: [String]
    var sensitiveEnabled: Bool
    /// Built-in categories the user removed, by id.
    var hiddenCategories: [String]?
    var storeFullText: Bool
    var pauseOnBattery: Bool
    var paused: Bool
    var useAppleIntelligence: Bool
    var fuseMountPoint: String
    var mirrorPath: String
    var inboxPath: String
    var helperPath: String?
}

/// A built-in category, as `slim categories` lists it.
struct CategoryInfo: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var sensitive: Bool
    var hidden: Bool
}

struct Item: Decodable, Equatable, Hashable, Identifiable {
    var name: String
    var fileId: Int64
    var original: String
    var origin: String
    var size: Int64
    var kind: String
    var docDate: String?
    var fileDate: String
    var amount: Double?
    var currency: String?
    var score: Double
    var reasons: [String]

    var id: Int64 { fileId }
    var url: URL { URL(fileURLWithPath: original) }
    /// The date shown in lists: the document's own date when known.
    var displayDate: String { docDate ?? fileDate }
}

/// A file whose text holds the words searched for, with the words around them.
struct TextHit: Decodable {
    var fileId: Int64
    var snippet: String
}

struct QueryResult: Decodable {
    var chips: [String]
    var items: [Item]
}

struct ParseResult: Decodable {
    var chips: [String]
}

struct Amount: Decodable, Equatable, Hashable {
    var value: Double
    var currency: String
    var isTotal: Bool
}

struct Facts: Decodable, Equatable {
    var amounts: [Amount]
    var dates: [String]
    var docDate: String?
    var vatNumbers: [String]
    var ibans: [String]
    var emails: [String]
    var mrz: Bool
    var hasCode: Bool

    var mainAmount: Amount? {
        amounts.filter(\.isTotal).max { $0.value < $1.value } ?? amounts.max { $0.value < $1.value }
    }
}

struct Placement: Decodable, Equatable, Hashable, Identifiable {
    var folder: String
    var kind: String
    var included: Bool
    var score: Double
    var source: String
    var reasons: [String]

    var id: String { folder + source }
}

struct Explanation: Decodable, Equatable {
    var fileId: Int64
    var original: String
    var kind: String
    var textMethod: String
    var textChars: Int
    var facts: Facts
    var askedFolder: String?
    var placements: [Placement]
    var snippets: [String]
}

struct LogRow: Decodable, Identifiable, Equatable {
    var ts: Int
    var level: String
    var message: String
    var id: String { "\(ts)-\(message)" }
}

struct Capabilities: Decodable, Equatable {
    var helper: String?
    var ocr: Bool
    var foundationModels: Bool
    var foundationModelsReason: String?
    var fuse: Bool
    var embedder: String
}

/// One-line, human description of how a file's text was obtained.
func describeMethod(_ method: String) -> String {
    switch method {
    case "plain": "Plain text"
    case "pdfkit": "PDF text layer"
    case "pdfkit+vision-ocr": "Scanned PDF, read with on-device OCR"
    case "vision-ocr": "Image, read with on-device OCR"
    case "attributed-string": "Document converter"
    case "pages-preview": "Pages preview"
    case "name-only": "File name only"
    default: method
    }
}
