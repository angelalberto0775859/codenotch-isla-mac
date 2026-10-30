import CoreGraphics

/// **Map Ranking — la geometría de la isla**, en puntos y sin AppKit.
///
/// Una sola fuente para tres lectores: la vista (el marco que dibuja), el
/// controlador (dónde atiende el puntero, para que fuera de la isla los clics
/// pasen a lo que hay debajo) y las pruebas. Si cada uno calculara el tamaño
/// por su cuenta, el área que responde al mouse y la que se ve se separarían.
enum IslandLayout {
    /// El recorte de la pantalla (MacBook con notch), en puntos.
    struct Notch: Equatable {
        var width: CGFloat
        var height: CGFloat
    }

    enum Mode: Equatable {
        /// Plegada: la cápsula con lo importante.
        case collapsed
        /// Plegada pero más ancha un momento: un dispositivo Bluetooth se conectó.
        case toast
        /// Abierta al pasar el mouse: música a la izquierda, anillos a la derecha.
        case expanded
    }

    struct Input: Equatable {
        var mode: Mode
        var notch: Notch?
        /// Alto de la barra de menús de esa pantalla (0 si se oculta sola).
        var menuBarHeight: CGFloat
        var screenWidth: CGFloat
        /// Hay una canción (o un aviso de permisos) para la columna de música.
        var hasMusic: Bool
        /// Hay algo que mostrar plegada: una canción o un anillo.
        var hasCompactContent: Bool
        /// Anillos en la isla abierta (IA + sistema + Bluetooth).
        var cells: Int
    }

    // MARK: - Medidas

    /// La ventana transparente donde vive la isla. Más grande que cualquier
    /// isla: fuera de la isla los clics la atraviesan.
    static let panelSize = CGSize(width: 860, height: 440)

    static let openWidthWithMusic: CGFloat = 680
    static let openWidth: CGFloat = 500
    static let padding: CGFloat = 16
    static let columnGap: CGFloat = 18
    /// Fila de botones arriba cuando la pantalla no tiene notch (con notch,
    /// esa fila es la franja del propio notch).
    static let headerHeight: CGFloat = 32
    static let headerGap: CGFloat = 6
    static let bottomPadding: CGFloat = 14
    /// Portada (o letra), barra y controles.
    static let musicHeight: CGFloat = 132
    /// Lo que la música le cede a los anillos: el 30 %.
    static let musicShare: CGFloat = 0.3

    static let cellWidth: CGFloat = 60
    static let cellHeight: CGFloat = 70
    static let cellSpacing: CGFloat = 8
    static let maxRows = 3
    /// Alto del renglón de "sin anillos" cuando no hay ninguno que mostrar.
    static let emptyRingsHeight: CGFloat = 40

    /// Cada ala a los lados del notch físico, plegada.
    static let wing: CGFloat = 74
    /// Y durante el aviso de Bluetooth.
    static let toastWing: CGFloat = 150
    /// Cápsula sin notch físico.
    static let capsuleWidthWithMusic: CGFloat = 310
    static let capsuleWidth: CGFloat = 190
    static let emptyCapsuleWidth: CGFloat = 120
    static let toastCapsuleWidth: CGFloat = 350

    static let expandedRadius: CGFloat = 26
    /// La curva con que la isla sale del borde de la pantalla, como el notch.
    static let flare: CGFloat = 8

    // MARK: - Cálculos

    /// Alto de la cápsula sin notch: lo de la barra de menús, sin pasarse.
    static func capsuleHeight(menuBarHeight: CGFloat) -> CGFloat {
        guard menuBarHeight > 0 else { return 28 }
        return min(30, max(22, menuBarHeight - 2))
    }

    /// Distancia del borde de arriba de la pantalla a la isla: cero pegada al
    /// notch; centrada en la barra de menús si no hay notch.
    static func topGap(_ input: Input) -> CGFloat {
        guard input.notch == nil else { return 0 }
        let bar = input.menuBarHeight > 0 ? input.menuBarHeight : 24
        return max(1, ((bar - capsuleHeight(menuBarHeight: input.menuBarHeight)) / 2).rounded(.down))
    }

