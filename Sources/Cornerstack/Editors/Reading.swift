import CoreText
import Foundation
import Vision

/// What Cornerstack read in a screenshot: its text, with Apple's text
/// recognition (the engine behind Live Text), and what any QR code or barcode
/// in it says. It runs on this Mac; nothing is sent anywhere.
struct Reading {
    /// The lines, top to bottom and left to right within a line. Each one
    /// knows where its characters sit, which Hide Secrets needs.
    let lines: [VNRecognizedText]
    /// The same lines as text, with look-alike letters put right; see
    /// `Lookalikes`. Character for character the same length as `lines`.
    let strings: [String]
    /// What the QR codes and barcodes say, in the order Vision found them.
    let codes: [String]
    /// Every code with where it sits, in Vision's coordinates, so Hide
    /// Secrets can cover one that holds a secret.
    let codeAreas: [(says: String, box: CGRect)]
    /// The image could not be read at all, which is not the same as an image
    /// with nothing to read.
    let failed: Bool

    init(lines: [VNRecognizedText], codeAreas: [(says: String, box: CGRect)] = [], failed: Bool = false) {
        self.lines = lines
        self.strings = lines.map { Lookalikes.fix($0.string) }
        var codes: [String] = []
        for area in codeAreas where !codes.contains(area.says) { codes.append(area.says) }
        self.codes = codes
        self.codeAreas = codeAreas
        self.failed = failed
    }

