import Foundation
import XCTest
import BitChordTestSupport
@testable import AudioCache

final class YouTubeMediaRouteTests: XCTestCase {
    func testDiagnosticComparisonReadsProxyDirectAndTailWithoutSelectingPlaybackRoute() async throws {
        let body = patternData(count: 1_200_000)
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        let direct = RangeServer()
        let proxy = RangeServer()
        direct.host(body, at: url)
        proxy.host(body, at: url)
        let route = YouTubeMediaRoute(directSession: direct.session)
        let resolved = stream(url, length: body.count)
        let report = await route.compare(resolved, proxySession: proxy.session)
        XCTAssertEqual(report, "proxy=206 direct=206 directTail=206")
        XCTAssertEqual(proxy.ranges(), [1_048_576..<1_064_960])
        XCTAssertEqual(direct.ranges(), [1_048_576..<1_064_960, 1_183_616..<1_200_000])
        direct.refuse(url)
        let decision = await route.usesDirect(resolved)
        XCTAssertFalse(decision, "comparison must not install its success as a playback decision")
    }

    func testDiagnosticReportSeparatesWorkingProxyFromRefusedDirectRoute() async throws {
        let body = patternData(count: 100_000)
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        let direct = RangeServer()
        let proxy = RangeServer()
        direct.refuse(url)
        proxy.host(body, at: url)
        let route = YouTubeMediaRoute(directSession: direct.session)
        let report = await route.compare(stream(url, length: body.count), proxySession: proxy.session)
        XCTAssertEqual(report, "proxy=206 direct=HTTP 403 directTail=not tested")
        XCTAssertEqual(direct.requests.count, 1)
    }

    func testRedirectAllowListRejectsOtherHostsCredentialsAndPlainHTTP() {
        for raw in ["https://rr1.googlevideo.com/file", "https://googlevideo.com:443/file"] {
            XCTAssertTrue(HTTPAudioSource.isGoogleMediaURL(URL(string: raw)!))
        }
        for raw in ["https://googlevideo.com.evil.test/file", "https://notgooglevideo.com/file",
                    "http://rr1.googlevideo.com/file", "https://user:secret@rr1.googlevideo.com/file",
                    "https://rr1.googlevideo.com:8443/file"] {
            XCTAssertFalse(HTTPAudioSource.isGoogleMediaURL(URL(string: raw)!))
        }
    }

    func testVerifiedURLUsesDirectForAudioAndChecksPastTheFirstMiBOnce() async throws {
        let body = patternData(count: 1_200_000)
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        let direct = RangeServer()
        direct.host(body, at: url)
        let proxy = RangeServer()
        let route = YouTubeMediaRoute(directSession: direct.session)
        let resolved = stream(url, length: body.count, headers: ["User-Agent": "selected-client"])
        let first = HTTPAudioSource(stream: resolved, session: proxy.session, mediaRoute: route)
        let second = HTTPAudioSource(stream: resolved, session: proxy.session, mediaRoute: route)
        let head = try await first.read(0..<1024)
        let tail = try await second.read(1_150_000..<1_151_000)
        XCTAssertEqual(head, body.prefix(1024))
        XCTAssertEqual(tail, body[1_150_000..<1_151_000])
        XCTAssertEqual(direct.ranges(), [1_048_576..<1_064_960, 0..<1024, 1_150_000..<1_151_000])
        XCTAssertTrue(direct.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "selected-client" })
        XCTAssertTrue(proxy.requests.isEmpty)
    }

    func testProbeRefusalUsesSameURLThroughProxy() async throws {
        let body = patternData(count: 100_000)
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        let direct = RangeServer()
        direct.refuse(url)
        let proxy = RangeServer()
        proxy.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: proxy.session,
                                     mediaRoute: YouTubeMediaRoute(directSession: direct.session))
        let bytes = try await source.read(0..<4096)
        XCTAssertEqual(bytes, body.prefix(4096))
        XCTAssertEqual(direct.ranges(), [0..<16_384])
        XCTAssertEqual(proxy.ranges(for: url), [0..<4096])
    }

    func testShortDirectReadResumesAtTheNextByteThroughProxy() async throws {
        let body = patternData(count: 100_000)
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        let direct = URLProtocolStub()
        direct.register(matching: { _ in true }) { request in
            let range = request.value(forHTTPHeaderField: "Range").flatMap(RangeServer.parseRange)!
            let count = range.count == 16_384 ? 16_384 : 1024
            return .data(body.prefix(count), status: 206, headers: [
                "Content-Type": "audio/mp4",
                "Content-Range": "bytes 0-\(count - 1)/\(body.count)",
                "Content-Length": "\(count)",
            ])
        }
        let proxy = RangeServer()
        proxy.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: proxy.session,
                                     mediaRoute: YouTubeMediaRoute(directSession: direct.makeSession()),
                                     onRefused: { _, _ in XCTFail("The direct path must not retire the resolver's client") })
        let first = try await source.read(0..<4096)
        let second = try await source.read(4096..<8192)
        XCTAssertEqual(first, body.prefix(4096))
        XCTAssertEqual(second, body[4096..<8192])
        XCTAssertEqual(direct.requests.count, 2)
        XCTAssertEqual(proxy.ranges(for: url), [1024..<4096, 4096..<8192])
    }

    func testThirdPartyAndLookalikeHostDoNotUseDirectSession() async throws {
        let body = patternData(count: 100_000)
        let direct = RangeServer()
        let proxy = RangeServer()
        let route = YouTubeMediaRoute(directSession: direct.session)
        let google = googlevideoURL(client: "VISIONOS", length: body.count)
        var addon = stream(google, length: body.count)
        addon.origin = .addon
        let lookalike = URL(string: "https://notgooglevideo.com/videoplayback")!
        for resolved in [addon, stream(lookalike, length: body.count)] {
            proxy.host(body, at: resolved.url)
            let source = HTTPAudioSource(stream: resolved, session: proxy.session, mediaRoute: route)
            let bytes = try await source.read(0..<1024)
            XCTAssertEqual(bytes, body.prefix(1024))
        }
        XCTAssertTrue(direct.requests.isEmpty)
        XCTAssertEqual(proxy.requests.count, 2)
    }
}
