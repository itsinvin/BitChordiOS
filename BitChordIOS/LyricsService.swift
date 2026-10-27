import Foundation

// MARK: - Lyrics (port of shared/data/lyrics/*)
// LRCLIB is key-less and first. Other providers are tried in the user's
// order; a provider that errors or returns nothing simply falls through to
// the next — no provider's failure is ever presented as "no lyrics".
// LRCLIB has line timing only (see original LrcLib.kt); word timing is
// parsed when a source actually embeds <mm:ss.xx> word tags.

public struct LyricWord: Equatable { public var text: String; public var time: Double }
public struct LyricLine: Equatable, Identifiable {
    public var id = UUID(); public var time: Double; public var text: String; public var words: [LyricWord]; public var translation: String?
    public init(time: Double, text: String, words: [LyricWord] = [], translation: String? = nil) { self.time = time; self.text = text; self.words = words; self.translation = translation }
}
public struct LyricsResult: Equatable {
    public var lines: [LyricLine]; public var provider: String; public var synced: Bool
    public func lineIndex(at position: Double, offsetMs: Int) -> Int? {
        let t = position + Double(offsetMs) / 1000
        var idx: Int? = nil
        for (i, line) in lines.enumerated() where line.time <= t { idx = i }
        return idx
    }
    public func activeWord(in line: LyricLine, at position: Double, offsetMs: Int) -> Int? {
        guard !line.words.isEmpty else { return nil }
        let t = position + Double(offsetMs) / 1000
        var idx: Int? = nil
        for (i, w) in line.words.enumerated() where w.time <= t { idx = i }
        return idx
    }
}