    /// The text as it reads, with what a code says at the end, unless it is
    /// already in the text.
    var text: String? {
        var parts = strings
        let read = parts.joined(separator: "\n")
        for code in codes where !read.contains(code) { parts.append(code) }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The code a card offers: the first web link, or else the first code.
    var code: String? {
        codes.first(where: { Reading.webLink($0) != nil }) ?? codes.first
    }

    /// A code that is a web address. Only http and https open in the
    /// browser; anything else a code says is copied instead.
    static func webLink(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Vision sometimes reads Latin text, monospaced code especially, as Cyrillic
/// or Greek letters that look the same: "ОРENАI_АРI_KЕY" with a Cyrillic О, Р
/// and А. Copied, that is no longer the key, and Hide Secrets would not
/// recognise it. This puts the Latin letters back in a word that
/// - mixes Latin letters with Cyrillic or Greek ones, which no real word does,
/// - and has only Cyrillic or Greek letters that look exactly like Latin ones,
///   so it comes out all Latin. A real Russian or Greek word nearly always has
///   a letter with no Latin twin (п, и, т, λ), so it stays as it is.
/// For someone who reads Cyrillic or Greek the scripts must also be mixed
/// within one run of letters and digits, like "АРI" or "prоj". Their texts
/// put a word in each script side by side, "НАТО/NATO" or a link that ends in
/// "/wiki/Тор", and those stay as they are.
/// Each character becomes exactly one character, so positions stay the same.
enum Lookalikes {
    private static let latin: [Character: Character] = [
        // Cyrillic
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C",
        "Т": "T", "Х": "X", "У": "Y", "І": "I", "Ј": "J", "Ѕ": "S", "З": "3",
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
        // Greek capitals; the small letters are left alone, they are often maths (α, ν).
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N",
        "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    ]
    /// In a word with digits, a slashed zero and long dashes are code, not text.
    private static let inCode: [Character: Character] = ["Ø": "0", "—": "-", "–": "-"]
    /// What Vision makes of 0, x and i in the middle of a key now and then,
    /// also in a word with no Cyrillic or Greek in it. See `fixKey`.
    private static let inKey: [Character: Character] = ["Ø": "0", "×": "x", "ı": "i"]
    private static let codeMarks: Set<Character> = ["_", "=", "/", ":", "@"]
    /// A word this long with letters and digits is a key even without a code mark.
    private static let keyLength = 16

    /// Whether the user reads Cyrillic or Greek, going by the Mac's languages.
    static let readsCyrillicOrGreek: Bool = Locale.preferredLanguages.contains { identifier in
        let script = Locale.Language(identifier: identifier).maximalIdentifier
        return script.contains("Cyrl") || script.contains("Grek")
    }

    private static func isCyrillicOrGreek(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x0400...0x04FF).contains($0.value) }
    }

    private static func isLatinLetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    private static func isLatinLetterOrDigit(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// The runs of letters and digits in a word: "АРI_KEY=abc" has three.
    private static func runs(in word: [Character]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, c) in word.enumerated() {
            if c.isLetter || c.isNumber || inKey[c] != nil {
                if start == nil { start = i }
            } else if let from = start {
                runs.append(from..<i)
                start = nil
            }
        }
        if let from = start { runs.append(from..<word.count) }
        return runs
    }

    static func fix(_ line: String) -> String {
        fix(line, readsCyrillicOrGreek: readsCyrillicOrGreek)
    }

    static func fix(_ line: String, readsCyrillicOrGreek: Bool) -> String {
        guard line.contains(where: { isCyrillicOrGreek($0) || inKey[$0] != nil }) else { return line }
        var result = ""
        var word: [Character] = []
        func flush() {
            defer { word = [] }
            let runs = Lookalikes.runs(in: word)
            let foreign = word.filter(isCyrillicOrGreek)
            let hasDigit = word.contains { $0.isASCII && $0.isNumber }
            if !foreign.isEmpty, word.contains(where: isLatinLetter),
               foreign.allSatisfy({ latin[$0] != nil }),
               !readsCyrillicOrGreek || runs.contains(where: { run in
                   word[run].contains(where: isLatinLetter) && word[run].contains(where: isCyrillicOrGreek)
               }) {
                word = word.map { latin[$0] ?? (hasDigit ? inCode[$0] : nil) ?? $0 }
            }
            fixKey(&word, runs: runs)
            result.append(contentsOf: word)
        }
        for c in line {
            if c.isWhitespace {
                flush()
                result.append(c)
            } else {
                word.append(c)
            }
        }
        flush()
        return result
    }

    /// Ø, × and ı become 0, x and i inside a key: a word that looks like
    /// code (a code mark, or long), in a run with Latin letters and digits,
    /// with one of them on each side. Each has its own tell besides, so that
    /// real text stays as it is:
    /// - Ø only in a run with a small letter, as keys have. Danish writes a
    ///   capital Ø inside a word only in capitals: "SØREN1", "DNØ25".
    /// - × only next to a letter: "1920×1080" is a size.
    /// - ı only next to a digit: Turkish has it between letters, "Adım1".
    /// Long dashes are not touched here: "2020–2024" is in too many links.
    private static func fixKey(_ word: inout [Character], runs: [Range<Int>]) {
        guard word.contains(where: { inKey[$0] != nil }),
              word.contains(where: codeMarks.contains) || word.count >= keyLength else { return }
        for run in runs where run.count >= 3 {
            guard word[run].contains(where: { $0.isASCII && $0.isNumber }),
                  word[run].contains(where: isLatinLetter) else { continue }
            let hasSmallLetter = word[run].contains { $0.isASCII && $0.isLowercase }
            for i in run.dropFirst().dropLast() {
                let before = word[i - 1], after = word[i + 1]
                guard let twin = inKey[word[i]],
                      isLatinLetterOrDigit(before), isLatinLetterOrDigit(after) else { continue }
                switch word[i] {
                case "Ø": guard hasSmallLetter else { continue }
                case "×": guard isLatinLetter(before) || isLatinLetter(after) else { continue }
                default: guard before.isNumber || after.isNumber else { continue }
                }
                word[i] = twin
            }
        }
    }
}

/// Reads each capture once, in the background, as soon as it lands on the
/// stack, so Copy Text, Hide Secrets and a card's code button have the
/// answer at hand when you ask. Reading a full Retina screen takes a few
/// tenths of a second.
@MainActor
final class Reader {
    static let shared = Reader()

    /// A file as it was when it was read: a file changed since, in Preview
    /// for example, is read again.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private var done: [URL: (stamp: Stamp, reading: Reading)] = [:]
    /// Newest last, so the oldest reading is the first to go.
    private var order: [URL] = []
    private var waiting: [URL: [@MainActor (Reading) -> Void]] = [:]
    /// The files still to read, the next one first. What you ask for goes
    /// to the front; a capture that just landed waits its turn at the back.
    private var pending: [URL] = []
    /// The files you asked for, which stay in line when their card leaves.
    private var asked = Set<URL>()
    private var busy = false
    /// Bumped when a file changes, so a reading of the old version that is
    /// still on its way is thrown away.
    private var versions: [URL: Int] = [:]
    /// One capture at a time, at a low priority, so reading never gets in
    /// the way of the app you are using.
    private let queue = DispatchQueue(label: "io.github.nemcaya.cornerstack.read", qos: .utility)
    /// Enough for every card on a full stack and the ones you might put back.
    private static let kept = 12

    /// Calls back on the main thread, at once when the file was read before.
    /// `asked` is false for a capture that is read because it just landed:
    /// Copy Text and Hide Secrets, which you wait for, go ahead of those.
    func read(_ url: URL, asked: Bool = true, then completion: @escaping @MainActor (Reading) -> Void) {
        if let entry = done[url] {
            if entry.stamp == Stamp(url) {
                completion(entry.reading)
                return
            }
            forget(url)
        }
        if asked { self.asked.insert(url) }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            if asked, let i = pending.firstIndex(of: url) {
                pending.remove(at: i)
                pending.insert(url, at: 0)
            }
            return
        }
        waiting[url] = [completion]
        if asked { pending.insert(url, at: 0) } else { pending.append(url) }
        next()
    }

    /// The file changed, after Markup for example: read it again next time.
    func forget(_ url: URL) {
        done[url] = nil
        order.removeAll { $0 == url }
        versions[url, default: 0] += 1
        pending.removeAll { $0 == url }
        // Whoever is waiting gets the new version instead.
        let ahead = asked.remove(url) != nil
        if let callbacks = waiting.removeValue(forKey: url) {
            for callback in callbacks { read(url, asked: ahead, then: callback) }
        }
    }

    /// The card left the stack before its turn came: nobody needs the
    /// reading, unless you asked for it. In a burst of captures this keeps
    /// the ones already pushed out from holding up the rest.
    func skip(_ url: URL) {
        guard !asked.contains(url), let i = pending.firstIndex(of: url) else { return }
        pending.remove(at: i)
        waiting[url] = nil
    }

    /// Reads a few letters once at launch. The first reading in a run of the
    /// app takes about twice as long as the ones after it, and this way that
    /// is not the first capture you ask about.
    func warmUp() {
        queue.async { Reader.readSample() }
    }

    private func next() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let url = pending.removeFirst()
        let stamp = Stamp(url)
        let version = versions[url, default: 0]
        queue.async {
            let reading = Reader.perform(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.finish(url, version: version, stamp: stamp, reading)
                    self.next()
                }
            }
        }
    }

    private func finish(_ url: URL, version: Int, stamp: Stamp, _ reading: Reading) {
        guard versions[url, default: 0] == version else { return }
        asked.remove(url)
        // A reading that failed is not kept, so the next try reads again.
        if !reading.failed {
            done[url] = (stamp, reading)
            order.removeAll { $0 == url }
            order.append(url)
            while order.count > Reader.kept { done[order.removeFirst()] = nil }
        }
        for callback in waiting.removeValue(forKey: url) ?? [] { callback(reading) }
    }

    private nonisolated static func perform(_ url: URL) -> Reading {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        // Spelling correction turns code, links and keys into words. Without
        // it the text comes out as it is on screen, and a little faster.
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        do {
            try VNImageRequestHandler(url: url).perform([text, codes])
        } catch {
            return Reading(lines: [], failed: true)
        }

        // Vision's coordinates start at the bottom left: higher lines first,
        // and left to right within a line.
        let lines = (text.results ?? [])
            .sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first }
        var areas: [(says: String, box: CGRect)] = []
        for code in codes.results ?? [] {
            guard let payload = code.payloadStringValue, !payload.isEmpty else { continue }
            areas.append((payload, code.boundingBox))
        }
        return Reading(lines: lines, codeAreas: areas)
    }

    /// A small image with a few letters, read and thrown away; see `warmUp`.
    private nonisolated static func readSample() {
        guard let context = CGContext(data: nil, width: 240, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 64))
        context.setFillColor(gray: 0, alpha: 1)
        let font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
        let sample = NSAttributedString(string: "abc 123", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 16, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(sample), context)
        guard let image = context.makeImage() else { return }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([text, VNDetectBarcodesRequest()])
    }
}
