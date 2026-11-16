import ImageIO
import UIKit

/// Makes the JPEG that is sent: at most 2,048 pixels on the long side, upright.
///
/// That's about a quarter of a phone photo's upload. In our check with 15 phone photos, the answers the API was sure
/// about stayed the same as for the full photo; cars far away may be skipped, because the API leaves out cars less
/// than 180 pixels wide in the photo it receives. Raise `longSide` to send larger photos (the API takes up to 12 MB).
enum PhotoShrinker {
    static let longSide = 2048
    static let quality = 0.85

    /// From a file's bytes (the photo library or the example). ImageIO reads only what it needs and applies the
    /// camera's rotation flag, so even a 48-megapixel photo never sits in memory at full size.
    static func jpeg(from data: Data) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // upright
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let photo = UIImage(cgImage: image)
        guard let jpeg = photo.jpegData(compressionQuality: quality) else { return nil }
        return (photo, jpeg)
    }

    /// From the camera. Drawing the image applies its orientation, so the JPEG is upright.
    static func jpeg(from image: UIImage) -> (UIImage, Data)? {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        let factor = min(1, Double(longSide) / max(width, height))
        let size = CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = photo.jpegData(compressionQuality: quality) else { return nil }
        return (photo, jpeg)
    }
}
