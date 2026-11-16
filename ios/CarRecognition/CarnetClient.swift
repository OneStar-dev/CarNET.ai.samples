import Foundation

/// Sends one photo to the CarNET API and reads the answer.
///
/// The address can be the Cloud API (needs your key), CarNET Server (no key), or your own server that adds the key,
/// such as the micro website's `/api/recognize` in this repo. An app you publish should use your own server: a key
/// inside an app can be taken out of it.
struct CarnetClient: Sendable {
    static let cloudAddress = "https://api.carnet.ai/v2/mmg/detect"
    /// What we ask for: make, model and generation, body color and angle, for every car in the photo.
    static let query = "features=mmg,color,angle&box_select=all"
    static let maxBytes = 12 * 1024 * 1024 // the Cloud API takes photos up to 12 MB

    var address: String
    var key: String
    var session: URLSession = .shared

    /// The answer, and the API's JSON as it came (pretty-printed) for showing.
    func recognize(_ photo: Data) async throws(RecognitionError) -> (Answer, String) {
        guard photo.count <= Self.maxBytes else { throw .tooLarge }
        if key.isEmpty && address.hasPrefix("https://api.carnet.ai/") { throw .noKey }
        let separator = address.contains("?") ? "&" : "?"
        guard let url = URL(string: address + separator + Self.query), url.scheme?.hasPrefix("http") == true else {
            throw .badAddress
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "api-key") }

        var (data, response) = try await send(request, photo)
        // Too fast for the key's per-second limit: wait for the next second and try once more. (Your own server's
        // refusals come as {"error": …}: it has already tried again itself.)
        if response.statusCode == 429 && !Self.isLimitUsedUp(data) && Self.ownServerError(data) == nil {
            try? await Task.sleep(for: .milliseconds(Self.waitForRate(response)))
            (data, response) = try await send(request, photo)
        }
        return try Self.read(data, response)
    }

    private func send(_ request: URLRequest, _ photo: Data) async throws(RecognitionError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(for: request, from: photo, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw RecognitionError.notAnswered }
            return (data, http)
        } catch {
            throw .notAnswered
        }
    }

    /// Turns an HTTP answer into the API's answer or a plain error.
    static func read(_ data: Data, _ response: HTTPURLResponse) throws(RecognitionError) -> (Answer, String) {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if response.statusCode != 200, let message = ownServerError(data) { throw .server(message) }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw .keyRefused
        case 413: throw .tooLarge
        case 429:
            if isLimitUsedUp(data) { throw .limitUsedUp(renews: resetTime(response, "X-Quota-Reset")) }
            throw .tooFast
        default: throw .serviceProblem(response.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let answer = try? decoder.decode(Answer.self, from: data) else { throw .unreadableAnswer }
        if !answer.isSuccess { throw .photoNotRead(answer.error?.message ?? "The API could not read the photo.") }
        let pretty = (try? JSONSerialization.data(withJSONObject: json ?? [:], options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (answer, pretty)
    }

    /// Your own server (like the micro website) answers its errors as {"error": "…"}.
    static func ownServerError(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    static func isLimitUsedUp(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).contains("Quota exceeded")
    }

    /// X-Rate-Limit-Reset (Unix time in milliseconds), kept between 0.1 and 1.1 s so a clock that is off can't
    /// make the app wait long.
    static func waitForRate(_ response: HTTPURLResponse) -> Int {
        guard let reset = resetTime(response, "X-Rate-Limit-Reset") else { return 1000 }
        return min(max(Int(reset.timeIntervalSinceNow * 1000), 100), 1100)
    }

    static func resetTime(_ response: HTTPURLResponse, _ header: String) -> Date? {
        guard let value = response.value(forHTTPHeaderField: header), let ms = Double(value), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// Refuses redirects, so the key (and the photo) never go on to an address you didn't set. The API doesn't redirect.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// The API's answer to one photo (the fields this app shows). Field names come in snake_case: `tl_x` is `tlX`.
struct Answer: Decodable, Sendable {
    let isSuccess: Bool
    let error: Problem?
    let detections: [Detection]?
    let meta: Meta?

    struct Problem: Decodable, Sendable { let code: Int?; let message: String? }
    struct Meta: Decodable, Sendable { let time: Double? }

    /// The cars: detections that come with a make and model.
    var cars: [Detection] { (detections ?? []).filter { !$0.guesses.isEmpty } }
}

struct Detection: Decodable, Sendable {
    let box: Box?
    let mmg: [Guess]?
    let mm: [Guess]? // instead of mmg when only make and model were asked for
    let color: [Named]?
    let angle: [Named]?

    /// The top guesses, most likely first.
    var guesses: [Guess] { mmg ?? mm ?? [] }
}

/// Where the car is, as fractions of the photo's width and height.
struct Box: Decodable, Sendable { let tlX, tlY, brX, brY: Double }

struct Guess: Decodable, Sendable {
    let makeName: String
    let modelName: String
    let generationName: String?
    let years: String?
    let probability: Double

    var name: String { [makeName, modelName, generationName ?? ""].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct Named: Decodable, Sendable { let name: String; let probability: Double }

enum RecognitionError: LocalizedError, Equatable {
    case noKey, badAddress, notAnswered, keyRefused, tooFast, tooLarge, unreadableAnswer
    case limitUsedUp(renews: Date?)
    case serviceProblem(Int)
    case photoNotRead(String)
    case server(String)
    case photoNotOpened

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your API key in Settings."
        case .badAddress: "The API address in Settings isn't a web address."
        case .notAnswered: "Could not reach the recognition service. Check your connection and try again."
        case .keyRefused: "The API key was refused. Check it in Settings."
        case .tooFast: "Too many photos at once. Try again in a second."
        case .tooLarge: "The photo is larger than 12 MB."
        case .unreadableAnswer: "The recognition service gave an answer this app could not read."
        case .limitUsedUp(let renews):
            if let renews { "The key's limit is used up. It renews at \(renews.formatted(date: .abbreviated, time: .shortened))." }
            else { "The key's limit is used up for now." }
        case .serviceProblem(let status): "The recognition service had a problem (HTTP \(status)). Try again in a moment."
        case .photoNotRead(let message): message
        case .server(let message): message
        case .photoNotOpened: "Could not open this photo."
        }
    }
}
