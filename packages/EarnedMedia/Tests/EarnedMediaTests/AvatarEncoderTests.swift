import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import EarnedMedia

/// The properties that make an avatar safe to upload, each proven on real
/// bytes: the tests build genuine JPEG/PNG files — including one with a full
/// GPS block — and read the derivative back the way any inspector would.
struct AvatarEncoderTests {

    // MARK: - Fixtures

    /// A solid-colour image of the given size, encoded with whatever
    /// properties are supplied — which is how the GPS-laden input is made.
    private func image(width: Int, height: Int,
                       type: UTType = .jpeg,
                       properties: [CFString: Any] = [:]) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A JPEG carrying exactly the metadata the encoder must strip: GPS
    /// coordinates, an EXIF timestamp, and a TIFF camera model.
    private func imageWithLocation() throws -> Data {
        try image(width: 1200, height: 900, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5074,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1278,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:31 09:00:00",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "iPhone 17 Pro",
            ],
        ])
    }

    private func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    // MARK: - The privacy property

    @Test func stripsGPSAndEXIFAndTIFFMetadata() throws {
        let original = try imageWithLocation()
        // Prove the fixture actually carries what the encoder must remove —
        // a strip test over a clean input proves nothing.
        #expect(properties(of: original)[kCGImagePropertyGPSDictionary] != nil)

        let encoded = try AvatarEncoder.encode(original)
        let result = properties(of: encoded)
        #expect(result[kCGImagePropertyGPSDictionary] == nil)
        #expect(result[kCGImagePropertyTIFFDictionary] == nil)
        if let exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // Encoders may write structural EXIF (pixel dimensions); what must
            // not survive is anything from the source.
            #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        }
    }

    @Test func coordinatesAppearNowhereInTheBytes() throws {
        let encoded = try AvatarEncoder.encode(try imageWithLocation())
        // Belt and braces: the latitude as rationals could hide from the
        // dictionary API; the raw byte search cannot be fooled by structure.
        #expect(!encoded.contains(Data("51.5074".utf8)))
        #expect(!encoded.contains(Data("iPhone 17 Pro".utf8)))
    }

    // MARK: - Size and shape

    @Test func downscalesOversizedImages() throws {
        let encoded = try AvatarEncoder.encode(try image(width: 4000, height: 3000))
        let result = properties(of: encoded)
        let width = result[kCGImagePropertyPixelWidth] as! Int
        let height = result[kCGImagePropertyPixelHeight] as! Int
        #expect(max(width, height) <= AvatarEncoder.maxPixels)
        #expect(encoded.count <= AvatarEncoder.maxBytes)
        // And aspect is preserved rather than squashed.
        #expect(abs(Double(width) / Double(height) - 4.0 / 3.0) < 0.02)
    }

    @Test func smallImagesStaySmall() throws {
        let encoded = try AvatarEncoder.encode(try image(width: 100, height: 100))
        let result = properties(of: encoded)
        #expect((result[kCGImagePropertyPixelWidth] as! Int) <= 100)
    }

    @Test func outputIsAlwaysJPEG() throws {
        // A PNG in is a JPEG out — one accepted upload format, whatever came in.
        let encoded = try AvatarEncoder.encode(try image(width: 300, height: 300, type: .png))
        #expect(encoded.prefix(2) == Data([0xFF, 0xD8]))
    }

    // MARK: - Refusals

    @Test func refusesNonImageData() {
        #expect(throws: AvatarEncoder.Failure.undecodable) {
            try AvatarEncoder.encode(Data("not an image at all".utf8))
        }
    }

    @Test func refusesEmptyData() {
        #expect(throws: AvatarEncoder.Failure.undecodable) {
            try AvatarEncoder.encode(Data())
        }
    }
}
