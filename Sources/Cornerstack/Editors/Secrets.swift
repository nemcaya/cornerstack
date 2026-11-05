import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Hide Secrets: finds keys, tokens, passwords, email addresses, card numbers
/// and IBANs in what `Reader` read, and paints over them in a copy of the
/// screenshot. The original stays as it is.
///
/// It goes by what the text looks like, so it is a safety net, not a
/// guarantee: text it could not read, or a secret in an unknown format,
/// stays visible. Look at the copy before you share it.
enum Secrets {
    private struct Rule {
        let pattern: NSRegularExpression
        /// The capture group to cover, or 0 for the whole match. A password
        /// covers only the value after "password:", not the word.
        let group: Int
        /// A last check on what matched, to rule out look-alikes.
        let check: ((String) -> Bool)?

        init(_ pattern: String, group: Int = 0, check: ((String) -> Bool)? = nil) {
            // The patterns are fixed, so a broken one is a bug found at once.
            self.pattern = try! NSRegularExpression(pattern: pattern)
            self.group = group
            self.check = check
        }
    }

    private static let rules: [Rule] = [
        // Private key blocks: the header line. The key itself is caught as a
        // long token below.
        Rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        // API keys with a known shape: OpenAI and Anthropic (sk-…), GitHub,
        // AWS, Google, Slack and Stripe.
        Rule(#"\bsk-[A-Za-z0-9_\-]{16,}"#),
        Rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        Rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(#"\bAIza[0-9A-Za-z_\-]{30,}"#),
        Rule(#"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
        Rule(#"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{16,}"#),
        // JSON web tokens: three base64 parts, the first two starting {"…
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        // "Bearer …" in a header.
        Rule(#"(?i)\bbearer\s+([A-Za-z0-9_\-.=+/]{16,})"#, group: 1),
        // A value after a word that says it is secret: password: hunter2,
        // DB_PASSWORD=…, "token": "…", and the German Passwort and Kennwort.
        Rule(#"(?i)(?:\b|_)(?:pass(?:word|wd)?|passwort|kennwort|pwd|passcode|pin|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|auth)\b["']?\s*[:=]\s*["']?([^\s"',;]{4,})"#, group: 1),
        // A card's security code: CVC 123, CVV: 1234.
        Rule(#"(?i)\b(?:cvc|cvv|csc|cvc2|cvv2)\b\s*[:=]?\s*(\d{3,4})\b"#, group: 1),
        // The password in a link like https://user:password@host
        Rule(#"\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s/:@]+:([^\s/@]+)@"#, group: 1),
        // Email addresses.
        Rule(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        // IBANs, checked with their own check digits.
        Rule(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b"#, check: isIBAN),
        // Card numbers, checked with the Luhn formula that every card number passes.
        Rule(#"\b(?:\d[ \-]?){12,18}\d\b"#, check: passesLuhn),
        // Any other long token that mixes letters and digits, like a key in a
        // format not listed above, or the lines of a private key.
        Rule(#"[A-Za-z0-9_\-+/=]{32,}"#, check: looksRandom),
    ]

    /// Where the secrets are, in Vision's coordinates: from 0 to 1, with the
    /// origin at the bottom left of the image.
    static func find(in reading: Reading) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in reading.lines {
            let text = line.string
            let all = NSRange(text.startIndex..., in: text)
            var covered: [Range<String.Index>] = []
            for rule in rules {
                for match in rule.pattern.matches(in: text, range: all) {
                    let found = match.range(at: rule.group)
                    guard found.location != NSNotFound, var range = Range(found, in: text) else { continue }
                    if let check = rule.check {
                        guard let passing = longestPassing(check, in: text, range: range) else { continue }
                        range = passing
                    }
                    // Already covered by an earlier rule.
                    if covered.contains(where: { $0.overlaps(range) }) { continue }
                    covered.append(range)
                    if let box = try? line.boundingBox(for: range)?.boundingBox { boxes.append(box) }
                }
            }
        }
        return boxes
    }

    /// Writes a copy of the image with the boxes painted over to `target`, a
    /// PNG. It keeps the original's pixel density, so the copy pastes at the
    /// same size. False when the image can't be read or written.
    static func paint(_ boxes: [CGRect], over url: URL, to target: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Solid bars, not a blur: a blur can sometimes be undone.
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        for box in boxes {
            let rect = CGRect(x: box.minX * width, y: box.minY * height,
                              width: box.width * width, height: box.height * height)
            // Vision's boxes for part of a line are estimates: cover a little more.
            let pad = max(2, rect.height * 0.25)
            let bar = rect.insetBy(dx: -pad, dy: -pad * 0.6)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: pad * 0.8, cornerHeight: pad * 0.8, transform: nil))
            context.fillPath()
        }
        guard let painted = context.makeImage() else { return false }

        // Written under a hidden name, then renamed, so nothing watching the
        // folder sees a half-written file.
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var properties: [CFString: Any] = [:]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = original[key] { properties[key] = value }
        }
        CGImageDestinationAddImage(destination, painted, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        do {
            try FileManager.default.moveItem(at: partial, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
    }

    // MARK: Checks

    /// The longest part of a match, from gap to gap, that passes its check.
    /// The patterns are greedy, so they can take in what follows a number,
    /// like the BIC after an IBAN or the expiry date after a card number,
    /// and then the whole match would fail its check.
    private static func longestPassing(_ check: (String) -> Bool, in text: String,
                                       range: Range<String.Index>) -> Range<String.Index>? {
        if check(String(text[range])) { return range }
        var starts = [range.lowerBound], ends = [range.upperBound]
        var i = range.lowerBound
        while i < range.upperBound {
            let next = text.index(after: i)
            if text[i] == " " || text[i] == "-" {
                ends.append(i)
                if next < range.upperBound { starts.append(next) }
            }
            i = next
        }
        var best: Range<String.Index>?
        var bestLength = 0
        for start in starts {
            for end in ends where end > start {
                let length = text.distance(from: start, to: end)
                guard length > bestLength, check(String(text[start..<end])) else { continue }
                best = start..<end
                bestLength = length
            }
        }
        return best
    }

    private static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static func isIBAN(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count) else { return false }
        // Move the country and check digits to the end, letters become
        // numbers (A = 10), and the whole number leaves 1 when divided by 97.
        let moved = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in moved {
            guard let value = character.wholeNumberValue
                    ?? character.asciiValue.flatMap({ $0 >= 65 && $0 <= 90 ? Int($0) - 55 : nil }) else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    /// Letters and digits mixed, like a key, and not a word, a path or a
    /// run of one character.
    private static func looksRandom(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        guard letters >= 4, digits >= 4 else { return false }
        return Set(text).count >= 12
    }
}
