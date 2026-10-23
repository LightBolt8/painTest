import CoreGraphics
import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(onnxruntime_objc)
import onnxruntime_objc
#elseif canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#elseif canImport(onnxruntime)
import onnxruntime
#endif

/// On-device FaceFusion FRAN age modifier (same `fran.onnx` model).
enum OnDeviceAgePreview {
    static let modelFileName = "fran.onnx"
    static let modelURL = URL(string: "https://github.com/facefusion/facefusion-assets/releases/download/models-3.6.0/fran.onnx")!
    static let cropSize = 1024
    /// FFHQ-512 template (normalized), scaled to crop size.
    static let ffhqTemplate: [(CGFloat, CGFloat)] = [
        (0.37691676, 0.46864664),
        (0.62285697, 0.46912813),
        (0.50123859, 0.61331904),
        (0.39308822, 0.72541100),
        (0.61150205, 0.72490465)
    ]

    enum Failure: LocalizedError {
        case unsupportedPlatform
        case decodeFailed
        case noFace
        case downloadFailed(String)
        case inferenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "On-device age preview needs ONNX Runtime."
            case .decodeFailed:
                return "Could not read that photo."
            case .noFace:
                return "No face found for on-device age preview."
            case .downloadFailed(let detail):
                return "Could not download FRAN model: \(detail)"
            case .inferenceFailed(let detail):
                return "On-device age failed: \(detail)"
            }
        }
    }

    static var cachedModelURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("painTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(modelFileName)
    }

    static var isModelReady: Bool {
        FileManager.default.fileExists(atPath: cachedModelURL.path)
    }

    static func ensureModel() async throws {
        if isModelReady { return }

        let local = URL(fileURLWithPath: "/Users/bryanhan/painTest/FaceFusion/.assets/models/fran.onnx")
        if FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.copyItem(at: local, to: cachedModelURL)
            return
        }

        let (data, response) = try await URLSession.shared.data(from: modelURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Failure.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try data.write(to: cachedModelURL, options: .atomic)
    }

    /// Applies FRAN age direction (-100...100). Negative = younger.
    static func apply(imageData: Data, direction: Int, assumedAge: Double = 35) async throws -> Data {
        #if canImport(onnxruntime_objc) || canImport(OnnxRuntimeBindings) || canImport(onnxruntime)
        try await ensureModel()
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSync(imageData: imageData, direction: direction, assumedAge: assumedAge)
        }.value
        #else
        throw Failure.unsupportedPlatform
        #endif
    }

    #if canImport(onnxruntime_objc) || canImport(OnnxRuntimeBindings) || canImport(onnxruntime)
    nonisolated private static func runSync(imageData: Data, direction: Int, assumedAge: Double) throws -> Data {
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw Failure.decodeFailed
        }
        #else
        guard let ns = NSImage(data: imageData),
              let cgImage = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.decodeFailed
        }
        #endif

        let landmarks = try detectFaceLandmarks5(in: cgImage)
        let (cropped, inverse) = try warpToFFHQ(cgImage: cgImage, landmarks: landmarks)
        let outputCrop = try runFran(crop: cropped, direction: direction, assumedAge: assumedAge)
        let composited = try pasteBack(original: cgImage, agedCrop: outputCrop, inverse: inverse)
        #if canImport(UIKit)
        guard let data = UIImage(cgImage: composited).jpegData(compressionQuality: 0.92) else {
            throw Failure.inferenceFailed("JPEG encode failed")
        }
        return data
        #else
        let rep = NSBitmapImageRep(cgImage: composited)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw Failure.inferenceFailed("JPEG encode failed")
        }
        return data
        #endif
    }

    private static func detectFaceLandmarks5(in cgImage: CGImage) throws -> [CGPoint] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        guard let face = request.results?.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }), let landmarks = face.landmarks else {
            throw Failure.noFace
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        func center(of region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            var sx: CGFloat = 0, sy: CGFloat = 0
            for i in 0..<region.pointCount {
                let p = region.normalizedPoints[i]
                let x = face.boundingBox.origin.x + p.x * face.boundingBox.width
                let y = face.boundingBox.origin.y + p.y * face.boundingBox.height
                sx += x * w
                sy += (1 - y) * h
            }
            return CGPoint(x: sx / CGFloat(region.pointCount), y: sy / CGFloat(region.pointCount))
        }

        guard
            let leftEye = center(of: landmarks.leftEye),
            let rightEye = center(of: landmarks.rightEye),
            let nose = center(of: landmarks.noseCrest) ?? center(of: landmarks.nose),
            let outer = landmarks.outerLips, outer.pointCount > 0
        else { throw Failure.noFace }

        var mouthPoints: [CGPoint] = []
        for i in 0..<outer.pointCount {
            let p = outer.normalizedPoints[i]
            let x = (face.boundingBox.origin.x + p.x * face.boundingBox.width) * w
            let y = (1 - (face.boundingBox.origin.y + p.y * face.boundingBox.height)) * h
            mouthPoints.append(CGPoint(x: x, y: y))
        }
        let mouthLeft = mouthPoints.min(by: { $0.x < $1.x })!
        let mouthRight = mouthPoints.max(by: { $0.x < $1.x })!

        return [leftEye, rightEye, nose, mouthLeft, mouthRight]
    }

    private static func warpToFFHQ(cgImage: CGImage, landmarks: [CGPoint]) throws -> (CGImage, CGAffineTransform) {
        let size = CGFloat(cropSize)
        let dst = ffhqTemplate.map { CGPoint(x: $0.0 * size, y: $0.1 * size) }
        let transform = similarityTransform(from: landmarks, to: dst)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: cropSize,
            height: cropSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.inferenceFailed("crop context") }

        ctx.interpolationQuality = .high
        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let cropped = ctx.makeImage() else { throw Failure.inferenceFailed("crop image") }
        return (cropped, transform.inverted())
    }

    private static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(src.count)
        let srcMean = CGPoint(
            x: src.map(\.x).reduce(0, +) / n,
            y: src.map(\.y).reduce(0, +) / n
        )
        let dstMean = CGPoint(
            x: dst.map(\.x).reduce(0, +) / n,
            y: dst.map(\.y).reduce(0, +) / n
        )

        var num: CGFloat = 0
        var den: CGFloat = 0
        for i in 0..<src.count {
            let s = CGPoint(x: src[i].x - srcMean.x, y: src[i].y - srcMean.y)
            let d = CGPoint(x: dst[i].x - dstMean.x, y: dst[i].y - dstMean.y)
            num += s.x * d.y - s.y * d.x
            den += s.x * d.x + s.y * d.y
        }
        let angle = atan2(num, den)
        var srcVar: CGFloat = 0
        for p in src {
            let dx = p.x - srcMean.x
            let dy = p.y - srcMean.y
            srcVar += dx * dx + dy * dy
        }
        var cov: CGFloat = 0
        for i in 0..<src.count {
            let s = CGPoint(x: src[i].x - srcMean.x, y: src[i].y - srcMean.y)
            let d = CGPoint(x: dst[i].x - dstMean.x, y: dst[i].y - dstMean.y)
            cov += s.x * d.x + s.y * d.y
        }
        let scale = srcVar > 1e-6 ? hypot(cov, num) / srcVar : 1
        let cosA = cos(angle) * scale
        let sinA = sin(angle) * scale
        let tx = dstMean.x - (cosA * srcMean.x - sinA * srcMean.y)
        let ty = dstMean.y - (sinA * srcMean.x + cosA * srcMean.y)
        return CGAffineTransform(a: cosA, b: sinA, c: -sinA, d: cosA, tx: tx, ty: ty)
    }

    private static func pasteBack(original: CGImage, agedCrop: CGImage, inverse: CGAffineTransform) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: original.width,
            height: original.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.inferenceFailed("paste context") }

        ctx.interpolationQuality = .high
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        ctx.concatenate(inverse)
        ctx.saveGState()
        let inset = CGFloat(cropSize) * 0.08
        let oval = CGRect(x: inset, y: inset, width: CGFloat(cropSize) - inset * 2, height: CGFloat(cropSize) - inset * 2)
        ctx.addEllipse(in: oval)
        ctx.clip()
        ctx.setAlpha(0.95)
        ctx.draw(agedCrop, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
        ctx.restoreGState()

        guard let out = ctx.makeImage() else { throw Failure.inferenceFailed("paste image") }
        return out
    }

    private static func runFran(crop: CGImage, direction: Int, assumedAge: Double) throws -> CGImage {
        // Validate model looks complete (~125MB).
        let attrs = try FileManager.default.attributesOfItem(atPath: cachedModelURL.path)
        let size = attrs[.size] as? NSNumber
        if let size, size.int64Value < 50_000_000 {
            throw Failure.downloadFailed("FRAN model file looks incomplete")
        }

        let pixels = try rgbaFloatCHW(from: crop)
        let age = assumedAge
        let dir = Double(max(-100, min(100, direction)))
        var directionVec: [Float] = [
            Float(min(max(age / 100.0, 0), 1)),
            Float(min(max((age + dir) / 100.0, 0), 1))
        ]

        let env = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        // CPU only — CoreML EP has been unstable with this model on device.
        try options.setGraphOptimizationLevel(.basic)
        let session = try ORTSession(env: env, modelPath: cachedModelURL.path, sessionOptions: options)

        // Keep buffers alive for the duration of session.run.
        let targetData = NSMutableData()
        pixels.withUnsafeBufferPointer { buf in
            targetData.append(buf.baseAddress!, length: buf.count * MemoryLayout<Float>.size)
        }
        let target = try ORTValue(
            tensorData: targetData,
            elementType: .float,
            shape: [1, 3, NSNumber(value: cropSize), NSNumber(value: cropSize)]
        )
        let dirData = NSMutableData()
        directionVec.withUnsafeBufferPointer { buf in
            dirData.append(buf.baseAddress!, length: buf.count * MemoryLayout<Float>.size)
        }
        let directionValue = try ORTValue(
            tensorData: dirData,
            elementType: .float,
            shape: [2]
        )

        let outputs = try session.run(
            withInputs: ["target": target, "direction": directionValue],
            outputNames: Set(["output"]),
            runOptions: nil
        )
        // Retain inputs until after run completes.
        withExtendedLifetime(targetData) {}
        withExtendedLifetime(dirData) {}
        withExtendedLifetime(target) {}
        withExtendedLifetime(directionValue) {}

        guard let output = outputs["output"] else {
            throw Failure.inferenceFailed("missing output")
        }
        let outData = try output.tensorData() as Data
        let outFloats = outData.withUnsafeBytes { buf -> [Float] in
            Array(buf.bindMemory(to: Float.self))
        }
        return try cgImageFromCHW(outFloats)
    }

    private static func rgbaFloatCHW(from image: CGImage) throws -> [Float] {
        let width = cropSize
        let height = cropSize
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.inferenceFailed("tensor context") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var chw = [Float](repeating: 0, count: 3 * width * height)
        let plane = width * height
        for i in 0..<plane {
            let o = i * 4
            chw[i] = Float(rgba[o]) / 255
            chw[plane + i] = Float(rgba[o + 1]) / 255
            chw[2 * plane + i] = Float(rgba[o + 2]) / 255
        }
        return chw
    }

    private static func cgImageFromCHW(_ chw: [Float]) throws -> CGImage {
        let width = cropSize
        let height = cropSize
        let plane = width * height
        var rgba = [UInt8](repeating: 255, count: plane * 4)
        for i in 0..<plane {
            let r = min(max(chw[i], 0), 1)
            let g = min(max(chw[plane + i], 0), 1)
            let b = min(max(chw[2 * plane + i], 0), 1)
            let o = i * 4
            rgba[o] = UInt8(r * 255)
            rgba[o + 1] = UInt8(g * 255)
            rgba[o + 2] = UInt8(b * 255)
            rgba[o + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            throw Failure.inferenceFailed("output image")
        }
        return image
    }
    #endif
}

