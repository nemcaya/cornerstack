import Foundation
import Vision

/// What Cornerstack read in a screenshot: its text, with Apple's text
/// recognition (the engine behind Live Text), and what any QR code or barcode
/// in it says. It runs on this Mac; nothing is sent anywhere.
struct Reading {
    /// The lines, top to bottom and left to right within a line. Each one
    /// knows where its characters sit, which Hide Secrets needs.
    let lines: [VNRecognizedText]
    /// What the QR codes and barcodes say, in the order Vision found them.
    let codes: [String]

    /// The text as it reads, with what a code says at the end, unless it is
    /// already in the text.
    var text: String? {
        var parts = lines.map(\.string)
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
    /// Bumped when a file changes, so a reading of the old version that is
    /// still on its way is thrown away.
    private var versions: [URL: Int] = [:]
    /// One capture at a time, at a low priority, so reading never gets in
    /// the way of the app you are using.
    private let queue = DispatchQueue(label: "io.github.nemcaya.cornerstack.read", qos: .utility)
    /// Enough for every card on a full stack and the ones you might put back.
    private static let kept = 12

    /// Calls back on the main thread, at once when the file was read before.
    func read(_ url: URL, then completion: @escaping @MainActor (Reading) -> Void) {
        let stamp = Stamp(url)
        if let entry = done[url] {
            if entry.stamp == stamp {
                completion(entry.reading)
                return
            }
            forget(url)
        }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]
        let version = versions[url, default: 0]
        queue.async {
            let reading = Reader.perform(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(url, version: version, stamp: stamp, reading) }
            }
        }
    }

    /// The file changed, after Markup for example: read it again next time.
    func forget(_ url: URL) {
        done[url] = nil
        order.removeAll { $0 == url }
        versions[url, default: 0] += 1
        // Whoever is waiting gets the new version instead.
        if let callbacks = waiting.removeValue(forKey: url) {
            for callback in callbacks { read(url, then: callback) }
        }
    }

    private func finish(_ url: URL, version: Int, stamp: Stamp, _ reading: Reading) {
        guard versions[url, default: 0] == version else { return }
        done[url] = (stamp, reading)
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Reader.kept { done[order.removeFirst()] = nil }
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
        try? VNImageRequestHandler(url: url).perform([text, codes])

        // Vision's coordinates start at the bottom left: higher lines first,
        // and left to right within a line.
        let lines = (text.results ?? [])
            .sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first }
        var payloads: [String] = []
        for code in codes.results ?? [] {
            guard let payload = code.payloadStringValue, !payload.isEmpty, !payloads.contains(payload) else { continue }
            payloads.append(payload)
        }
        return Reading(lines: lines, codes: payloads)
    }
}
