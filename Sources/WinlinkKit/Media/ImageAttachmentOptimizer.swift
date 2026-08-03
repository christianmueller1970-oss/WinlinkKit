import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Verkleinert Bild-Anhänge fürs Funkbudget: dekodiert mit ImageIO,
/// skaliert herunter und encodiert als JPEG, bis die Zielgrösse
/// erreicht ist. Nicht-Bilder werden nicht angerührt (`optimize`
/// liefert dann nil).
public enum ImageAttachmentOptimizer {

    public struct Optimized: Sendable {
        public let data: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Kantenlängen-Leiter für die Verkleinerung; pro Stufe werden
    /// absteigende JPEG-Qualitäten probiert.
    private static let maxEdges = [2048, 1600, 1280, 1024, 800, 640, 512, 400, 320]
    private static let qualities = [0.65, 0.5, 0.35]

    /// True, wenn ImageIO die Daten als Bild dekodieren kann.
    public static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// Dateiname des optimierten Anhangs: Endung wird durch .jpg ersetzt.
    public static func optimizedName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + ".jpg"
    }

    /// Optimiert ein Bild auf höchstens `targetBytes`. Ist das Bild
    /// bereits ein JPEG innerhalb des Budgets, kommt es unverändert
    /// zurück; andere Formate (HEIC, PNG …) werden immer nach JPEG
    /// gewandelt, damit jeder Winlink-Empfänger sie öffnen kann.
    /// Lässt sich das Budget selbst auf der kleinsten Stufe nicht
    /// erreichen, kommt die kleinste erzielte Variante zurück.
    /// Nil, wenn die Daten kein dekodierbares Bild sind.
    public static func optimize(_ data: Data, targetBytes: Int) -> Optimized? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let isJPEG = CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString
        if isJPEG && data.count <= targetBytes {
            return Optimized(data: data, pixelWidth: width, pixelHeight: height)
        }

        // Leiter aufs Original begrenzen (nie hochskalieren); erste
        // Stufe ist damit ein Re-Encode in voller Grösse.
        let originalMaxEdge = max(width, height)
        let edges = Array(Set(maxEdges.map { min($0, originalMaxEdge) })).sorted(by: >)
        var best: Optimized?
        for edge in edges {
            for quality in qualities {
                guard let candidate = encode(source, maxEdge: edge, quality: quality) else { continue }
                if best == nil || candidate.data.count < best!.data.count {
                    best = candidate
                }
                if candidate.data.count <= targetBytes {
                    return candidate
                }
            }
        }
        return best
    }

    private static func encode(_ source: CGImageSource, maxEdge: Int, quality: Double) -> Optimized? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Optimized(data: output as Data, pixelWidth: image.width, pixelHeight: image.height)
    }
}
