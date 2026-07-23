import AppKit
import CoreImage.CIFilterBuiltins

enum PairingQR {
    /**
     Renders the pairing JSON as a crisp QR image using CoreImage, scaled
     with nearest-neighbor so modules stay sharp at display size.
     */
    static func image(for text: String, side: CGFloat = 280) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
