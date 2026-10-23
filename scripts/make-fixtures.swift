// Generates a small, fake document set for trying the Smart Disk safely:
//   swift scripts/make-fixtures.swift <output-folder>
// PDFs get a text layer; PNGs are images of text, so they exercise OCR.

import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "fixtures")
let fm = FileManager.default

func write(_ text: String, pdf name: String, in dir: String) {
    let folder = out.appendingPathComponent(dir)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(folder.appendingPathComponent(name) as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    draw(text, in: ctx, rect: box.insetBy(dx: 50, dy: 60), size: 13)
    ctx.endPDFPage()
    ctx.closePDF()
}

func write(_ text: String, png name: String, in dir: String, width: Int = 1400, height: Int = 900) {
    let folder = out.appendingPathComponent(dir)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(text, in: ctx, rect: CGRect(x: 60, y: 60, width: width - 120, height: height - 120), size: 34)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

func draw(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
    let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)),
        CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
}

func write(_ text: String, txt name: String, in dir: String) {
    let folder = out.appendingPathComponent(dir)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try! text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// Every name and identifier below is fictitious test data.
write("""
INVOICE 2026-0423
Invoice date: 04/03/2026
Landlord: Example Student Homes
Description: Student room rent for March
Rent: EUR 450.00
Service charge: EUR 25.00
Total amount due: EUR 475.00
Due date: 31/03/2026
""", pdf: "rent-invoice-0423.pdf", in: "Downloads")

write("""
INVOICE #88412
Invoice date: 12 January 2026
Example Electronics
1x USB-C hub EUR 39.99
Subtotal EUR 33.05
VAT 21% EUR 6.94
Total EUR 39.99
""", pdf: "electronics-invoice.pdf", in: "Downloads")

write("""
INVOICE F-2026-118
Invoice date: 15/09/2026
Example Energy
Electricity and gas, September advance payment
Total amount due: EUR 132.40
""", pdf: "energy-september.pdf", in: "Documents/Housing")

write("""
TENANCY AGREEMENT FOR A STUDENT ROOM
Between the landlord, Example Student Homes, and the tenant, Sam Example.
Article 1: This agreement lasts twelve months from 1 September 2025.
Article 2: Rent is EUR 450 per month, payable by the fifth day.
Article 3: The deposit is equal to two months of rent.
Article 4: The tenant can end the agreement with a notice period of three months.
Article 5: The parties inspect the room at the start and end of the tenancy.
Signed on 20 August 2025. Landlord signature — Tenant signature.
""", pdf: "student-tenancy-agreement.pdf", in: "Documents/Housing")

write("""
EMPLOYMENT CONTRACT — STUDENT JOB
The parties are Example Bakery and Sam Example, the employee.
Article 1: The employee works on Saturday from 8 a.m. until 2 p.m.
Article 2: Gross pay is EUR 14.20 per hour, subject to applicable deductions.
Article 3: Either party can terminate this agreement under the agreed terms.
The employer provides the equipment required for the role.
Signed on 2 February 2026. Employer signature — Employee signature.
""", pdf: "student-employment-contract.pdf", in: "Documents")

write("""
FICTIONAL IDENTITY CARD — TEST DATA ONLY
Surname: EXAMPLE
Given name: Sam
Nationality: Example
Date of birth: 01 January 2003
This is not a valid identity document.
""", png: "sample-identity-card.png", in: "Documents/Scans", width: 1400, height: 900)

write("""
Messages
Your example verification code is 482913.
This is fictitious test data.
""", png: "Screenshot 2026-10-02 at 14.21.07.png", in: "Desktop", width: 1200, height: 700)

write("""
Weather today: sunny, 18°C
Tomorrow: cloudy
""", png: "Screenshot 2026-09-12 at 09.03.44.png", in: "Desktop", width: 1200, height: 700)

write("""
Example University — Faculty of Economics
Course: Statistics I — chapter 3
Exam in January. Classes on Tuesday.
""", pdf: "statistics-chapter3.pdf", in: "Downloads")

write("""
Shopping: milk, bread, cheese, apples, coffee
""", txt: "shopping.txt", in: "Documents")

write("""
Example Tax Office — tax statement
Tax year 2025
Taxable pay: EUR 4,280.00
Date: 28/02/2025
""", pdf: "tax-statement-2025.pdf", in: "Documents/Taxes")

print("Sample documents written to \(out.path)")
