import Foundation
import UIKit

extension StreamingService {

    // MARK: - Stream URL

    func streamURL(for track: StreamTrack) async throws -> URL {
        guard isConfigured else {
            throw StreamingError.notConfigured
        }

        // Return the bridge's stream PROXY URL rather than the raw CDN URL.
        // YouTube's googlevideo URLs are bound to the IP that extracted them, so
        // the old flow (bridge extracts → app fetches the raw URL from a
        // different IP) returned 403 and never produced a temp file to play. The
        // proxy re-streams the audio from the bridge's IP, so playback works; it
        // also extracts lazily (when the app fetches it), so Play is instant and
        // the URL is deterministic/cacheable. Auth/cookie headers travel on the
        // Song (see `toSong`) since the player fetches this URL directly.
        // `preferredFormat` is the DOWNLOAD preference and must not be used
        // here. A download can be transcoded and re-tagged server-side; a live
        // stream hands bytes straight to AVFoundation, which cannot demux
        // several of the formats that setting offers — Opus resolves to a WebM
        // container and fails outright (AVErrorFileFormatNotRecognized, -11828).
        // The bridge already coerces those to m4a, but asking for the right
        // thing keeps both sides agreeing on what the bytes are: the temp file
        // this stream is written to takes its extension from the requested
        // format, so requesting opus and receiving AAC produced a `.opus` file
        // full of MP4 that AVAudioFile rejected as invalid ('dta?').
        //
        // m4a is YouTube's native itag 140 (AAC in MP4) — no transcode, and
        // natively playable. Non-YouTube sources keep the requested format,
        // since the bridge only substitutes for YouTube.
        let streamFormat = track.source == "youtube" ? "m4a" : preferredFormat
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id",     value: track.id),
            URLQueryItem(name: "source", value: track.source),
            URLQueryItem(name: "format", value: streamFormat),
        ]
        if track.source == "soundcloud" || track.source == "bandcamp" {
            queryItems.append(URLQueryItem(name: "url", value: track.youtubeURL))
        }
        // Carried in the URL because AVPlayer's byte-range requests do not carry
        // our headers — see StreamingService+StreamTicket. The header auth stays
        // on as well; this is the credential that survives the requests the
        // headers never reach.
        if let ticket = await streamTicket() {
            queryItems.append(URLQueryItem(name: "ticket", value: ticket))
        }

        var components = URLComponents()
        components.path = "/api/stream/proxy"
        components.queryItems = queryItems

        guard let request = makeRequest(components.string ?? "/api/stream/proxy"),
              let url = request.url else {
            throw StreamingError.invalidURL
        }
        appLog("streamURL: proxy URL for \"\(track.title)\" [src: \(track.source), fmt: \(streamFormat)]", category: "network")
        return url
    }
}
