import Foundation
import Vision

/// Reads the text in a screenshot with Apple's text recognition, the engine
/// behind Live Text. It runs on this Mac; nothing is sent anywhere.
enum TextRecognition {
    /// Calls back on the main thread with the text, top to bottom, or with
    /// nil when there is none.
    static func text(in url: URL, completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(url: url).perform([request])

            // Vision's coordinates start at the bottom left: higher lines first,
            // and left to right within a line.
            let lines = (request.results ?? [])
                .sorted { a, b in
                    abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                        ? a.boundingBox.midY > b.boundingBox.midY
                        : a.boundingBox.minX < b.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(text.isEmpty ? nil : text) }
            }
        }
    }
}
