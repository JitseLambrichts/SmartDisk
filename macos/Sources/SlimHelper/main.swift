// slim-helper: the Rust core's window into Apple frameworks.
//
//   slim-helper extract <file>        → {"text": "...", "method": "..."}
//   slim-helper parse-query <name>    → {"category": ..., "free_text": ..., ...}
//   slim-helper capabilities          → {"ocr": true, "foundation_models": ...}
//
// Everything runs on device. Nothing leaves the Mac.

import AppKit
import Foundation
import PDFKit
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Output

func emit(_ object: [String: Any?]) {
    let clean = object.mapValues { $0 ?? NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("slim-helper: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - OCR

let ocrLanguages = ["nl-NL", "en-US", "fr-FR", "de-DE"]

func recognizeText(in image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    request.recognitionLanguages = ocrLanguages.filter { supported.contains($0) }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return ""
    }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    // Downscale huge photos; OCR does not need 48 megapixels.
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 3000,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func render(page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale: CGFloat = 2
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard width > 0, height > 0,
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

// MARK: - Extraction

func extractPDF(_ url: URL) -> (String, String) {
    guard let doc = PDFDocument(url: url) else { fail("cannot open PDF") }
    if doc.isLocked { return ("", "pdf-locked") }
    var text = doc.string ?? ""
    let pages = doc.pageCount
    // A scan has (almost) no text layer: fall back to OCR on the first pages.
    if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 25 * max(pages, 1) {
        var ocr: [String] = []
        for i in 0..<min(pages, 10) {
            if let page = doc.page(at: i), let image = render(page: page) {
                ocr.append(recognizeText(in: image))
            }
        }
        let joined = ocr.joined(separator: "\n\n")
        if joined.count > text.count {
            text = joined
            return (text, "pdfkit+vision-ocr")
        }
    }
    return (text, "pdfkit")
}

func extractDocument(_ url: URL) -> (String, String) {
    if url.pathExtension.lowercased() == "pages" {
        // Pages files carry a PDF preview; read that.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let preview = url.appendingPathComponent("QuickLook/Preview.pdf")
            if FileManager.default.fileExists(atPath: preview.path) { return extractPDF(preview) }
            return ("", "unsupported-pages")
        }
        // Single-file Pages documents are zip archives.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, "QuickLook/Preview.pdf"]
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        unzip.standardOutput = try? FileHandle(forWritingTo: tmp)
        unzip.standardError = FileHandle.nullDevice
        try? unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus == 0, let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int, size > 0 {
            let (text, _) = extractPDF(tmp)
            return (text, "pages-preview")
        }
        return ("", "unsupported-pages")
    }
    if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
        return (attributed.string, "attributed-string")
    }
    return ("", "unsupported")
}

func extract(_ path: String) {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    let result: (String, String)
    switch ext {
    case "pdf":
        result = extractPDF(url)
    case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp":
        guard let image = loadImage(url) else { fail("cannot decode image") }
        result = (recognizeText(in: image), "vision-ocr")
    default:
        result = extractDocument(url)
    }
    emit(["text": result.0, "method": result.1])
}

// MARK: - Folder names → queries (Apple Intelligence)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct FolderQuery {
    @Guide(description: "Which built-in category the folder is about, or none", .anyOf(["invoices", "contracts", "id_documents", "screenshots", "photos", "housing", "none"]))
    var category: String

    @Guide(description: "Four-digit year mentioned in the folder name, or 0 when none is mentioned")
    var year: Int

    @Guide(description: "Minimum amount of money mentioned (e.g. 'over 100 euro' gives 100), or 0")
    var amountMin: Double

    @Guide(description: "Topic words that are not a category, year, amount or file type, in the folder name's language. Empty when nothing is left.")
    var freeText: String
}
#endif

func parseQuery(_ name: String) async {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { fail("Apple Intelligence is not available") }
        let session = LanguageModelSession(instructions: """
            You read folder names on a smart drive and turn them into search fields. \
            Folder names may be Dutch or English. Only extract what is literally there; never invent numbers.
            """)
        do {
            let response = try await session.respond(to: "Folder name: \(name)", generating: FolderQuery.self)
            let q = response.content
            emit([
                "category": q.category == "none" ? nil : q.category,
                "year": q.year > 0 ? q.year : nil,
                "amount_min": q.amountMin > 0 ? q.amountMin : nil,
                "free_text": q.freeText.isEmpty ? nil : q.freeText,
            ])
            return
        } catch {
            fail("model error: \(error.localizedDescription)")
        }
    }
    #endif
    fail("Foundation Models framework not available")
}

func capabilities() {
    var fm = false
    var reason: String? = "Foundation Models framework not available"
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            fm = true
            reason = nil
        case .unavailable(let why):
            reason = String(describing: why)
        }
    }
    #endif
    emit(["ocr": true, "foundation_models": fm, "foundation_models_reason": reason])
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: slim-helper extract <file> | parse-query <name> | capabilities") }
switch args[1] {
case "extract" where args.count >= 3:
    extract(args[2])
case "parse-query" where args.count >= 3:
    await parseQuery(args[2...].joined(separator: " "))
case "capabilities":
    capabilities()
default:
    fail("unknown command \(args[1])")
}
