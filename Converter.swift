import AVFoundation
import CoreImage
import ImageIO
import AppKit

enum ConvertError: LocalizedError {
    case unreadable(String)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let s): return "Couldn't read that file: \(s)"
        case .writer(let s): return "Couldn't make the video: \(s)"
        }
    }
}

/// Turns a GIF or video into a 4K HEVC .mov in the same shape as Apple's Aerial wallpapers.
/// Short clips are repeated until the file is at least `minDuration` seconds long.
final class Converter {
    static let width = 3840
    static let height = 2160
    static let minDuration = 60.0
    static let timescale: CMTimeScale = 60000

    private let ci = CIContext()
    private var firstFrame: CIImage?

    /// Writes `output` (.mov) and `thumbnail` (.png). `progress` gets 0...1.
    func convert(input: URL, output: URL, thumbnail: URL, progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: output)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        // Put the video index at the front of the file, like ffmpeg's +faststart.
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 25_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ],
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(writerInput) else { throw ConvertError.writer("encoder setup failed") }
        writer.add(writerInput)
        guard writer.startWriting() else { throw ConvertError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        var lastTime: Int64 = -1
        func append(_ image: CIImage, at time: Int64) throws {
            // Two frames can't share a timestamp.
            let t = max(time, lastTime + 1)
            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed { throw ConvertError.writer(writer.error?.localizedDescription ?? "encoder failed") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ConvertError.writer("no buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ConvertError.writer("no pixel buffer") }
            let filled = Self.fill(image)
            if firstFrame == nil { firstFrame = filled }
            ci.render(filled, to: buffer, bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                      colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: t, timescale: Self.timescale)) {
                throw ConvertError.writer(writer.error?.localizedDescription ?? "append failed")
            }
            lastTime = t
        }

        let ext = input.pathExtension.lowercased()
        let endTime: Int64
        if ext == "gif" {
            endTime = try writeGIF(input, append: append, progress: progress)
        } else {
            endTime = try writeVideo(input, append: append, progress: progress)
        }

        writerInput.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: endTime, timescale: Self.timescale))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw ConvertError.writer(writer.error?.localizedDescription ?? "finish failed")
        }
        try writeThumbnail(to: thumbnail)
        progress(1)
    }

    // MARK: GIF

    private func writeGIF(_ url: URL, append: (CIImage, Int64) throws -> Void, progress: (Double) -> Void) throws -> Int64 {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConvertError.unreadable("not a GIF") }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ConvertError.unreadable("GIF has no frames") }

        var delays: [Int64] = []
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            var d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
            if d <= 0 { d = (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0 }
            if d < 0.02 { d = 0.1 } // same rule browsers use for "0" delays
            delays.append(Int64(d * Double(Self.timescale)))
        }
        let loopLength = delays.reduce(0, +)
        let target = Int64(Self.minDuration * Double(Self.timescale))

        var t: Int64 = 0
        repeat {
            for i in 0..<count {
                // Decode on demand: caching 4K frames for a long GIF would use gigabytes.
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                try autoreleasepool { try append(CIImage(cgImage: cg), t) }
                t += delays[i]
            }
            progress(min(0.99, Double(t) / Double(max(target, loopLength))))
        } while t < target
        return t
    }

    // MARK: Video

    private func writeVideo(_ url: URL, append: (CIImage, Int64) throws -> Void, progress: (Double) -> Void) throws -> Int64 {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw ConvertError.unreadable("no video track") }
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { throw ConvertError.unreadable("video has no length") }
        let orientation = Self.orientation(for: track.preferredTransform)
        let frameStep = Int64(Double(Self.timescale) / Double(max(track.nominalFrameRate, 1)))
        let target = max(Self.minDuration, duration)

        var offset: Int64 = 0
        repeat {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { throw ConvertError.unreadable(reader.error?.localizedDescription ?? "can't decode") }
            var first: Int64?
            var last: Int64 = 0
            while let sample = out.copyNextSampleBuffer() {
                try autoreleasepool {
                    guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                    let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                                                 timescale: Self.timescale, method: .roundHalfAwayFromZero).value
                    if first == nil { first = pts }
                    last = pts - first!
                    try append(CIImage(cvPixelBuffer: pb).oriented(orientation), offset + last)
                    progress(min(0.99, Double(offset + last) / (target * Double(Self.timescale))))
                }
            }
            if reader.status == .failed { throw ConvertError.unreadable(reader.error?.localizedDescription ?? "decode failed") }
            offset += last + frameStep
        } while Double(offset) / Double(Self.timescale) < Self.minDuration
        return offset
    }

    /// Phone videos store rotation as a transform; map the common ones.
    private static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    // MARK: Helpers

    /// Scales to cover 3840x2160 and crops the overflow, so nothing is stretched.
    static func fill(_ image: CIImage, width: Int = Converter.width, height: Int = Converter.height) -> CIImage {
        let e = image.extent
        let w = CGFloat(width), h = CGFloat(height)
        let scale = max(w / e.width, h / e.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - w) / 2
        let dy = (scaled.extent.height - h) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Same size Apple uses for Aerial thumbnails (214x130 pixels).
    private func writeThumbnail(to url: URL) throws {
        guard let frame = firstFrame else { return }
        let small = Self.fill(frame, width: 214, height: 130)
        guard let cg = ci.createCGImage(small, from: CGRect(x: 0, y: 0, width: 214, height: 130)) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
