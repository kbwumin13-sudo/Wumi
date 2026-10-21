import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Produces the subject mask used by "Remove Background". Injectable so the compositing can be tested
/// without the on-device model.
public protocol ImageForegroundMaskGenerating: Sendable {
    /// A mask covering `image` pixel for pixel (1 keeps a pixel, 0 clears it), or nil when no subject was found.
    func foregroundMask(for image: CGImage) throws -> CIImage?
}

/// On-device subject lifting with `VNGenerateForegroundInstanceMaskRequest`, using every detected instance.
public struct VisionForegroundMaskGenerator: ImageForegroundMaskGenerating {
    public init() {}

    public func foregroundMask(for image: CGImage) throws -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw ImageTransformationError.foregroundDetectionFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        do {
            let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return CIImage(cvPixelBuffer: mask)
        } catch {
            throw ImageTransformationError.foregroundDetectionFailed(error.localizedDescription)
        }
    }
}
