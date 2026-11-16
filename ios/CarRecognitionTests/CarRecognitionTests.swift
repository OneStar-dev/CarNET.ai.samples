import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CarRecognition

/// The client against a stand-in for the API (no real requests), and the photo shrinker.
final class CarnetClientTests: XCTestCase {
    private let car = #"""
    {"is_success": true, "meta": {"time": 0.07}, "detections": [{"box": {"tl_x": 0.1, "tl_y": 0.2, "br_x": 0.9, "br_y": 0.8},
     "mmg": [{"make_name": "Porsche", "model_name": "Taycan", "generation_name": "I facelift", "years": "2024-", "probability": 0.997},
             {"make_name": "Porsche", "model_name": "Taycan", "generation_name": "I", "years": "2019-2024", "probability": 0.002}],
     "color": [{"name": "Black", "probability": 0.99}], "angle": [{"name": "front-right", "probability": 1.0}]}]}
    """#

    override func setUp() {
        Stub.answers = []
        Stub.requests = []
    }

    private func client(key: String = "test-key", address: String = CarnetClient.cloudAddress) -> CarnetClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return CarnetClient(address: address, key: key, session: URLSession(configuration: configuration))
    }

    private func recognize(_ client: CarnetClient) async -> Result<Answer, RecognitionError> {
        do throws(RecognitionError) {
            return .success(try await client.recognize(Data("PHOTO".utf8)).0)
        } catch {
            return .failure(error)
        }
    }

    /// The error a request ends with, or nil when it succeeds.
    private func failure(_ client: CarnetClient) async -> RecognitionError? {
        if case .failure(let error) = await recognize(client) { return error }
        return nil
    }

    func testSendsTheKeyAndParametersAndReadsTheCars() async throws {
        Stub.answers = [(200, [:], car)]
        let answer = try await recognize(client()).get()
        XCTAssertEqual(answer.cars.count, 1)
        XCTAssertEqual(answer.cars[0].guesses[0].name, "Porsche Taycan I facelift")
        XCTAssertEqual(answer.cars[0].box?.brX, 0.9)
        XCTAssertEqual(Stub.requests.first?.value(forHTTPHeaderField: "api-key"), "test-key")
        XCTAssertEqual(Stub.requests.first?.url?.query, "features=mmg,color,angle&box_select=all")
    }

    func testNoKeyForTheCloudAPI() async {
        let error1 = await failure(client(key: ""))
        XCTAssertEqual(error1, .noKey)
        XCTAssertTrue(Stub.requests.isEmpty)
    }

    func testCarnetServerNeedsNoKey() async throws {
        Stub.answers = [(200, [:], car)]
        _ = try await recognize(client(key: "", address: "http://192.168.1.20:50052/detect")).get()
        XCTAssertNil(Stub.requests.first?.value(forHTTPHeaderField: "api-key"))
    }

    func testTooFastWaitsAndTriesOnceMore() async throws {
        let reset = String(Int(Date().timeIntervalSince1970 * 1000) + 200)
        Stub.answers = [(429, ["X-Rate-Limit-Reset": reset], #"{"message":"Rate limit exceeded ! You reach the limit of 1 requests per 1 seconds"}"#),
                        (200, [:], car)]
        _ = try await recognize(client()).get()
        XCTAssertEqual(Stub.requests.count, 2)
    }

    func testLimitUsedUpSaysWhenItRenews() async {
        Stub.answers = [(429, ["X-Quota-Reset": "1794915965161"], #"{"message":"Quota exceeded ! You reach the limit of 100 requests per 1 days"}"#)]
        let error2 = await failure(client())
        XCTAssertEqual(error2, .limitUsedUp(renews: Date(timeIntervalSince1970: 1794915965.161)))
        XCTAssertEqual(Stub.requests.count, 1)
    }

    func testPlainErrors() async {
        Stub.answers = [(403, [:], #"{"message":"API Key is not valid or is expired / revoked."}"#)]
        let error3 = await failure(client())
        XCTAssertEqual(error3, .keyRefused)
        Stub.answers = [(500, [:], "oops")]
        let error4 = await failure(client())
        XCTAssertEqual(error4, .serviceProblem(500))
        Stub.answers = [(200, [:], "<html>")]
        let error5 = await failure(client())
        XCTAssertEqual(error5, .unreadableAnswer)
        Stub.answers = [(200, [:], #"{"is_success": false, "error": {"code": 8, "message": "Error decoding image"}, "detections": []}"#)]
        let error6 = await failure(client())
        XCTAssertEqual(error6, .photoNotRead("Error decoding image"))
    }

    func testYourOwnServersErrorIsShownAsItIs() async {
        Stub.answers = [(503, [:], #"{"error":"This site is busy. Try again in a moment."}"#)]
        let error7 = await failure(client(key: "", address: "https://example.com/api/recognize"))
        XCTAssertEqual(error7, .server("This site is busy. Try again in a moment."))
    }

    func testYourOwnServersLimitIsNotRetried() async {
        Stub.answers = [(429, [:], #"{"error":"This site's limit of photos is used up for now. Try again later."}"#)]
        let error = await failure(client(key: "", address: "https://example.com/api/recognize"))
        XCTAssertEqual(error, .server("This site's limit of photos is used up for now. Try again later."))
        XCTAssertEqual(Stub.requests.count, 1)
    }

    func testRefusesAPhotoOver12MB() async {
        do throws(RecognitionError) {
            _ = try await client().recognize(Data(count: CarnetClient.maxBytes + 1))
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    /// All eight camera rotation flags. The photo is 40 x 20 with its top-left corner red; once upright, the red
    /// corner must be where the flag says it belongs.
    func testEveryRotationFlagComesOutUpright() throws {
        let expected: [Int: (size: CGSize, red: CGPoint)] = [
            1: (CGSize(width: 40, height: 20), CGPoint(x: 2, y: 2)), 2: (CGSize(width: 40, height: 20), CGPoint(x: 37, y: 2)),
            3: (CGSize(width: 40, height: 20), CGPoint(x: 37, y: 17)), 4: (CGSize(width: 40, height: 20), CGPoint(x: 2, y: 17)),
            5: (CGSize(width: 20, height: 40), CGPoint(x: 2, y: 2)), 6: (CGSize(width: 20, height: 40), CGPoint(x: 17, y: 2)),
            7: (CGSize(width: 20, height: 40), CGPoint(x: 17, y: 37)), 8: (CGSize(width: 20, height: 40), CGPoint(x: 2, y: 37)),
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stored = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for (flag, want) in expected.sorted(by: { $0.key < $1.key }) {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(stored.cgImage), [kCGImagePropertyOrientation: flag] as CFDictionary)
            CGImageDestinationFinalize(destination)
            let (photo, _) = try XCTUnwrap(PhotoShrinker.jpeg(from: data as Data))
            XCTAssertEqual(photo.size, want.size, "flag \(flag)")
            XCTAssertTrue(isRed(photo, at: want.red), "flag \(flag): the red corner isn't at \(want.red)")
        }
    }

    private func isRed(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: -point.x, y: -(CGFloat(cgImage.height) - 1 - point.y),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return pixel[0] > 200 && pixel[1] < 80 && pixel[2] < 80
    }

    func testShrinksALargePhotoAndTurnsItUpright() throws {
        // 4000 x 3000 pixels, with the camera's flag "turn 90° clockwise to view" (orientation 6).
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).image { context in UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000)) }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)

        let (photo, jpeg) = try XCTUnwrap(PhotoShrinker.jpeg(from: data as Data))
        XCTAssertEqual(photo.size, CGSize(width: 1536, height: 2048)) // upright: portrait
        XCTAssertLessThan(jpeg.count, CarnetClient.maxBytes)
    }

    func testThePhotoSentCarriesNoLocation() throws {
        // A photo with GPS and camera details, as the photo library may hand it over.
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let details: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 59.437, kCGImagePropertyGPSLongitude: 24.7536],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 13 Pro"],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), details as CFDictionary)
        CGImageDestinationFinalize(destination)

        let (_, jpeg) = try XCTUnwrap(PhotoShrinker.jpeg(from: data as Data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let sent = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(sent[kCGImagePropertyGPSDictionary])
        XCTAssertNil((sent[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
    }

    func testKeepsTheSizeOfASmallPhoto() throws {
        let example = try XCTUnwrap(Bundle.main.url(forResource: "example", withExtension: "jpg"))
        let (photo, _) = try XCTUnwrap(PhotoShrinker.jpeg(from: Data(contentsOf: example)))
        XCTAssertEqual(photo.size, CGSize(width: 1024, height: 768))
    }
}

/// A stand-in for the API: answers from `answers` (or "no car") and records each request.
final class Stub: URLProtocol {
    nonisolated(unsafe) static var answers: [(Int, [String: String], String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, body) = Self.answers.isEmpty ? (200, [:], #"{"is_success":true,"detections":[]}"#) : Self.answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
