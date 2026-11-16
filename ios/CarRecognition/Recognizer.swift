import Observation
import UIKit

/// What the screen shows: the photo sent, the answer, and a status line.
@MainActor @Observable
final class Recognizer {
    var photo: UIImage?
    var answer: Answer?
    var rawAnswer = ""
    var status = "Take or choose a photo of a car."
    var isError = false
    var busy = false

    /// A photo from the library or the example.
    func recognize(data: Data) async {
        await run { PhotoShrinker.jpeg(from: data) }
    }

    /// A photo from the camera.
    func recognize(image: UIImage) async {
        await run { PhotoShrinker.jpeg(from: image) }
    }

    func recognizeExample() async {
        guard let url = Bundle.main.url(forResource: "example", withExtension: "jpg"), let data = try? Data(contentsOf: url) else { return }
        await recognize(data: data)
    }

    private func run(_ prepare: @escaping @Sendable () -> (UIImage, Data)?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        answer = nil
        rawAnswer = ""
        isError = false
        status = "Recognizing…"
        // Shrinking a large photo takes a moment: do it off the main thread.
        guard let prepared = await Task.detached(operation: prepare).value else {
            show(RecognitionError.photoNotOpened)
            return
        }
        let (photo, jpeg) = prepared
        self.photo = photo
        do throws(RecognitionError) {
            let (answer, raw) = try await Settings.client.recognize(jpeg)
            self.answer = answer
            rawAnswer = raw
            let time = answer.meta?.time.map { String(format: " The API took %.2f s.", $0) } ?? ""
            switch answer.cars.count {
            case 0: status = "No car recognized in this photo.\(time)"
            case 1: status = "Found 1 car.\(time)"
            case let n: status = "Found \(n) cars.\(time)"
            }
        } catch {
            show(error)
        }
    }

    private func show(_ error: RecognitionError) {
        status = error.errorDescription ?? "Something went wrong."
        isError = true
    }
}