    /// El ancho de la isla abierta, sin salirse de la pantalla.
    static func expandedWidth(_ input: Input) -> CGFloat {
        var width = input.hasMusic ? openWidthWithMusic : openWidth
        if let notch = input.notch { width = max(width, notch.width + 300) }
        return min(width, max(320, input.screenWidth - 24))
    }

    /// El ancho de la columna de música (30 % de lo útil).
    static func musicWidth(totalWidth: CGFloat) -> CGFloat {
        ((totalWidth - 2 * padding - columnGap) * musicShare).rounded(.down)
    }

    /// Lo que queda para los anillos.
    static func ringsWidth(_ input: Input) -> CGFloat {
        let total = expandedWidth(input)
        let inner = total - 2 * padding
        return input.hasMusic ? inner - musicWidth(totalWidth: total) - columnGap : inner
    }

    static func columns(_ input: Input) -> Int {
        max(1, Int(((ringsWidth(input) + cellSpacing) / (cellWidth + cellSpacing)).rounded(.down)))
    }

    static func rows(_ input: Input) -> Int {
        guard input.cells > 0 else { return 0 }
        let perRow = columns(input)
        return min(maxRows, (input.cells + perRow - 1) / perRow)
    }

    /// Cuántos anillos caben (lo demás no se dibuja).
    static func visibleCells(_ input: Input) -> Int {
        min(input.cells, maxRows * columns(input))
    }

    static func ringsHeight(_ input: Input) -> CGFloat {
        let count = rows(input)
        guard count > 0 else { return emptyRingsHeight }
        return CGFloat(count) * cellHeight + CGFloat(count - 1) * cellSpacing
    }

    /// La franja de arriba de la isla abierta: la del notch, o una fila propia.
    static func header(_ input: Input) -> CGFloat {
        input.notch?.height ?? headerHeight
    }

    static func size(_ input: Input) -> CGSize {
        switch input.mode {
        case .expanded:
            let content = max(input.hasMusic ? musicHeight : 0, ringsHeight(input))
            return CGSize(width: expandedWidth(input),
                          height: header(input) + headerGap + content + bottomPadding)
        case .collapsed, .toast:
            if let notch = input.notch {
                let side: CGFloat
                if input.mode == .toast { side = toastWing }
                else { side = input.hasCompactContent ? wing : 0 }
                return CGSize(width: notch.width + 2 * side + (side > 0 ? 2 * flare : 0),
                              height: notch.height)
            }
            let width: CGFloat
            if input.mode == .toast { width = toastCapsuleWidth }
            else if input.hasMusic { width = capsuleWidthWithMusic }
            else { width = input.hasCompactContent ? capsuleWidth : emptyCapsuleWidth }
            return CGSize(width: width, height: capsuleHeight(menuBarHeight: input.menuBarHeight))
        }
    }

    /// Dónde está la isla dentro de la ventana, con el origen arriba a la
    /// izquierda (como la vista de SwiftUI, que está volteada).
    static func frame(_ input: Input, in panel: CGSize = panelSize) -> CGRect {
        let island = size(input)
        return CGRect(x: ((panel.width - island.width) / 2).rounded(), y: topGap(input),
                      width: island.width, height: island.height)
    }

    /// Las curvas de la isla: la salida del borde (solo pegada al notch), la
    /// esquina de arriba (solo sin notch) y la de abajo.
    struct Radii: Equatable {
        var flare: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    static func radii(_ input: Input) -> Radii {
        let island = size(input)
        if input.notch != nil {
            let bottom = input.mode == .expanded ? expandedRadius : min(14, island.height * 0.4)
            return Radii(flare: flare, top: 0, bottom: bottom)
        }
        let radius = input.mode == .expanded ? expandedRadius : island.height / 2
        return Radii(flare: 0, top: radius, bottom: radius)
    }
}
