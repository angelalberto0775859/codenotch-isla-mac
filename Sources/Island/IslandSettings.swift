import AppKit
import Combine
import SwiftUI

/// **Map Ranking — los ajustes de la isla dinámica**, en `UserDefaults` bajo
/// `isla.*`.
///
/// Aparte de `Preferences` a propósito: la isla es un agregado de este build y
/// vive entera en `Sources/Island`, así el resto del código queda igual al
/// original y se puede seguir integrando sin conflictos. Los textos están en
/// español directamente, como en la versión de Windows.
@MainActor
final class IslandSettings: ObservableObject {
    static let shared = IslandSettings(defaults: .standard)

    /// La isla arriba al centro. Encendida, el notch clásico del borde de
    /// arriba se oculta (los de los otros bordes se quedan).
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// Lo que suena en Spotify o Música.
    @Published var media: Bool { didSet { defaults.set(media, forKey: Keys.media) } }
    /// La letra de LRCLIB en lugar de la portada.
    @Published var lyrics: Bool { didSet { defaults.set(lyrics, forKey: Keys.lyrics) } }
    /// Los anillos de uso de IA (los mismos del notch).
    @Published var aiRings: Bool { didSet { defaults.set(aiRings, forKey: Keys.aiRings) } }
    /// CPU, RAM y disco.
    @Published var system: Bool { didSet { defaults.set(system, forKey: Keys.system) } }
    /// La batería de los dispositivos Bluetooth conectados.
    @Published var bluetooth: Bool { didSet { defaults.set(bluetooth, forKey: Keys.bluetooth) } }
    /// El aviso plegado al conectarse un dispositivo.
    @Published var toasts: Bool { didSet { defaults.set(toasts, forKey: Keys.toasts) } }
    /// Los botones de captura.
    @Published var tools: Bool { didSet { defaults.set(tools, forKey: Keys.tools) } }
    /// Vidrio (Liquid Glass en macOS 26, desenfoque del sistema antes); apagado,
    /// la isla es del color liso.
    @Published var glass: Bool { didSet { defaults.set(glass, forKey: Keys.glass) } }
    /// Se esconde plegada mientras una app ocupa la pantalla completa.
    @Published var hidesInFullScreen: Bool {
        didSet { defaults.set(hidesInFullScreen, forKey: Keys.hidesInFullScreen) }
    }
    /// "#RRGGBB", o vacío para el tono oscuro de siempre.
    @Published var color: String { didSet { defaults.set(color, forKey: Keys.color) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        enabled = bool(Keys.enabled, true)
        media = bool(Keys.media, true)
        lyrics = bool(Keys.lyrics, true)
        aiRings = bool(Keys.aiRings, true)
        system = bool(Keys.system, true)
        bluetooth = bool(Keys.bluetooth, true)
        toasts = bool(Keys.toasts, true)
        tools = bool(Keys.tools, true)
        glass = bool(Keys.glass, true)
        hidesInFullScreen = bool(Keys.hidesInFullScreen, true)
        color = IslandColor.normalized(defaults.string(forKey: Keys.color) ?? "") ?? ""
    }

    private enum Keys {
        static let enabled = "isla.activa"
        static let media = "isla.musica"
        static let lyrics = "isla.letras"
        static let aiRings = "isla.anillosIA"
        static let system = "isla.sistema"
        static let bluetooth = "isla.bluetooth"
        static let toasts = "isla.avisos"
        static let tools = "isla.capturas"
        static let glass = "isla.vidrio"
        static let hidesInFullScreen = "isla.ocultarEnPantallaCompleta"
        static let color = "isla.color"
    }
}

/// El color propio de la isla: un hexadecimal "#RRGGBB" guardado como texto.
enum IslandColor {
    /// El tono de la isla sin color propio: casi negro, como la de Windows.
    static let base: UInt32 = 0x141416

    static let presets: [(name: String, hex: String)] = [
        ("Grafito", "#2C2C2E"),
        ("Medianoche", "#14213D"),
        ("Morado", "#3A1C5C"),
        ("Bosque", "#12372A"),
        ("Vino", "#4A1020"),
        ("Ámbar", "#5A3A00"),
    ]

    /// "#RRGGBB" en mayúsculas, o nil si el texto no es un color.
    static func normalized(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }

    static func value(_ text: String) -> UInt32? {
        guard let hex = normalized(text) else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    /// El color guardado, o nil sin color propio.
    static func color(_ text: String) -> Color? {
        value(text).map { Color(hex: $0) }
    }

    /// Un color del selector como "#RRGGBB".
    static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                      byte(rgb.blueComponent))
    }
}
