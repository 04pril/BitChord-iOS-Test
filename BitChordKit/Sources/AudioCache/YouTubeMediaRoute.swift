import Foundation
import BitChordCore

/// Optional experiment. The resolver keeps its original session; only eligible media GETs
/// use this session, after a bounded range request proves the same signed URL works there.
public actor YouTubeMediaRoute {
    nonisolated let session: URLSession
    private let probeLimit: Duration
    private var decisions: [URL: Bool] = [:]
    private var pending: [URL: Task<Bool, Never>] = [:]

    public init(directSession: URLSession, probeLimit: Duration = .milliseconds(1_500)) {
        session = directSession
        self.probeLimit = probeLimit
    }

    func usesDirect(_ stream: ResolvedStream) async -> Bool {
        let url = stream.url
        guard stream.origin == .youtube, !stream.isHLS, url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host()?.lowercased(),
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return false }
        if let decision = decisions[url] { return decision }
        if let probe = pending[url] { return await probe.value }
        guard !Task.isCancelled else { return false }
        let probe = Task {
            let start = ContinuousClock.now
            let result = await Self.test(stream, session: session, limit: probeLimit)
            let message = result == "206"
                ? "direct probe passed (206)"
                : "proxy fallback: direct probe \(result)"
            TrackLog.i("MediaRoute", "\(message) in \(TrackLog.ms(since: start))ms")
            return result == "206"
        }
        pending[url] = probe
        let accepted = await probe.value
        pending[url] = nil
        if decisions.count >= 128 { decisions.removeAll(keepingCapacity: true) }
        decisions[url] = accepted
        return accepted
    }

    func fallBack(_ url: URL, reason: String) {
        guard decisions[url] != false else { return }
        decisions[url] = false
        TrackLog.i("MediaRoute", "proxy fallback: \(reason)")
    }

    /// Diagnostic probes never select a playback route or mutate its remembered decisions.
    public func compare(_ stream: ResolvedStream, proxySession: URLSession) async -> String {
        guard stream.origin == .youtube, !stream.isHLS,
              HTTPAudioSource.isGoogleMediaURL(stream.url) else { return "skipped=ineligible URL" }
        let proxy = await Self.test(stream, session: proxySession, limit: .seconds(3), allowGoogleRedirects: true)
        guard !Task.isCancelled else { return "cancelled" }
        let direct = await Self.test(stream, session: session, limit: .seconds(3), allowGoogleRedirects: true)
        guard !Task.isCancelled else { return "cancelled" }
        let length = stream.contentLength ?? HTTPAudioSource.declaredLength(of: stream.url) ?? 0
        let tail: String
        if direct == "206", length > 32 * 1024 {
            tail = await Self.test(stream, session: session, limit: .seconds(3), allowGoogleRedirects: true,
                                   offset: length - 16 * 1024)
        } else { tail = "not tested" }
        return "proxy=\(proxy) direct=\(direct) directTail=\(tail)"
    }

    private static func test(_ stream: ResolvedStream, session: URLSession, limit: Duration,
                             allowGoogleRedirects: Bool = false, offset: Int64? = nil) async -> String {
        let length = stream.contentLength ?? HTTPAudioSource.declaredLength(of: stream.url)
        let probeSize: Int64 = 16 * 1024
        let boundary: Int64 = 1024 * 1024
        let start = offset ?? ((length ?? 0) >= boundary + probeSize ? boundary : 0)
        let count = min(probeSize, length ?? probeSize)
        guard count > 0 else { return "invalid length" }
        var request = URLRequest(url: stream.url)
        for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        let probeRequest = request
        return await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    var received: Int64 = 0
                    for try await event in HTTPAudioSource.events(for: probeRequest, session: session,
                                                                  allowRedirects: allowGoogleRedirects,
                                                                  googleMediaRedirectsOnly: allowGoogleRedirects) {
                        switch event {
                        case .response(let http):
                            guard http.statusCode == 206 else { return "HTTP \(http.statusCode)" }
                            guard http.mimeType?.hasPrefix("audio/") == true,
                                  let header = http.value(forHTTPHeaderField: "Content-Range"),
                                  let range = HTTPAudioSource.parseContentRange(header),
                                  range.start == start, range.end >= start + count - 1,
                                  length == nil || range.total == length else { return "invalid range" }
                        case .data(let piece):
                            received += Int64(piece.count)
                            if received >= count { return "206" }
                        }
                    }
                    return "short body"
                } catch { return "connection error" }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return "timed out"
            }
            let result = await group.next() ?? "unavailable"
            group.cancelAll()
            return result
        }
    }
}
