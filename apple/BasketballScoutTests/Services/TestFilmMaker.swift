import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Writes a small H.264 MP4 at test time (no binary films in the repository). Frame `i` is a flat
/// grey of level `level(i)`, so a grabbed frame shows which one it is.
nonisolated enum TestFilmMaker {
    static let width = 160
    static let height = 120
    static let framesPerSecond: Int32 = 10
    static let frameCount = 20

    /// The grey level of frame `index`.
    static func level(_ index: Int) -> UInt8 {
        UInt8(clamping: 20 + index * 10)
    }

    /// A 2-second film (20 frames at 10 fps), `moov` at the end as AVAssetWriter leaves it.
    @concurrent
    static func makeMP4(at url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let buffer = try pixelBuffer(level: level(index))
            let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func pixelBuffer(level: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.fileWriteUnknown) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                pixels[offset] = level
                pixels[offset + 1] = level
                pixels[offset + 2] = level
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    /// The mean grey level of `image` (drawn into an 8-bit grey bitmap).
    static func meanLevel(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, !pixels.isEmpty else { return -1 }
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }
}
