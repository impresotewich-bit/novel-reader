// thai-ocr.swift — turn scanned PDF books into text for Meaw Meaw Read, entirely on this Mac.
//
// Uses Apple's built-in Vision text recognition (the engine behind Live Text), which reads Thai
// well, works offline, costs nothing and never touches claude.ai.
//
// Usage:  thai-ocr <file.pdf | folder> [output-folder]     convert PDFs to <name>.book.json (+ <name>.cover.jpg)
//         thai-ocr --seal <library> <books> <vault.json>   encrypt the library for the public website
//         thai-ocr --vault <vault.json> <index.html>       new password: new salt + check value
//         thai-ocr --token <vault.json> <index.html>       store the shared GitHub key (NOVEL_GH_TOKEN) encrypted
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

/// Write encrypted data, leaving the file alone when its content is unchanged (fresh nonces would
/// otherwise rewrite every file and bloat the git history).
func writeSealed(_ data: Data, to url: URL, _ key: SymmetricKey) throws {
    if let old = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: old),
       (try? AES.GCM.open(box, using: key)) == data { return }
    try seal(data, key).write(to: url)
}

struct Vault { let salt: Data; let rounds: Int; let check: Data; var gh: Data?; var repo: String? }

func readVault(_ url: URL) throws -> Vault {
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    guard let s = obj["salt"] as? String, let salt = Data(base64Encoded: s), let rounds = obj["rounds"] as? Int,
          let c = obj["check"] as? String, let check = Data(base64Encoded: c) else {
        throw NSError(domain: "vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "อ่าน \(url.lastPathComponent) ไม่ได้"])
    }
    return Vault(salt: salt, rounds: rounds, check: check,
                 gh: (obj["gh"] as? String).flatMap { Data(base64Encoded: $0) }, repo: obj["repo"] as? String)
}

/// vault.json and the VAULT constant in index.html carry the same public values:
/// salt, rounds, an encrypted check string and (optionally) the encrypted shared GitHub key.
func writeVault(_ v: Vault, _ vaultURL: URL, page: URL) throws {
    var json = "{\"salt\":\"\(v.salt.base64EncodedString())\",\"rounds\":\(v.rounds),\"check\":\"\(v.check.base64EncodedString())\""
    if let gh = v.gh { json += ",\"gh\":\"\(gh.base64EncodedString())\"" }
    if let repo = v.repo { json += ",\"repo\":\"\(repo)\"" }
    json += "}"
    try Data((json + "\n").utf8).write(to: vaultURL)
    var html = try String(contentsOf: page, encoding: .utf8)
    guard let a = html.range(of: "/*VAULT*/"), let b = html.range(of: "/*END VAULT*/", range: a.upperBound..<html.endIndex) else {
        throw NSError(domain: "vault", code: 2, userInfo: [NSLocalizedDescriptionKey: "ไม่พบ /*VAULT*/ ใน index.html"])
    }
    html.replaceSubrange(a.upperBound..<b.lowerBound, with: json)
    try html.write(to: page, atomically: true, encoding: .utf8)
}

/// The shared GitHub key (NOVEL_GH_TOKEN), encrypted with the site key — only people who know the password can use it.
func sealedToken(_ key: SymmetricKey) throws -> Data? {
    guard let t = ProcessInfo.processInfo.environment["NOVEL_GH_TOKEN"], !t.isEmpty else { return nil }
    return try seal(Data(t.utf8), key)
}

/// New salt + check value for a (new) password; re-encrypts the shared GitHub key if there is one.
func makeVault(_ vaultURL: URL, page: URL) throws {
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let rounds = 310_000
    let key = deriveKey(password(), salt: salt, rounds: rounds)
    let old = try? readVault(vaultURL)
    let v = Vault(salt: salt, rounds: rounds, check: try seal(Data(vaultCheckText.utf8), key),
                  gh: try sealedToken(key), repo: ProcessInfo.processInfo.environment["NOVEL_REPO"] ?? old?.repo)
    try writeVault(v, vaultURL, page: page)
    print("✓ ตั้งรหัสใหม่แล้ว")
}

func siteKey(_ v: Vault) -> SymmetricKey {
    let key = deriveKey(password(), salt: v.salt, rounds: v.rounds)
    guard (try? AES.GCM.open(AES.GCM.SealedBox(combined: v.check), using: key)) == Data(vaultCheckText.utf8) else {
        print("✗ รหัสในเครื่องไม่ตรงกับรหัสเว็บ ตั้งใหม่ด้วย ./novel password"); exit(1)
    }
    return key
}

/// Store the shared GitHub key in the vault (same password, same salt).
func setToken(_ vaultURL: URL, page: URL) throws {
    var v = try readVault(vaultURL)
    let key = siteKey(v)
    v.gh = try sealedToken(key)
    v.repo = ProcessInfo.processInfo.environment["NOVEL_REPO"] ?? v.repo
    try writeVault(v, vaultURL, page: page)
    print(v.gh == nil ? "✓ เอากุญแจร่วมออกแล้ว" : "✓ เก็บกุญแจร่วม (เข้ารหัส) ในเว็บแล้ว")
}

func opaqueName(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

func readIndex(_ out: URL, _ key: SymmetricKey) -> [String: Any]? {
    guard let sealed = try? Data(contentsOf: out.appendingPathComponent("index.enc")),
          let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key) else { return nil }
    return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
}

let iso = ISO8601DateFormatter()

/// Encrypt every library/<name>.book.json (+ cover) into books/<id>.book.enc and books/index.enc.
/// Books added on the website are adopted into library/ first; books deleted on the website
/// (index "removed" list) are deleted from library/ unless the local copy is newer.
func sealLibrary(_ lib: URL, into out: URL, vaultURL: URL, drop: String? = nil) throws {
    let key = siteKey(try readVault(vaultURL))
    let fm = FileManager.default
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    try fm.createDirectory(at: lib, withIntermediateDirectories: true)
    let old = readIndex(out, key)
    var removed: [String: String] = [:]   // id -> ISO time it was deleted
    for r in (old?["removed"] as? [[String: Any]]) ?? [] { if let id = r["id"] as? String, let at = r["at"] as? String { removed[id] = at } }
    if let drop { removed[opaqueName(drop)] = iso.string(from: Date()) }
    try adoptWebBooks(lib, entries: (old?["books"] as? [[String: Any]]) ?? [], from: out, key: key, skip: Set(removed.keys))
    var files = ((try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: [.contentModificationDateKey]) ) ?? [])
        .filter { $0.lastPathComponent.hasSuffix(".book.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    // honour deletions made on other devices
    files = files.filter { f in
        let name = String(f.lastPathComponent.dropLast(".book.json".count)), id = opaqueName(name)
        guard let at = removed[id].flatMap(iso.date) else { return true }
        let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if id != drop.map(opaqueName), mtime > at.addingTimeInterval(1) { removed[id] = nil; return true }   // re-added here after the deletion
        try? fm.removeItem(at: f); try? fm.removeItem(at: lib.appendingPathComponent(name + ".cover.jpg"))
        print("  ✗ เอาออกตามที่ลบจากเว็บ: \(name)")
        return false
    }
    var entries: [[String: Any]] = []
    var keep = Set(["index.enc", "progress.enc"])
    var oldEntries: [String: [String: Any]] = [:]
    for e in (old?["books"] as? [[String: Any]]) ?? [] { if let id = e["id"] as? String { oldEntries[id] = e } }
    for f in files {
        var raw = try Data(contentsOf: f)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
        let name = String(f.lastPathComponent.dropLast(".book.json".count))
        let id = opaqueName(name)
        // renamed on the website after this copy was made: take the new title
        if let oe = oldEntries[id], let t = oe["title"] as? String, let up = oe["updated"] as? String,
           t != obj["title"] as? String, up > (obj["updated"] as? String ?? "") {
            obj["title"] = t; obj["updated"] = up
            raw = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
            try raw.write(to: f)
            print("  ✎ ชื่อใหม่จากเว็บ: \(t)")
        }
        try writeSealed(raw, to: out.appendingPathComponent(id + ".book.enc"), key); keep.insert(id + ".book.enc")
        var e: [String: Any] = ["id": id, "name": name, "title": obj["title"] as? String ?? name, "source": obj["source"] as? String ?? "",
                                "numPages": obj["numPages"] as? Int ?? 0, "updated": obj["updated"] as? String ?? ""]
        let cover = lib.appendingPathComponent(name + ".cover.jpg")
        if let c = try? Data(contentsOf: cover) {
            try writeSealed(c, to: out.appendingPathComponent(id + ".cover.enc"), key); keep.insert(id + ".cover.enc"); e["cover"] = true
        }
        entries.append(e)
    }
    let live = Set(entries.compactMap { $0["id"] as? String })
    let tomb = removed.filter { !live.contains($0.key) }.sorted { $0.key < $1.key }.map { ["id": $0.key, "at": $0.value] }
    let index = try JSONSerialization.data(withJSONObject: ["format": "reader-shelf/2", "books": entries, "removed": tomb],
                                           options: [.withoutEscapingSlashes, .sortedKeys])
    try writeSealed(index, to: out.appendingPathComponent("index.enc"), key)
    for f in (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(f.lastPathComponent) {
        try? fm.removeItem(at: f)   // books removed from the library, or old unencrypted files
    }
    print("ชั้นหนังสือบนเว็บมี \(entries.count) เล่ม (เข้ารหัสแล้ว)")
}

/// Books uploaded from the website are only in books/ (encrypted). Copy them into library/ so they
/// survive the seal, which rebuilds books/ from library/.
func adoptWebBooks(_ lib: URL, entries: [[String: Any]], from out: URL, key: SymmetricKey, skip: Set<String>) throws {
    let fm = FileManager.default
    let local = Set(((try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasSuffix(".book.json") }
        .map { opaqueName(String($0.lastPathComponent.dropLast(".book.json".count))) })
    for e in entries {
        guard let id = e["id"] as? String, !local.contains(id), !skip.contains(id),
              let name = (e["name"] as? String)?.replacingOccurrences(of: "/", with: "-"), opaqueName(name) == id,
              let bookData = try? Data(contentsOf: out.appendingPathComponent(id + ".book.enc")),
              let book = try? AES.GCM.open(AES.GCM.SealedBox(combined: bookData), using: key) else { continue }
        try book.write(to: lib.appendingPathComponent(name + ".book.json"))
        if let c = try? Data(contentsOf: out.appendingPathComponent(id + ".cover.enc")),
           let cover = try? AES.GCM.open(AES.GCM.SealedBox(combined: c), using: key) {
            try cover.write(to: lib.appendingPathComponent(name + ".cover.jpg"))
        }
        print("  ↓ รับเล่มที่เพิ่มจากเว็บ: \(e["title"] as? String ?? name)")
    }
}

// ---- main ----
let args = CommandLine.arguments.dropFirst()
if args.first == "--seal" {   // --seal <library> <books> <vault.json> [--drop <name>]
    let a = Array(args.dropFirst())
    guard a.count == 3 || (a.count == 5 && a[3] == "--drop") else { print("วิธีใช้: thai-ocr --seal <library> <books> <vault.json> [--drop <ชื่อ>]"); exit(1) }
    do { try sealLibrary(URL(fileURLWithPath: a[0]), into: URL(fileURLWithPath: a[1]), vaultURL: URL(fileURLWithPath: a[2]), drop: a.count == 5 ? a[4] : nil) }
    catch { print("✗ \(error.localizedDescription)"); exit(1) }
    exit(0)
}
if args.first == "--vault" || args.first == "--token" {  // --vault|--token <vault.json> <index.html>
    let a = Array(args.dropFirst())
    guard a.count == 2 else { print("วิธีใช้: thai-ocr \(args.first!) <vault.json> <index.html>"); exit(1) }
    do {
        if args.first == "--vault" { try makeVault(URL(fileURLWithPath: a[0]), page: URL(fileURLWithPath: a[1])) }
        else { try setToken(URL(fileURLWithPath: a[0]), page: URL(fileURLWithPath: a[1])) }
    } catch { print("✗ \(error.localizedDescription)"); exit(1) }
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
