import AppKit
import Combine

/// **Map Ranking — lo que suena**, para la isla.
///
/// En Windows se lee de los controles multimedia del sistema, que ven a
/// cualquier reproductor. En macOS el equivalente (MediaRemote) es privado y
/// desde macOS 15.4 ya no le contesta a apps de terceros, así que aquí se le
/// pregunta por AppleScript a los dos reproductores que lo permiten: Spotify y
/// Música. Lo que suena en un navegador (YouTube, etc.) no se ve.
///
/// macOS pide permiso la primera vez («Codenotch quiere controlar Spotify»);
/// negado, ese reproductor deja de consultarse hasta reabrir la app.
enum IslandPlayer: String, CaseIterable {
    case spotify
    case music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music:   return "com.apple.Music"
        }
    }

    /// El nombre para mostrar.
    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music:   return "Música"
        }
    }

    /// El nombre para AppleScript, que no se traduce.
    var scriptName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music:   return "Music"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Una lectura del reproductor.
struct NowPlaying: Equatable {
    var player: IslandPlayer
    var title: String
    var artist: String
    var album: String
    /// Segundos (0 si no se sabe).
    var duration: TimeInterval
    /// Segundos, a la hora `readAt`.
    var position: TimeInterval
    var readAt: Date
    var isPlaying: Bool
    /// Solo Spotify: la portada es una dirección https.
    var artworkURL: String?

    /// La canción, sin la posición: cambia solo al cambiar de canción.
    var trackKey: String {
        [player.rawValue, title, artist, album].joined(separator: "\u{1F}")
    }

    /// Dónde va la canción ahora, contando lo que avanzó desde la lectura.
    func elapsed(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let advanced = position + max(0, now.timeIntervalSince(readAt))
        return duration > 0 ? min(advanced, duration) : advanced
    }

    /// "1:05", "12:34".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Los guiones de AppleScript y la lectura de su respuesta.
enum IslandMusic {
    enum Command {
        case playPause, next, previous
    }

    /// Estado, canción, artista, álbum, duración, posición (y la portada en
    /// Spotify), todo de una vez. Con tiempo límite: un reproductor colgado no
    /// debe congelar la isla.
    static func stateScript(for player: IslandPlayer) -> String {
        let artwork = player == .spotify ? ", artwork url of t" : ""
        return """
        tell application "\(player.scriptName)"
            with timeout of 2 seconds
                set st to player state as string
                if st is "stopped" then return {st}
                try
                    set t to current track
                    return {st, name of t, artist of t, album of t, duration of t, player position\(artwork)}
                on error
                    return {st}
                end try
            end timeout
        end tell
        """
    }

    static func commandScript(_ command: Command, for player: IslandPlayer) -> String {
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next:      verb = "next track"
        case .previous:  verb = "previous track"
        }
        return "tell application \"\(player.scriptName)\" to \(verb)"
    }

    static func seekScript(to seconds: TimeInterval, for player: IslandPlayer) -> String {
        "tell application \"\(player.scriptName)\" to set player position to \(String(format: "%.2f", max(0, seconds)))"
    }

    /// La portada de Música: los bytes de la imagen tal cual.
    static let musicArtworkScript = """
    tell application "Music"
        with timeout of 3 seconds
            try
                return raw data of artwork 1 of current track
            end try
        end timeout
    end tell
    """

    /// La lista que devuelve `stateScript`, o nil si no hay canción.
    static func reading(from result: NSAppleEventDescriptor, player: IslandPlayer,
                        now: Date) -> NowPlaying? {
        guard result.numberOfItems >= 6,
              let state = result.atIndex(1)?.stringValue,
              state != "stopped",
              let title = result.atIndex(2)?.stringValue
        else { return nil }
        let rawDuration = number(result.atIndex(5))
        // Spotify da la duración en milisegundos; Música, en segundos.
        let duration = player == .spotify ? rawDuration / 1000 : rawDuration
        return NowPlaying(
            player: player,
            title: title,
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: max(0, duration),
            position: max(0, number(result.atIndex(6))),
            readAt: now,
            isPlaying: state == "playing",
            artworkURL: result.numberOfItems >= 7 ? result.atIndex(7)?.stringValue : nil
        )
    }

    /// Un número de AppleScript, venga como real, entero o texto.
    private static func number(_ descriptor: NSAppleEventDescriptor?) -> Double {
        guard let descriptor else { return 0 }
        let real = descriptor.doubleValue
        if real.isFinite, real != 0 { return real }
        let whole = descriptor.int32Value
        if whole != 0 { return Double(whole) }
        return descriptor.stringValue.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? 0
    }
}

