import AppKit

/// **Map Ranking — capturas** desde la isla, como `capture.rs` en Windows:
/// pantalla completa sin la isla (PNG guardado donde macOS guarda las
/// capturas y copiado al portapapeles), recorte, y grabación con la barra de
/// Captura de pantalla de macOS (la misma de ⇧⌘5).
///
/// Las dos primeras usan `screencapture`, así que macOS pide a Codenotch el
/// permiso de Grabación de pantalla la primera vez; sin él la imagen sale solo
/// con el fondo de pantalla. Grabar no lo necesita: lo hace la app del sistema.
enum IslandCaptureKind: Equatable {
    case fullScreen, region, record
}

@MainActor
enum IslandCapture {
    /// `setHidden` esconde la isla mientras se toma la foto.
    static func run(_ kind: IslandCaptureKind, setHidden: @escaping @MainActor (Bool) -> Void) {
        switch kind {
        case .record:
            let app = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        case .fullScreen, .region:
            let file = saveFolder().appendingPathComponent(fileName(at: Date()))
            let arguments = kind == .region ? ["-i", "-x", file.path] : ["-x", "-t", "png", file.path]
            setHidden(true)
            Task { @MainActor in
                // Que la isla termine de desaparecer antes de la foto.
                try? await Task.sleep(nanoseconds: 220_000_000)
                screencapture(arguments) {
                    setHidden(false)
                    // Un recorte cancelado con Esc no deja archivo.
                    if FileManager.default.fileExists(atPath: file.path) { copyToPasteboard(file) }
                }
            }
        }
    }

    private static func screencapture(_ arguments: [String], then done: @escaping @MainActor () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { _ in
            Task { @MainActor in done() }
        }
        do {
            try process.run()
        } catch {
            done()
        }
    }

    private static func copyToPasteboard(_ file: URL) {
        guard let image = NSImage(contentsOf: file) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
    }

    /// Donde el usuario eligió guardar las capturas (⇧⌘5 › Opciones), o el
    /// Escritorio, que es lo de fábrica.
    static func saveFolder() -> URL {
        if let chosen = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (chosen as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// "Captura de pantalla 2026-10-30 a las 1.23.45.png", como las de macOS en español.
    nonisolated static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'a las' H.mm.ss"
        return "Captura de pantalla \(formatter.string(from: date)).png"
    }
}
