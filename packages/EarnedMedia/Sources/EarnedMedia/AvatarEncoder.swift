import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever the photo picker hands over into the one thing Earned will
/// upload: a small, square-ish JPEG that carries no metadata at all.
///
/// The privacy property is structural rather than a scrubbing pass: the
/// original file is decoded to pixels and a **fresh** JPEG is written from
/// those pixels with no source properties copied. EXIF, GPS, TIFF, maker
/// notes — none of it survives because none of it is ever read. The original
/// bytes are never uploaded (docs/social-architecture.md §6.1).
///
/// The server's bucket enforces its own caps (1 MB, image/jpeg) so this
/// re-encode is a courtesy to the user's data, not the security boundary.
public enum AvatarEncoder {

    public enum Failure: Error, Equatable {
        /// Not an image, or not one this platform can decode.
        case undecodable
        /// Decoded, but a derivative could not be produced — out of memory,
        /// zero-sized image, or an encoder refusal.
        case encodingFailed
        /// The derivative would exceed `maxBytes` even at minimum quality.
        /// Should be unreachable at 512px; kept because "should be" is not
        /// a size limit.
        case tooLarge
    }

    /// The longest edge of the uploaded derivative.
    public static let maxPixels = 512
    /// The bucket's own cap, mirrored so refusal happens before a network
    /// round-trip rather than after one.
    public static let maxBytes = 1_048_576

    /// Re-encode picked image data into the uploadable derivative.
    public static func encode(_ original: Data, maxPixels: Int = AvatarEncoder.maxPixels) throws -> Data {
        // Decode via a thumbnail rather than the full image: it downscales in
        // one step, bakes any EXIF orientation into the pixels (so dropping
        // the metadata cannot leave the image sideways), and never holds a
        // 48-megapixel bitmap for a 512-pixel result.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(original as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.undecodable
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw Failure.undecodable
        }

        // Write a fresh JPEG from the pixels. The only property supplied is
        // compression quality; supplying no metadata is what guarantees there
        // is none.
        for quality in [0.8, 0.6, 0.4] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                    data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw Failure.encodingFailed
            }
            let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else {
                throw Failure.encodingFailed
            }
            if data.length <= maxBytes { return data as Data }
        }
        throw Failure.tooLarge
    }
}
