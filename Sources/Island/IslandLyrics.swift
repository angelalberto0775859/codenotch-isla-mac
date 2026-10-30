import Combine
import Foundation

/// **Map Ranking — letras de canciones** para la isla: la canción que suena se
/// busca en LRCLIB (lrclib.net, libre y sin cuenta), con el tiempo de cada
/// línea cuando lo tiene, para seguirla en lugar de la portada.
///
/// Es lo único de la isla que sale a internet: título, artista, álbum y
/// duración de la canción, una vez por canción y solo con «Letras» encendido.
/// Las respuestas se guardan en memoria. Igual que `lyrics.rs` en Windows.
struct IslandLyricLine: Equatable {
    var ms: Int
    var text: String
}

struct IslandLyrics: Equatable {
    enum Status: Equatable {
        case loading
        case synced
        case plain
        case instrumental
        /// No está en LRCLIB, o no hubo conexión.
        case none
    }

    /// La canción (`NowPlaying.trackKey`), para mostrarla solo con la suya.
    var trackKey: String
    var status: Status
    var lines: [IslandLyricLine] = []
    var plain: String = ""

    /// La línea que suena a los `ms` de la canción; nil antes de la primera.
    func lineIndex(at ms: Int) -> Int? {
        guard let first = lines.first, ms >= first.ms else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].ms <= ms { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

enum LRC {
    /// Líneas "[01:02.34] palabras" (una línea puede traer varios tiempos)
    /// como [ms, palabras], en orden. Las etiquetas [ar:…], [ti:…] no son líneas.
    static func parse(_ text: String) -> [IslandLyricLine] {
        var out: [(order: Int, line: IslandLyricLine)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Int] = []
            while rest.first == "[" {
                guard let close = rest.firstIndex(of: "]"),
                      let ms = stamp(String(rest[rest.index(after: rest.startIndex)..<close]))
                else { break }
                stamps.append(ms)
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for ms in stamps {
                out.append((out.count, IslandLyricLine(ms: ms, text: words)))
            }
        }
        return out.sorted { ($0.line.ms, $0.order) < ($1.line.ms, $1.order) }.map(\.line)
    }

    /// "01:02.34" → 62340.
    static func stamp(_ text: String) -> Int? {
        guard let colon = text.firstIndex(of: ":"),
              let minutes = Int(text[..<colon].trimmingCharacters(in: .whitespaces)),
              let seconds = Double(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
              minutes >= 0, seconds >= 0, seconds.isFinite
        else { return nil }
        return minutes * 60_000 + Int((seconds * 1000).rounded())
    }
}

/// Una respuesta de `/api/search`.
struct LRCLibEntry: Decodable, Equatable {
    var duration: Double?
    var albumName: String?
    var plainLyrics: String?
    var syncedLyrics: String?
    var instrumental: Bool?
}

enum LRCLib {
    static let endpoint = "https://lrclib.net/api/search"
    static let agent = "CodenotchIsla/1.0 (Codenotch for macOS, Map Ranking build)"

    /// Primero la que trae tiempos, luego la del mismo álbum, luego la de
    /// duración más cercana (a 10 s o menos, si se sabe la duración).
    static func best(_ entries: [LRCLibEntry], album: String, durationMs: Int) -> LRCLibEntry? {
        let seconds = Double(durationMs) / 1000
        func off(_ entry: LRCLibEntry) -> Double {
            entry.duration.map { abs($0 - seconds) } ?? 999
        }
        func rank(_ entry: LRCLibEntry) -> (Int, Int, Int) {
            let synced = !(entry.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sameAlbum = !album.isEmpty
                && (entry.albumName ?? "").caseInsensitiveCompare(album) == .orderedSame
            return (synced ? 0 : 1, sameAlbum ? 0 : 1, Int(off(entry) * 10))
        }
        return entries
            .filter { durationMs == 0 || off($0) <= 10 }
            .min { rank($0) < rank($1) }
    }

    static func lyrics(trackKey: String, entry: LRCLibEntry?) -> IslandLyrics {
        var lyrics = IslandLyrics(trackKey: trackKey, status: .none)
        guard let entry else { return lyrics }
        if entry.instrumental == true {
            lyrics.status = .instrumental
            return lyrics
        }
        if let synced = entry.syncedLyrics { lyrics.lines = LRC.parse(synced) }
        lyrics.plain = (entry.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lyrics.lines.isEmpty { lyrics.status = .synced }
        else if !lyrics.plain.isEmpty { lyrics.status = .plain }
        return lyrics
    }

    /// La mejor entrada para la canción; nil si LRCLIB no la tiene, error si
    /// no hubo conexión (eso no se recuerda: se vuelve a preguntar después).
    static func fetch(title: String, artist: String, album: String,
                      durationMs: Int) async -> Result<LRCLibEntry?, Error> {
        guard var components = URLComponents(string: endpoint) else { return .success(nil) }
        var items = [URLQueryItem(name: "track_name", value: title.trimmingCharacters(in: .whitespaces))]
        let artistName = artist.trimmingCharacters(in: .whitespaces)
        if !artistName.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artistName)) }
        components.queryItems = items
        guard let url = components.url else { return .success(nil) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(URLError(.badServerResponse))
            }
            let entries = try JSONDecoder().decode([LRCLibEntry].self, from: data)
            return .success(best(entries, album: album, durationMs: durationMs))
        } catch {
            return .failure(error)
        }
    }
}

/// Busca la letra cuando cambia la canción y la guarda (hasta 200 canciones).
@MainActor
final class IslandLyricsService: ObservableObject {
    @Published private(set) var current: IslandLyrics?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            wanted = nil
            task?.cancel()
            if !enabled { current = nil }
        }
    }

    private var wanted: String?
    private var cache: [String: IslandLyrics] = [:]
    private var task: Task<Void, Never>?
    static let cacheLimit = 200

    func track(_ playing: NowPlaying?) {
        guard enabled, let playing,
              !playing.title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        let key = playing.trackKey
        guard wanted != key else { return }
        wanted = key
        if let hit = cache[key] {
            current = hit
            return
        }
        current = IslandLyrics(trackKey: key, status: .loading)
        task?.cancel()
        let title = playing.title
        let artist = playing.artist
        let album = playing.album
        let durationMs = Int(playing.duration * 1000)
        task = Task { @MainActor [weak self] in
            let found = await LRCLib.fetch(title: title, artist: artist, album: album,
                                           durationMs: durationMs)
            guard let self, !Task.isCancelled else { return }
            switch found {
            case .success(let entry):
                let lyrics = LRCLib.lyrics(trackKey: key, entry: entry)
                if self.cache.count >= Self.cacheLimit { self.cache.removeAll() }
                self.cache[key] = lyrics
                if self.wanted == key { self.current = lyrics }
            case .failure:
                // Sin conexión no se guarda en la memoria: la próxima vez que
                // suene la canción se vuelve a buscar.
                if self.wanted == key { self.current = IslandLyrics(trackKey: key, status: .none) }
            }
        }
    }
}
