// thai-ocr.swift — turn scanned PDF books into text for Meaw Meaw Read, entirely on this Mac.
//
// Uses Apple's built-in Vision text recognition (the engine behind Live Text), which reads Thai
// well, works offline, costs nothing and never touches claude.ai.
//
// Usage:  thai-ocr <file.pdf | folder> [output-folder]     convert PDFs to <name>.book.json (+ <name>.cover.jpg)
//         thai-ocr --seal <library> <books> <vault.json>   encrypt the library for the public website
//         thai-ocr --vault <vault.json> <index.html>       new password: new salt + check value
// The password comes from the NOVEL_PASSWORD environment variable (the novel CLI reads it from the Keychain).

import Foundation
import PDFKit
import Vision
import AppKit
import CryptoKit
import CommonCrypto

struct Line { let text: String; let minX: Double; let maxX: Double; let top: Double; let height: Double }

func isThai(_ c: Character?) -> Bool {
    guard let s = c?.unicodeScalars.first else { return false }
    return (0x0E00...0x0E7F).contains(s.value)
}

/// Render one PDF page to a bitmap big enough for small print.
func renderPage(_ page: PDFPage, longSide: CGFloat) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let scale = longSide / max(box.width, box.height)
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// Read the text lines on an image with Vision, top to bottom.
func recognize(_ image: CGImage) throws -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["th-TH", "en-US"]
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
    let lines = (req.results ?? []).compactMap { obs -> Line? in
        guard let t = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let b = obs.boundingBox   // normalised, origin bottom-left
        return Line(text: t, minX: b.minX, maxX: b.maxX, top: 1 - b.maxY, height: b.height)
    }
    // Vision may split one printed line into pieces; merge pieces that share a baseline
    var merged: [Line] = []
    for l in lines.sorted(by: { $0.top < $1.top }) {
        if let last = merged.last, abs(last.top - l.top) < min(last.height, l.height) * 0.5 {
            let (a, b) = last.minX <= l.minX ? (last, l) : (l, last)
            merged[merged.count - 1] = Line(text: a.text + " " + b.text, minX: a.minX, maxX: max(a.maxX, b.maxX),
                                            top: min(a.top, b.top), height: max(a.height, b.height))
        } else { merged.append(l) }
    }
    return merged
}

/// Group lines into paragraphs using line spacing and first-line indents.
func paragraphs(_ raw: [Line]) -> [String] {
    // drop running page numbers like “12” or “- 12 -”
    let lines = raw.filter { !$0.text.allSatisfy { "0123456789๐๑๒๓๔๕๖๗๘๙-–—. |".contains($0) } }
    guard !lines.isEmpty else { return [] }
    var gaps: [Double] = []
    for i in 1..<max(1, lines.count) where lines.count > 1 { gaps.append(lines[i].top - lines[i - 1].top) }
    let typical = gaps.filter { $0 > 0 }.sorted().dropFirst(gaps.count / 4).first ?? 0
    let left = lines.map(\.minX).sorted()[lines.count / 4]          // body text left edge
    let right = lines.map(\.maxX).sorted()[lines.count * 3 / 4]     // body text right edge
    var out: [String] = []
    var cur = lines[0].text
    for i in 1..<lines.count {
        let prev = lines[i - 1], l = lines[i]
        let bigGap = typical > 0 && (l.top - prev.top) > typical * 1.5
        let indented = l.minX - left > l.height * 0.8
        let prevShort = prev.maxX < right - (right - left) * 0.15        // previous line ended early
        if bigGap || indented || (prevShort && l.minX - left > l.height * 0.3) {
            out.append(cur); cur = l.text
        } else if cur.hasSuffix("-") && !isThai(l.text.first) {
            cur = String(cur.dropLast()) + l.text
        } else if isThai(cur.last) && isThai(l.text.first) {
            cur += l.text                                                  // Thai words join without a space
        } else {
            cur += " " + l.text
        }
    }
    out.append(cur)
    return out.map { $0.replacingOccurrences(of: "  ", with: " ") }
}

