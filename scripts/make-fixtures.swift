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

write("""
FACTUUR 2026-0423
Factuurdatum: 04/03/2026
Verhuurder: Kotbaas BV, Naamsestraat 12, 3000 Leuven
BTW BE 0123.456.789
Omschrijving: Huur studentenkamer maart
Huurprijs € 450,00
Vaste kosten € 25,00
Totaal te betalen: € 475,00
IBAN BE68 5390 0754 7034 — vervaldatum 31/03/2026
""", pdf: "factuur-0423.pdf", in: "Downloads")

write("""
INVOICE #88412
Invoice date: 12 January 2026
Coolblue B.V. — VAT NL123456789B01
1x USB-C hub     € 39,99
Subtotal € 33,05
VAT 21% € 6,94
Total € 39,99
""", pdf: "invoice-coolblue.pdf", in: "Downloads")

write("""
FACTUUR F-2026-118
Factuurdatum: 15/09/2026
Fluvius — energie
Elektriciteit en gas, voorschot september
Totaal te betalen: € 132,40
BTW BE 0477.445.084
""", pdf: "energie-september.pdf", in: "Documents/Wonen")

write("""
HUUROVEREENKOMST VOOR STUDENTENKAMER

Tussen de partijen:
De verhuurder, Kotbaas BV, en de huurder, Sam Peeters.

Artikel 1 — Duur: deze overeenkomst geldt voor twaalf maanden vanaf 1 september 2025.
Artikel 2 — Huurprijs: 450 euro per maand, te betalen vóór de vijfde van de maand.
Artikel 3 — Waarborg: de huurwaarborg bedraagt twee maanden huur.
Artikel 4 — Opzegtermijn: de huurder kan de overeenkomst opzeggen met een opzegtermijn van drie maanden.
Artikel 5 — Plaatsbeschrijving bij aanvang en einde van de huur.

Ondertekend te Leuven op 20 augustus 2025.
Handtekening verhuurder — Handtekening huurder
""", pdf: "huurcontract-kot.pdf", in: "Documents/Wonen")

write("""
ARBEIDSOVEREENKOMST — STUDENTENJOB

Tussen de werkgever Bakkerij Janssens en de werknemer, hierna de partijen.
Artikel 1. De werknemer werkt op zaterdag van 8 tot 14 uur.
Artikel 2. Het loon bedraagt 14,20 euro bruto per uur.
Artikel 3. Deze overeenkomst kan door beide partijen beëindigd worden zonder bijzondere voorwaarden.
Ondertekend op 2 februari 2026.
""", pdf: "studentenjob-contract.pdf", in: "Documents")

write("""
KONINKRIJK BELGIË — IDENTITEITSKAART
BELGIQUE · BELGIEN · BELGIUM
Naam: PEETERS
Voornamen: Sam
Nationaliteit: Belg
Geboortedatum: 01 01 2003
IDBEL5912345674<<<<<<<<<<<<<<<
0301012M3101017BEL<<<<<<<<<<<0
PEETERS<<SAM<<<<<<<<<<<<<<<<<<<
""", png: "scan-id-voorkant.png", in: "Documents/Scans", width: 1400, height: 900)

write("""
Messages
Your verification code is 482913.
Do not share this code with anyone.
""", png: "Screenshot 2026-10-02 at 14.21.07.png", in: "Desktop", width: 1200, height: 700)

write("""
Weather today: sunny, 18°C
Tomorrow: cloudy
""", png: "Screenshot 2026-09-12 at 09.03.44.png", in: "Desktop", width: 1200, height: 700)

write("""
KU Leuven — Faculteit Economie
Cursus: Statistiek I — syllabus hoofdstuk 3
Examen in januari. Lessen op dinsdag.
""", pdf: "statistiek-hoofdstuk3.pdf", in: "Downloads")

write("""
Boodschappen: melk, brood, kaas, appels, koffie
""", txt: "boodschappen.txt", in: "Documents")

write("""
FOD Financiën — fiscale fiche 281.10
Aanslagjaar 2025, inkomsten 2025
Belastbaar loon: 4.280,00 EUR
Datum: 28/02/2025
""", pdf: "fiscale-fiche-2025.pdf", in: "Documents/Belastingen")

print("fixtures written to \(out.path)")
