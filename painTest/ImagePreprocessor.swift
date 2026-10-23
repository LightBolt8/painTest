import CoreImage
import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// OpenFace preprocess:
/// 1) upright + JPEG + downscale
/// 2) Vision face/blur gate + mild exposure normalize (no tight crop — OpenFace needs full-face context for AUs)
enum ImagePreprocessor {
    static let maxLongEdge: CGFloat = 1280
    static let workingLongEdge: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.90
    /// Soft head margin when trimming huge backgrounds (fraction of face box).
    static let facePadding: CGFloat = 1.15
    /// Laplacian variance below this → treat as too blurry (on ~256px gray face region).
    static let minSharpness: Double = 18

    enum Failure: LocalizedError {
        case decodeFailed
        case noFace
        case tooBlurry
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed:
                return "Could not read that photo."
            case .noFace:
                return "No face found in the photo. Move closer, face the camera, and try again."
            case .tooBlurry:
                return "Photo looks too blurry for analysis. Hold steady and try again."
            case .encodeFailed:
                return "Could not encode the preprocessed photo."
            }
        }
    }

    static func prepareForOpenFace(data: Data) -> Result<Data, Failure> {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return .failure(.decodeFailed) }
        return prepareForOpenFace(image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return .failure(.decodeFailed) }
        return prepareForOpenFace(image)
        #else
        return .failure(.decodeFailed)
        #endif
    }

    #if canImport(UIKit)
    static func prepareForOpenFace(_ image: UIImage) -> Result<Data, Failure> {
        let upright = image.bakedUpright()
        let working = upright.scaledToLongEdge(workingLongEdge)
        guard let cgImage = working.cgImage else { return .failure(.decodeFailed) }

        do {
            let faceRegion = try faceRegionForQualityCheck(cgImage)
            if laplacianVariance(faceRegion) < minSharpness {
                return .failure(.tooBlurry)
            }
            // Prefer generous head framing over tight crop so OpenFace AU models keep context.
            let framed = try softHeadFrame(cgImage) ?? cgImage
            let normalized = mildNormalize(framed) ?? framed
            let ui = UIImage(cgImage: normalized, scale: 1, orientation: .up)
            let sized = ui.scaledToLongEdge(maxLongEdge)
            guard let jpeg = sized.jpegData(compressionQuality: jpegQuality) else {
                return .failure(.encodeFailed)
            }
            return .success(jpeg)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.noFace)
        }
    }
    #endif

    #if canImport(AppKit) && !canImport(UIKit)
    static func prepareForOpenFace(_ image: NSImage) -> Result<Data, Failure> {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(.decodeFailed)
        }
        let working = scaleCGImage(cgImage, maxSide: workingLongEdge)
        do {
            let faceRegion = try faceRegionForQualityCheck(working)
            if laplacianVariance(faceRegion) < minSharpness {
                return .failure(.tooBlurry)
            }
            let framed = try softHeadFrame(working) ?? working
            let normalized = mildNormalize(framed) ?? framed
            let finalImage = scaleCGImage(normalized, maxSide: maxLongEdge)
            let rep = NSBitmapImageRep(cgImage: finalImage)
            guard let jpeg = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegQuality]
            ) else {
                return .failure(.encodeFailed)
            }
            return .success(jpeg)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.noFace)
        }
    }
    #endif

    // MARK: - Step 2 helpers

    private static func largestFaceBox(_ cgImage: CGImage) throws -> CGRect {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        guard let faces = request.results, !faces.isEmpty else {
            throw Failure.noFace
        }

        let largest = faces.max { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        }!

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let box = largest.boundingBox
        return CGRect(
            x: box.origin.x * imgW,
            y: (1 - box.origin.y - box.height) * imgH,
            width: box.width * imgW,
            height: box.height * imgH
        )
    }

    private static func faceRegionForQualityCheck(_ cgImage: CGImage) throws -> CGImage {
        let box = try largestFaceBox(cgImage)
        let rect = box.integral.intersection(
            CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        )
        guard rect.width >= 32, rect.height >= 32,
              let cropped = cgImage.cropping(to: rect) else {
            throw Failure.noFace
        }
        return cropped
    }

    /// Soft head frame: only trim when the face is a small part of a large photo.
    private static func softHeadFrame(_ cgImage: CGImage) throws -> CGImage? {
        let box = try largestFaceBox(cgImage)
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let faceArea = box.width * box.height
        let imageArea = imgW * imgH
        // Face already fills much of the frame — keep full image for OpenFace.
        if faceArea / imageArea >= 0.18 {
            return nil
        }

        let padX = box.width * facePadding
        let padY = box.height * facePadding
        var rect = CGRect(
            x: box.minX - padX,
            y: box.minY - padY,
            width: box.width + padX * 2,
            height: box.height + padY * 2
        )
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard rect.width >= 64, rect.height >= 64 else { return nil }
        return cgImage.cropping(to: rect)
    }

    private static func mildNormalize(_ cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let shadow = CIFilter(name: "CIHighlightShadowAdjust")
        shadow?.setValue(ci, forKey: kCIInputImageKey)
        shadow?.setValue(0.25, forKey: "inputShadowAmount")
        shadow?.setValue(0.95, forKey: "inputHighlightAmount")

        let contrast = CIFilter(name: "CIColorControls")
        contrast?.setValue(shadow?.outputImage ?? ci, forKey: kCIInputImageKey)
        contrast?.setValue(1.05, forKey: kCIInputContrastKey)
        contrast?.setValue(0.0, forKey: kCIInputBrightnessKey)

        guard let out = contrast?.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(out, from: out.extent)
    }

    /// Focus score: variance of a 3×3 Laplacian on a downscaled grayscale crop.
    private static func laplacianVariance(_ cgImage: CGImage) -> Double {
        let targetW = 256
        let scale = CGFloat(targetW) / CGFloat(max(cgImage.width, 1))
        let w = max(32, Int((CGFloat(cgImage.width) * scale).rounded()))
        let h = max(32, Int((CGFloat(cgImage.height) * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }

        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap =
                    Double(pixels[i - w])
                    + Double(pixels[i + w])
                    + Double(pixels[i - 1])
                    + Double(pixels[i + 1])
                    - 4.0 * Double(pixels[i])
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        return (sumSq / count) - (mean * mean)
    }

    #if canImport(AppKit) && !canImport(UIKit)
    private static func scaleCGImage(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide, longest > 0 else { return image }
        let ratio = maxSide / longest
        let newW = max(1, Int((CGFloat(image.width) * ratio).rounded(.down)))
        let newH = max(1, Int((CGFloat(image.height) * ratio).rounded(.down)))
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
    #endif
}

#if canImport(UIKit)
private extension UIImage {
    func bakedUpright() -> UIImage {
        if imageOrientation == .up, let cgImage, cgImage.width > 0 {
            return self
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func scaledToLongEdge(_ maxSide: CGFloat) -> UIImage {
        let pixelSize: CGSize = {
            if let cgImage {
                return CGSize(width: cgImage.width, height: cgImage.height)
            }
            return CGSize(width: size.width * scale, height: size.height * scale)
        }()

        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxSide, longest > 0 else { return self }

        let ratio = maxSide / longest
        let newSize = CGSize(
            width: (pixelSize.width * ratio).rounded(.down),
            height: (pixelSize.height * ratio).rounded(.down)
        )
        guard newSize.width >= 1, newSize.height >= 1 else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
#endif