func jpegData(_ image: CGImage, width: CGFloat) -> Data? {
    let scale = width / CGFloat(image.width)
    let w = Int(width), h = Int(CGFloat(image.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let small = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
    return data
}

func convert(_ url: URL, into outDir: URL) throws {
    guard let doc = PDFDocument(url: url) else { throw NSError(domain: "thai-ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: "เปิดไฟล์ไม่ได้"]) }
    let name = url.deletingPathExtension().lastPathComponent
    var pages: [[String]] = []
    var cover: Data?
    let started = Date()
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i), let img = renderPage(page, longSide: 2600) else { pages.append([]); continue }
        if i == 0 { cover = jpegData(img, width: 420) }
        pages.append(paragraphs(try recognize(img)))
        let done = i + 1
        let eta = Date().timeIntervalSince(started) / Double(done) * Double(doc.pageCount - done)
        print("\r  หน้า \(done)/\(doc.pageCount)  (เหลืออีกประมาณ \(Int(eta)) วินาที)   ", terminator: "")
        fflush(stdout)
    }
    print("")
    let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
    var book: [String: Any] = ["format": "reader-book/1", "title": title, "source": url.lastPathComponent,
                               "numPages": doc.pageCount, "updated": ISO8601DateFormatter().string(from: Date()), "pages": pages]
    if let cover {
        book["cover"] = "data:image/jpeg;base64," + cover.base64EncodedString()
        try cover.write(to: outDir.appendingPathComponent(name + ".cover.jpg"))
    }
    let json = try JSONSerialization.data(withJSONObject: book, options: [.withoutEscapingSlashes])
    let out = outDir.appendingPathComponent(name + ".book.json")
    try json.write(to: out)
    print("  ✓ บันทึกแล้ว: \(out.path)")
}

// ---- encryption for the public website ----
// Books are published only as AES-256-GCM ciphertext. The key comes from the site password with
// PBKDF2-SHA256 (salt + rounds in tools/vault.json, also embedded in index.html); the browser derives
// the same key with WebCrypto. File format: 12-byte nonce || ciphertext || 16-byte tag.

let vaultCheckText = "meaw meaw read"

func password() -> String {
    guard let pw = ProcessInfo.processInfo.environment["NOVEL_PASSWORD"], !pw.isEmpty else {
        print("✗ ไม่พบรหัสเว็บ ตั้งรหัสด้วย ./novel password"); exit(1)
    }
    return pw
}

func deriveKey(_ pw: String, salt: Data, rounds: Int) -> SymmetricKey {
    var out = [UInt8](repeating: 0, count: 32)
    let pwBytes = Array(pw.utf8)
    _ = salt.withUnsafeBytes { s in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pwBytes.count,
                             s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
    }
    return SymmetricKey(data: out)
}

func seal(_ data: Data, _ key: SymmetricKey) throws -> Data { try AES.GCM.seal(data, using: key).combined! }

struct Vault { let salt: Data; let rounds: Int; let check: Data }

func readVault(_ url: URL) throws -> Vault {
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    guard let s = obj["salt"] as? String, let salt = Data(base64Encoded: s), let rounds = obj["rounds"] as? Int,
          let c = obj["check"] as? String, let check = Data(base64Encoded: c) else {
        throw NSError(domain: "vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "อ่าน \(url.lastPathComponent) ไม่ได้"])
    }
    return Vault(salt: salt, rounds: rounds, check: check)
}

/// New salt + check value for a (new) password; writes vault.json and the VAULT constant in index.html.
func makeVault(_ vaultURL: URL, page: URL) throws {
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let rounds = 310_000
    let key = deriveKey(password(), salt: salt, rounds: rounds)
    let check = try seal(Data(vaultCheckText.utf8), key)
    let json = "{\"salt\":\"\(salt.base64EncodedString())\",\"rounds\":\(rounds),\"check\":\"\(check.base64EncodedString())\"}"
    try Data((json + "\n").utf8).write(to: vaultURL)
    var html = try String(contentsOf: page, encoding: .utf8)
    guard let a = html.range(of: "/*VAULT*/"), let b = html.range(of: "/*END VAULT*/", range: a.upperBound..<html.endIndex) else {
        throw NSError(domain: "vault", code: 2, userInfo: [NSLocalizedDescriptionKey: "ไม่พบ /*VAULT*/ ใน index.html"])
    }
    html.replaceSubrange(a.upperBound..<b.lowerBound, with: json)
    try html.write(to: page, atomically: true, encoding: .utf8)
    print("✓ ตั้งรหัสใหม่แล้ว")
}

func opaqueName(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// Encrypt every library/<name>.book.json (+ cover) into books/<id>.book.enc and books/index.enc.
func sealLibrary(_ lib: URL, into out: URL, vaultURL: URL) throws {
    let v = try readVault(vaultURL)
    let key = deriveKey(password(), salt: v.salt, rounds: v.rounds)
    // refuse to publish with a password that doesn't match the website's
    guard (try? AES.GCM.open(AES.GCM.SealedBox(combined: v.check), using: key)) == Data(vaultCheckText.utf8) else {
        print("✗ รหัสในเครื่องไม่ตรงกับรหัสเว็บ ตั้งใหม่ด้วย ./novel password"); exit(1)
    }
    let fm = FileManager.default
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let files = ((try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasSuffix(".book.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var entries: [[String: Any]] = []
    var keep = Set(["index.enc"])
    for f in files {
        let raw = try Data(contentsOf: f)
        guard let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
        let name = String(f.lastPathComponent.dropLast(".book.json".count))
        let id = opaqueName(name)
        try seal(raw, key).write(to: out.appendingPathComponent(id + ".book.enc")); keep.insert(id + ".book.enc")
        var e: [String: Any] = ["id": id, "title": obj["title"] as? String ?? name, "source": obj["source"] as? String ?? "",
                                "numPages": obj["numPages"] as? Int ?? 0, "updated": obj["updated"] as? String ?? ""]
        let cover = lib.appendingPathComponent(name + ".cover.jpg")
        if let c = try? Data(contentsOf: cover) {
            try seal(c, key).write(to: out.appendingPathComponent(id + ".cover.enc")); keep.insert(id + ".cover.enc"); e["cover"] = true
        }
        entries.append(e)
    }
    let index = try JSONSerialization.data(withJSONObject: ["format": "reader-shelf/2", "books": entries], options: [.withoutEscapingSlashes])
    try seal(index, key).write(to: out.appendingPathComponent("index.enc"))
    for f in (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(f.lastPathComponent) {
        try? fm.removeItem(at: f)   // books removed from the library, or old unencrypted files
    }
    print("ชั้นหนังสือบนเว็บมี \(entries.count) เล่ม (เข้ารหัสแล้ว)")
}

// ---- main ----
let args = CommandLine.arguments.dropFirst()
if args.first == "--seal" {   // --seal <library> <books> <vault.json>
    let a = Array(args.dropFirst())
    guard a.count == 3 else { print("วิธีใช้: thai-ocr --seal <library> <books> <vault.json>"); exit(1) }
    do { try sealLibrary(URL(fileURLWithPath: a[0]), into: URL(fileURLWithPath: a[1]), vaultURL: URL(fileURLWithPath: a[2])) }
    catch { print("✗ \(error.localizedDescription)"); exit(1) }
    exit(0)
}
if args.first == "--vault" {  // --vault <vault.json> <index.html>
    let a = Array(args.dropFirst())
    guard a.count == 2 else { print("วิธีใช้: thai-ocr --vault <vault.json> <index.html>"); exit(1) }
    do { try makeVault(URL(fileURLWithPath: a[0]), page: URL(fileURLWithPath: a[1])) }
    catch { print("✗ \(error.localizedDescription)"); exit(1) }
    exit(0)
}
guard let input = args.first else {
    print("วิธีใช้: swift tools/thai-ocr.swift <ไฟล์.pdf หรือโฟลเดอร์> [โฟลเดอร์ผลลัพธ์]")
    exit(1)
}
let inURL = URL(fileURLWithPath: input)
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: inURL.path, isDirectory: &isDir) else { print("ไม่พบ \(input)"); exit(1) }
let pdfs: [URL] = isDir.boolValue
    ? ((try? FileManager.default.contentsOfDirectory(at: inURL, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    : [inURL]
let outDir = args.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? (isDir.boolValue ? inURL : inURL.deletingLastPathComponent())
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
if pdfs.isEmpty { print("ไม่มีไฟล์ PDF ใน \(input)"); exit(0) }
for (n, pdf) in pdfs.enumerated() {
    print("[\(n + 1)/\(pdfs.count)] \(pdf.lastPathComponent)")
    do { try convert(pdf, into: outDir) } catch { print("  ✗ \(error.localizedDescription)") }
}