public enum LyricsService {
    public static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let lineTag = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let wordTag = try? NSRegularExpression(pattern: #"<(\d+):(\d+(?:\.\d+)?)>"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = lineTag?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? []
            guard let first = matches.first else { continue }
            func timeOf(_ m: NSTextCheckingResult) -> Double {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                return min * 60 + sec
            }
            let lineTime = timeOf(first)
            var body = raw
            // Strip line tags, keep word tags for word timing.
            body = lineTag?.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "") ?? body
            var words: [LyricWord] = []
            var plain = ""
            if let wt = wordTag {
                let wmatches = wt.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
                var cursor = 0
                let bns = body as NSString
                for (i, m) in wmatches.enumerated() {
                    let nextStart = i + 1 < wmatches.count ? wmatches[i + 1].range.location : bns.length
                    let wordText = bns.substring(with: NSRange(location: m.range.location + m.range.length, length: nextStart - (m.range.location + m.range.length))).trimmingCharacters(in: .whitespaces)
                    if !wordText.isEmpty { words.append(LyricWord(text: wordText, time: timeOf(m))) }
                    _ = cursor
                }
                plain = wt.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: bns.length), withTemplate: "")
            } else { plain = body }
            let text = plain.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append(LyricLine(time: lineTime, text: text, words: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    public static func parsePlain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .enumerated().map { LyricLine(time: Double($0.offset) * 5, text: $0.element) }
    }

    private static func getJSON(_ urlString: String, headers: [String: String] = [:]) async -> JSONValue? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("BitChord-iOS/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }
    private static func getText(_ urlString: String, headers: [String: String] = [:]) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("BitChord-iOS/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func query(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    public static func fetch(for track: Track) async -> LyricsResult? {
        let order = await SettingsStore.shared.lyricsProviderOrder
        for provider in order {
            if let result = await fetchFrom(provider, track: track) { return result }
        }
        return nil
    }
    private static func fetchFrom(_ provider: String, track: Track) async -> LyricsResult? {
        let artist = track.artists.first ?? ""
        switch provider {
        case "LRCLIB":
            for path in ["/api/get", "/api/get-cached"] {
                let url = "https://lrclib.net\(path)?artist_name=\(query(artist))&track_name=\(query(track.title))&album_name=\(query(track.album ?? ""))&duration=\(Int(track.durationSeconds))"
                if let json = await getJSON(url), let synced = json["syncedLyrics"].string, !synced.isEmpty {
                    return LyricsResult(lines: parseLRC(synced), provider: "LRCLIB", synced: true)
                }
                if let json = await getJSON(url), let plain = json["plainLyrics"].string, !plain.isEmpty {
                    return LyricsResult(lines: parsePlain(plain), provider: "LRCLIB", synced: false)
                }
            }
            return nil
        case "LrcRed":
            // Original LrcRed.kt: GET https://lrc.red/search.json?q= then TTML docs.
            let url = "https://lrc.red/search.json?q=\(query("\(track.title) \(artist)"))"
            if let json = await getJSON(url) {
                // search.json answers with a list of documents; take the first
                // lrc/ttml body we can read rather than guessing a shape.
                for item in json.array ?? [] {
                    if let lrc = item["lrc"].string, !lrc.isEmpty { return LyricsResult(lines: parseLRC(lrc), provider: "LrcRed", synced: true) }
                    if let url2 = item["url"].string, let text = await getText(url2), !text.isEmpty {
                        let lines = parseLRC(text); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "LrcRed", synced: true) }
                    }
                }
            }
            return nil
        case "BiniLyrics":
            // Original BiniLyrics.kt: GET https://lyrics-api.binimum.org/ with title/artist query.
            let url = "https://lyrics-api.binimum.org/?title=\(query(track.title))&artist=\(query(artist))"
            if let json = await getJSON(url) {
                for key in ["syncedLyrics", "lrc", "lyrics"] {
                    if let lrc = json[key].string, !lrc.isEmpty {
                        let lines = parseLRC(lrc); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "BiniLyrics", synced: true) }
                    }
                }
            }
            return nil
        case "LyricsPlus":
            // Original LyricsPlus.kt: $host/v2/lyrics/get, hosts tried in order.
            for host in ["https://lyricsplus.binimum.org", "https://lyricsplus.atomix.one", "https://lyrics-plus-backend.vercel.app"] {
                let url = "\(host)/v2/lyrics/get?title=\(query(track.title))&artist=\(query(artist))"
                if let json = await getJSON(url) {
                    for key in ["syncedLyrics", "lrc", "lyrics"] {
                        if let lrc = json[key].string, !lrc.isEmpty {
                            let lines = parseLRC(lrc); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "LyricsPlus", synced: true) }
                        }
                    }
                }
            }
            return nil
        case "Unison":
            let url = "https://unison.boidu.dev/lyrics?title=\(query(track.title))&artist=\(query(artist))"
            if let json = await getJSON(url) {
                for key in ["syncedLyrics", "lrc", "lyrics"] {
                    if let lrc = json[key].string, !lrc.isEmpty {
                        let lines = parseLRC(lrc); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "Unison", synced: true) }
                    }
                }
            }
            return nil
        case "PaxSenix":
            // Original PaxSenix.kt: api.paxsenix.org/lyrics/lrcget needs an API
            // key; without one the provider is skipped, not faked.
            let key = await SettingsStore.shared.paxSenixAPIKey
            guard !key.isEmpty else { return nil }
            let url = "https://api.paxsenix.org/lyrics/lrcget?title=\(query(track.title))&artist=\(query(artist))"
            if let json = await getJSON(url, headers: ["Authorization": "Bearer \(key)"]) {
                for k in ["syncedLyrics", "lrc", "lyrics"] {
                    if let lrc = json[k].string, !lrc.isEmpty {
                        let lines = parseLRC(lrc); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "PaxSenix", synced: true) }
                    }
                }
            }
            return nil
        case "Megalobiz":
            // Original Megalobiz.kt: scrape searchall for a .lrc link, then fetch it.
            let searchURL = "https://www.megalobiz.com/searchall?q=\(query("\(track.title) \(artist)"))"
            if let html = await getText(searchURL),
               let range = html.range(of: #"href="([^"]+\.lrc[^"]*)""#, options: .regularExpression) {
                let href = String(html[range]).replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "&amp;", with: "&")
                let full = href.hasPrefix("http") ? href : "https://www.megalobiz.com\(href)"
                if let lrc = await getText(full) {
                    let lines = parseLRC(lrc); if !lines.isEmpty { return LyricsResult(lines: lines, provider: "Megalobiz", synced: true) }
                }
            }
            return nil
        case "KuGou":
            // KuGou answers KRC (encrypted/encoded) lyrics; decoding that
            // format is not implemented here, so KuGou is attempted via its
            // search only and falls through rather than returning garbage.
            _ = await getJSON("https://mobileservice.kugou.com/api/v3/search/song?keyword=\(query("\(track.title) \(artist)"))&page=1&pagesize=5")
            return nil
        default:
            return nil
        }
    }

    /// Translation via the same Google endpoint the original uses
    /// (translate.googleapis.com/translate_a/single). Word timings are NOT
    /// invented for translated lines — the original re-times words from the
    /// source line, and this port keeps the source timing.
    public static func translate(lines: [LyricLine], to language: String) async -> [LyricLine] {
        guard !language.isEmpty, language != "en" else { return lines }
        let joined = lines.map { $0.text }.joined(separator: "\n")
        let url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(query(language))&dt=t&q=\(query(joined))"
        guard let json = await getJSON(url) else { return lines }
        // Response: [[[translated, original, ...], ...], ...]
        var translated: [String] = []
        if let first = json[0].array {
            for segment in first { if let t = segment[0].string { translated.append(t) } }
        }
        let full = translated.joined()
        let parts = full.components(separatedBy: "\n")
        guard parts.count == lines.count else { return lines }
        return zip(lines, parts).map { var l = $0; l.translation = $1; return l }
    }
}