/// Le pregunta a Spotify y a Música qué suena: cada segundo con la isla
/// abierta, cada dos plegada, y nada si ninguno de los dos está abierto.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var current: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// Un reproductor al que macOS no nos deja hablar (Automatización negada).
    @Published private(set) var blocked: IslandPlayer?

    /// La isla está encendida y la música también.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled { clear() }
            reschedule()
            if enabled { poll() }
        }
    }

    /// La isla está abierta: la barra de avance tiene que ir al día.
    var fastPolling = false {
        didSet {
            guard fastPolling != oldValue else { return }
            reschedule()
            if fastPolling { poll() }
        }
    }

    private var scripts: [IslandPlayer: NSAppleScript] = [:]
    private var denied: Set<IslandPlayer> = []
    private var timer: Timer?
    private var lastPlaying: IslandPlayer?
    private var artworkKey: String?
    private var artworkTask: Task<Void, Never>?

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        let interval: TimeInterval = fastPolling ? 1 : 2
        let poll = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll.tolerance = interval * 0.2
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    func poll() {
        guard enabled else { return }
        let readings = IslandPlayer.allCases
            .filter { !denied.contains($0) && $0.isRunning }
            .compactMap { read($0) }
        let chosen = readings.first(where: { $0.isPlaying })
            ?? readings.first(where: { $0.player == lastPlaying })
            ?? readings.first
        if let chosen, chosen.isPlaying { lastPlaying = chosen.player }
        update(to: chosen)
    }

    private func update(to reading: NowPlaying?) {
        guard let reading else {
            if current != nil { current = nil }
            return
        }
        // Misma canción y la posición donde se esperaba: no se publica, así la
        // isla no se vuelve a dibujar cada segundo por nada.
        if let current, current.trackKey == reading.trackKey,
           current.isPlaying == reading.isPlaying, current.duration == reading.duration,
           abs(current.elapsed(at: reading.readAt) - reading.position) < 1.5 {
            return
        }
        current = reading
        loadArtwork(for: reading)
    }

    private func read(_ player: IslandPlayer) -> NowPlaying? {
        guard let script = script(for: player) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: el usuario dijo que no en Privacidad › Automatización.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                denied.insert(player)
                blocked = player
            }
            return nil
        }
        if blocked == player { blocked = nil }
        return IslandMusic.reading(from: result, player: player, now: Date())
    }

    /// Compilado una vez y solo con el reproductor abierto: compilarlo con la
    /// app cerrada podría abrirla.
    private func script(for player: IslandPlayer) -> NSAppleScript? {
        if let script = scripts[player] { return script }
        guard let script = NSAppleScript(source: IslandMusic.stateScript(for: player)) else { return nil }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { return nil }
        scripts[player] = script
        return script
    }

    func send(_ command: IslandMusic.Command) {
        guard let player = current?.player else { return }
        run(IslandMusic.commandScript(command, for: player))
        refreshSoon()
    }

    /// Saltar a una parte de la canción (0…1), tocando la barra.
    func seek(toFraction fraction: Double) {
        guard let current, current.duration > 0 else { return }
        run(IslandMusic.seekScript(to: current.duration * min(max(fraction, 0), 1), for: current.player))
        refreshSoon()
    }

    private func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    /// El reproductor tarda un instante en cambiar de canción.
    private func refreshSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.poll()
        }
    }

    private func clear() {
        current = nil
        artwork = nil
        artworkKey = nil
        artworkTask?.cancel()
        // Volver a encender la música vuelve a preguntar a quien dijo que no.
        denied.removeAll()
        blocked = nil
    }

    /// Una vez por canción: la dirección de Spotify, o los bytes de Música.
    private func loadArtwork(for reading: NowPlaying) {
        let key = reading.trackKey
        guard artworkKey != key else { return }
        artworkKey = key
        artworkTask?.cancel()
        artwork = nil
        switch reading.player {
        case .spotify:
            guard let text = reading.artworkURL, let url = URL(string: text), url.scheme == "https"
            else { return }
            artworkTask = Task { @MainActor [weak self] in
                guard let fetched = try? await URLSession.shared.data(from: url),
                      !Task.isCancelled,
                      let image = NSImage(data: fetched.0),
                      let self, self.artworkKey == key
                else { return }
                self.artwork = image
            }
        case .music:
            guard let script = NSAppleScript(source: IslandMusic.musicArtworkScript) else { return }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil, let image = NSImage(data: result.data) else { return }
            artwork = image
        }
    }
}
