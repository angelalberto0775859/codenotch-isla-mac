import SwiftUI

/// **Map Ranking — la pestaña «Isla dinámica» de Configuración**, en español
/// como la de Windows. Cada interruptor apaga también lo que lee: lo apagado
/// deja de consultarse.
struct IslandSettingsPane: View {
    @ObservedObject var settings: IslandSettings

    var body: some View {
        Form {
            Section {
                toggle("Mostrar la isla dinámica", $settings.enabled)
                caption("Arriba al centro de la pantalla con la barra de menús. En una Mac con notch se funde con él; sin notch es una cápsula en la barra de menús. Pasa el mouse para abrirla. Si el notch clásico está en el borde de arriba, la isla lo reemplaza; en otro borde, conviven.")
                toggle("Ocultarla en pantalla completa", $settings.hidesInFullScreen)
            } header: {
                Text(verbatim: "Isla")
            }

            Section {
                toggle("Música (Spotify y Música)", $settings.media)
                caption("Canción, portada, avance y controles. macOS pide permiso la primera vez («Codenotch quiere controlar Spotify»). Lo que suena en el navegador no se puede leer: desde macOS 15.4 Apple no deja a otras apps ver los controles multimedia del sistema.")
                toggle("Letras de canciones", $settings.lyrics)
                    .disabled(!settings.media)
                caption("El botón de letra en los controles cambia la portada por la letra, línea por línea. Se busca en LRCLIB (lrclib.net): es lo único que sale a internet, una vez por canción.")
                toggle("Anillos de IA", $settings.aiRings)
                toggle("Sistema: CPU, RAM y disco", $settings.system)
                caption("Se lee solo con la isla abierta. Toca un anillo para leer de nuevo.")
                toggle("Bluetooth: batería de tus dispositivos", $settings.bluetooth)
                toggle("Aviso al conectar un dispositivo", $settings.toasts)
                    .disabled(!settings.bluetooth)
                caption("macOS pide el permiso de Bluetooth la primera vez. La batería sale en audífonos de Apple y en teclados, ratones y trackpads que la publican.")
                toggle("Botones de captura", $settings.tools)
                caption("Pantalla completa (sin la isla, al portapapeles y a la carpeta de capturas), recorte y grabación con la barra de ⇧⌘5. Las dos primeras piden el permiso de Grabación de pantalla.")
            } header: {
                Text(verbatim: "Qué mostrar")
            }

            Section {
                toggle("Vidrio", $settings.glass)
                caption(glassCaption)
                colorRow
            } header: {
                Text(verbatim: "Estilo")
            }
        }
        .formStyle(.grouped)
    }

    private var glassCaption: String {
        if #available(macOS 26.0, *) {
            return "Liquid Glass oscuro. Apagado, la isla es del color liso. Plegada sobre el notch físico siempre es negra, para fundirse con él."
        }
        return "Desenfoque de lo que hay detrás. Apagado, la isla es del color liso. Plegada sobre el notch físico siempre es negra, para fundirse con él."
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Color")
            HStack(spacing: 8) {
                swatch(name: "Oscuro", hex: "")
                ForEach(IslandColor.presets, id: \.hex) { preset in
                    swatch(name: preset.name, hex: preset.hex)
                }
                Spacer(minLength: 8)
                ColorPicker(selection: customColor, supportsOpacity: false) {
                    Text(verbatim: "Personalizado")
                }
                .fixedSize()
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { IslandColor.color(settings.color) ?? Color(hex: IslandColor.base) },
            set: { settings.color = IslandColor.hex(from: $0) ?? "" }
        )
    }

    private func swatch(name: String, hex: String) -> some View {
        let selected = settings.color == hex
        return Circle()
            .fill(IslandColor.color(hex) ?? Color(hex: IslandColor.base))
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.white.opacity(selected ? 0.95 : 0.25),
                                     lineWidth: selected ? 2 : 1))
            .contentShape(Circle())
            .onTapGesture { settings.color = hex }
            .help(name)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityAddTraits(.isButton)
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Text(verbatim: title) }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
