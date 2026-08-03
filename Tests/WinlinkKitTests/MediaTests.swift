import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WinlinkKit

struct ImageAttachmentOptimizerTests {

    /// Deterministisches Testbild mit Pseudo-Rauschen (LCG), damit
    /// JPEG nicht trivial klein komprimiert.
    private func makeImageData(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let block = 8
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let r = CGFloat((state >> 33) & 0xFF) / 255
                let g = CGFloat((state >> 41) & 0xFF) / 255
                let b = CGFloat((state >> 49) & 0xFF) / 255
                context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: block, height: block))
            }
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func detectsImagesAndRejectsOtherData() {
        let png = makeImageData(width: 64, height: 64, type: .png)
        #expect(ImageAttachmentOptimizer.isImage(png))
        #expect(!ImageAttachmentOptimizer.isImage(Data("Kein Bild, nur Text".utf8)))
        #expect(ImageAttachmentOptimizer.optimize(Data([0x00, 0x01]), targetBytes: 1000) == nil)
    }

    @Test func shrinksLargeImageBelowTarget() throws {
        let original = makeImageData(width: 1600, height: 1200, type: .png)
        #expect(original.count > 150_000)

        let result = ImageAttachmentOptimizer.optimize(original, targetBytes: 150_000)
        let optimized = try #require(result)
        #expect(optimized.data.count <= 150_000)
        #expect(optimized.pixelWidth <= 1600)

        let source = CGImageSourceCreateWithData(optimized.data as CFData, nil)!
        #expect(CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString)
    }

    @Test func keepsSmallJPEGUntouched() {
        let big = makeImageData(width: 800, height: 600, type: .png)
        let small = ImageAttachmentOptimizer.optimize(big, targetBytes: 100_000)!
        let again = ImageAttachmentOptimizer.optimize(small.data, targetBytes: 100_000)!
        #expect(again.data == small.data)
    }

    @Test func convertsSmallPNGToJPEG() {
        let png = makeImageData(width: 64, height: 64, type: .png)
        let result = ImageAttachmentOptimizer.optimize(png, targetBytes: 1_000_000)!
        let source = CGImageSourceCreateWithData(result.data as CFData, nil)!
        #expect(CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString)
        // Volle Grösse bleibt erhalten, kein Hochskalieren, kein Downscale.
        #expect(result.pixelWidth == 64 && result.pixelHeight == 64)
    }

    @Test func returnsSmallestVariantWhenTargetUnreachable() throws {
        let original = makeImageData(width: 1600, height: 1200, type: .png)
        let result = ImageAttachmentOptimizer.optimize(original, targetBytes: 1)
        let optimized = try #require(result)
        #expect(optimized.data.count < original.count)
        #expect(optimized.pixelWidth <= 320 && optimized.pixelHeight <= 320)
    }

    @Test func renamesToJPGExtension() {
        #expect(ImageAttachmentOptimizer.optimizedName(for: "IMG_1234.HEIC") == "IMG_1234.jpg")
        #expect(ImageAttachmentOptimizer.optimizedName(for: "foto.png") == "foto.jpg")
        #expect(ImageAttachmentOptimizer.optimizedName(for: "ohne-endung") == "ohne-endung.jpg")
    }
}

struct TransferTimeEstimatorTests {

    @Test func secondsScaleLinearlyWithBytes() {
        #expect(TransferTimeEstimator.seconds(forBytes: 0, mode: .ardop500) == 0)
        let one = TransferTimeEstimator.seconds(forBytes: 60, mode: .ardop500)
        #expect(abs(one - 1) < 0.001)
        let double = TransferTimeEstimator.seconds(forBytes: 120, mode: .ardop500)
        #expect(abs(double - 2) < 0.001)
    }

    @Test func formatsSecondsMinutesAndHours() {
        #expect(TransferTimeEstimator.formatted(bytes: 600, mode: .ardop500) == "~10 s")
        #expect(TransferTimeEstimator.formatted(bytes: 150_000, mode: .ardop2000) == "~11 min")
        #expect(TransferTimeEstimator.formatted(bytes: 400_000, mode: .ardop500) == "~1.9 h")
        #expect(TransferTimeEstimator.formatted(bytes: 1, mode: .telnet) == "~1 s")
    }
}
