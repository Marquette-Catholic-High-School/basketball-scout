import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BasketballScout

/// The resource loader's byte-range math and content types (04 §4, 09 R11, R12).
nonisolated struct VideoRangeTests {
    @Test func rangeHeaders() {
        #expect(ByteRange(start: 0, end: 1).headerValue == "bytes=0-1")
        #expect(ByteRange(start: 100).headerValue == "bytes=100-")
        #expect(ByteRange(start: 100, end: 199).length == 100)
        #expect(ByteRange(start: 100).length == nil)
    }

    @Test func whatADataRequestStillNeeds() {
        // A fresh bounded request.
        #expect(ByteRange.remaining(requestedOffset: 0, requestedLength: 2, currentOffset: 0, toEndOfResource: false, contentLength: nil)
            == ByteRange(start: 0, end: 1))
        // Part of it was delivered already.
        #expect(ByteRange.remaining(requestedOffset: 1000, requestedLength: 500, currentOffset: 1200, toEndOfResource: false, contentLength: nil)
            == ByteRange(start: 1200, end: 1499))
        // To the end: open-ended, or up to the known length.
        #expect(ByteRange.remaining(requestedOffset: 5000, requestedLength: Int.max, currentOffset: 5000, toEndOfResource: true, contentLength: nil)
            == ByteRange(start: 5000))
        #expect(ByteRange.remaining(requestedOffset: 5000, requestedLength: Int.max, currentOffset: 5000, toEndOfResource: true, contentLength: 10240)
            == ByteRange(start: 5000, end: 10239))
        // Clamped to the length; nothing left past it.
        #expect(ByteRange.remaining(requestedOffset: 10000, requestedLength: 1000, currentOffset: 10000, toEndOfResource: false, contentLength: 10240)
            == ByteRange(start: 10000, end: 10239))
        #expect(ByteRange.remaining(requestedOffset: 10240, requestedLength: 10, currentOffset: 10240, toEndOfResource: false, contentLength: 10240) == nil)
        #expect(ByteRange.remaining(requestedOffset: 0, requestedLength: 100, currentOffset: 100, toEndOfResource: false, contentLength: nil) == nil)
        #expect(ByteRange.remaining(requestedOffset: 0, requestedLength: 0, currentOffset: 0, toEndOfResource: false, contentLength: nil) == nil)
        // A huge requested length does not overflow.
        #expect(ByteRange.remaining(requestedOffset: Int64.max - 10, requestedLength: Int.max, currentOffset: Int64.max - 10, toEndOfResource: false, contentLength: nil)
            == ByteRange(start: Int64.max - 10))
    }

    /// 04 §4 captures: `bytes 0-1/10240` on a 206, `bytes */10240` on a 416.
    @Test func contentRangeHeaders() {
        #expect(ContentRange(headerValue: "bytes 0-1/10240") == ContentRange(start: 0, end: 1, total: 10240))
        #expect(ContentRange(headerValue: "bytes 100-10239/10240") == ContentRange(start: 100, end: 10239, total: 10240))
        #expect(ContentRange(headerValue: "Bytes 5-9/*") == ContentRange(start: 5, end: 9, total: nil))
        #expect(ContentRange(headerValue: "bytes */10240") == ContentRange(start: nil, end: nil, total: 10240))
        #expect(ContentRange(headerValue: "bytes 9-5/10240") == nil)
        #expect(ContentRange(headerValue: "bytes 0-10240/10240") == nil)
        #expect(ContentRange(headerValue: "bytes */*") == nil)
        #expect(ContentRange(headerValue: "items 0-1/2") == nil)
        #expect(ContentRange(headerValue: "bytes abc") == nil)
    }

    /// 09 R11: `.mov` → QuickTime, otherwise MPEG-4 (the server says `video/mp4` for both, 04 §8.13).
    @Test func contentTypes() {
        #expect(VideoAssetFactory.contentType(filmFileName: "Game Film.MOV", variant: .original) == .quickTimeMovie)
        #expect(VideoAssetFactory.contentType(filmFileName: "Game Film.mp4", variant: .original) == .mpeg4Movie)
        #expect(VideoAssetFactory.contentType(filmFileName: "Game Film.m4v", variant: .original) == .mpeg4Movie)
        #expect(VideoAssetFactory.contentType(filmFileName: nil, variant: .original) == .mpeg4Movie)
        #expect(VideoAssetFactory.contentType(filmFileName: "Game Film.mov", variant: .annotated) == .mpeg4Movie)
    }

    @Test func theTypeMustBeOneAVFoundationAllows() {
        let quickTime = UTType.quickTimeMovie.identifier
        let mpeg4 = UTType.mpeg4Movie.identifier
        #expect(VideoResourceLoader.allowedType(quickTime, allowed: nil) == quickTime)
        #expect(VideoResourceLoader.allowedType(quickTime, allowed: []) == quickTime)
        #expect(VideoResourceLoader.allowedType(quickTime, allowed: [mpeg4, quickTime]) == quickTime)
        #expect(VideoResourceLoader.allowedType(quickTime, allowed: ["public.mp3", mpeg4]) == mpeg4)
        #expect(VideoResourceLoader.allowedType(quickTime, allowed: ["public.mp3"]) == "public.mp3")
    }

    @Test func streamURLs() {
        #expect(VideoAssetFactory.isStreamURL(URL(string: "scoutvideo://film/1.mp4")))
        #expect(VideoAssetFactory.isStreamURL(URL(string: "SCOUTVIDEO://film/1.mp4")))
        #expect(!VideoAssetFactory.isStreamURL(URL(string: "http://10.0.0.5:8000/api/games/g_1/video")))
        #expect(!VideoAssetFactory.isStreamURL(nil))
    }

    @Test func theFakeServerParsesRangesLikeStarlette() {
        #expect(FakeVideoServer.parse("bytes=0-1", total: 10240)! == (0, 1))
        #expect(FakeVideoServer.parse("bytes=100-", total: 10240)! == (100, 10239))
        #expect(FakeVideoServer.parse("bytes=-100", total: 10240)! == (10140, 10239))
        #expect(FakeVideoServer.parse("bytes=abc", total: 10240) == nil)
    }
}
