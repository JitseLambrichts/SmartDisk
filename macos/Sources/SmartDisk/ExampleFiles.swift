import AppKit
import CoreText

/// A small set of made-up documents for the tour, like `scripts/make-fixtures.swift`.
/// PDFs get a text layer; PNGs are images of text, so they show on-device OCR at work.
enum ExampleFiles {
    /// Next to the drive's own data, so trying the tour needs no folder access prompt.
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SmartDisk Examples", isDirectory: true)
    }

    /// The file the tour opens: an invoice that is also about housing, so it sits in two folders.
    static var showcase: URL { folder.appendingPathComponent("Downloads/rent-invoice-0423.pdf") }

    static var exists: Bool { FileManager.default.fileExists(atPath: showcase.path) }

    /// Writes every example document. Existing ones are replaced.
    static func write() throws {
        // Every name and identifier below is fictitious test data.
        try pdf("""
        INVOICE 2026-0423
        Invoice date: 04/03/2026
        Landlord: Example Student Homes
        Description: Student room rent for March
        Rent: EUR 450.00
        Service charge: EUR 25.00
        Total amount due: EUR 475.00
        Due date: 31/03/2026
        """, "rent-invoice-0423.pdf", in: "Downloads")

        try pdf("""
        INVOICE #88412
        Invoice date: 12 January 2026
        Example Electronics
        1x USB-C hub EUR 39.99
        Subtotal EUR 33.05
        VAT 21% EUR 6.94
        Total EUR 39.99
        """, "electronics-invoice.pdf", in: "Downloads")

        try pdf("""
        INVOICE F-2026-118
        Invoice date: 15/09/2026
        Example Energy
        Electricity and gas, September advance payment
        Total amount due: EUR 132.40
        """, "energy-september.pdf", in: "Documents/Housing")

        try pdf("""
        TENANCY AGREEMENT FOR A STUDENT ROOM
        Between the landlord, Example Student Homes, and the tenant, Sam Example.
        Article 1: This agreement lasts twelve months from 1 September 2025.
        Article 2: Rent is EUR 450 per month, payable by the fifth day.
        Article 3: The deposit is equal to two months of rent.
        Article 4: The tenant can end the agreement with a notice period of three months.
        Article 5: The parties inspect the room at the start and end of the tenancy.
        Signed on 20 August 2025. Landlord signature — Tenant signature.
        """, "student-tenancy-agreement.pdf", in: "Documents/Housing")

        try pdf("""
        EMPLOYMENT CONTRACT — STUDENT JOB
        The parties are Example Bakery and Sam Example, the employee.
        Article 1: The employee works on Saturday from 8 a.m. until 2 p.m.
        Article 2: Gross pay is EUR 14.20 per hour, subject to applicable deductions.
        Article 3: Either party can terminate this agreement under the agreed terms.
        The employer provides the equipment required for the role.
        Signed on 2 February 2026. Employer signature — Employee signature.
        """, "student-employment-contract.pdf", in: "Documents")

        try png("""
        FICTIONAL IDENTITY CARD — TEST DATA ONLY
        Surname: EXAMPLE
        Given name: Sam
        Nationality: Example
        Date of birth: 01 January 2003
        This is not a valid identity document.
        """, "sample-identity-card.png", in: "Documents/Scans", width: 1400, height: 900)

        try png("""
        Messages
        Your example verification code is 482913.
        This is fictitious test data.
        """, "Screenshot 2026-10-02 at 14.21.07.png", in: "Desktop", width: 1200, height: 700)

        try png("""
        Weather today: sunny, 18°C
        Tomorrow: cloudy
        """, "Screenshot 2026-09-12 at 09.03.44.png", in: "Desktop", width: 1200, height: 700)

        try pdf("""
        Example University — Faculty of Economics
        Course: Statistics I — chapter 3
        Exam in January. Classes on Tuesday.
        """, "statistics-chapter3.pdf", in: "Downloads")

        try txt("""
        Shopping: milk, bread, cheese, apples, coffee
        """, "shopping.txt", in: "Documents")

        try pdf("""
        Example Tax Office — tax statement
        Tax year 2025
        Taxable pay: EUR 4,280.00
        Date: 28/02/2025
        """, "tax-statement-2025.pdf", in: "Documents/Taxes")
    }

    /// Moves the examples to the Trash, so they can still be brought back.
    static func remove() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    // MARK: Writers

    private struct Failure: LocalizedError {
        var name: String
        var errorDescription: String? { "Could not write the example file \(name)." }
    }

    private static func directory(_ dir: String) throws -> URL {
        let url = folder.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pdf(_ text: String, _ name: String, in dir: String) throws {
        let url = try directory(dir).appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Failure(name: name) }
        ctx.beginPDFPage(nil)
        draw(text, in: ctx, rect: box.insetBy(dx: 50, dy: 60), size: 13)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func png(_ text: String, _ name: String, in dir: String, width: Int, height: Int) throws {
        let url = try directory(dir).appendingPathComponent(name)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure(name: name) }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: ctx, rect: CGRect(x: 60, y: 60, width: width - 120, height: height - 120), size: 34)
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(name: name) }
        try data.write(to: url)
    }

    private static func txt(_ text: String, _ name: String, in dir: String) throws {
        try text.write(to: directory(dir).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func draw(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)),
            CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}
