import AppKit
import Combine
import SwiftUI

/// **Map Ranking — el estado de la isla dinámica** que dibuja `IslandRootView`.
///
/// Reúne lo que la isla muestra: lo que suena, la letra, el sistema, el
/// Bluetooth y los anillos de IA, que son los del propio Codenotch: lee el
/// `menuModel` de `NotchFleet`, que recibe todas las lecturas igual que el
/// notch, así la isla y el notch nunca dicen cosas distintas.
@MainActor
final class IslandModel: ObservableObject {
    @Published var expanded = false
    /// Una app en pantalla completa: plegada, la isla no se ve.
    @Published var fullScreenHidden = false
    /// Escondida un instante para que no salga en una captura.
    @Published var hiddenForCapture = false
    @Published var notch: IslandLayout.Notch?
    @Published var menuBarHeight: CGFloat = 24
    @Published var screenWidth: CGFloat = 1440
    /// La letra en lugar de la portada (el botón de los controles). Recordado.
    @Published var showsLyrics: Bool {
        didSet { UserDefaults.standard.set(showsLyrics, forKey: "isla.verLetra") }
    }

    let settings: IslandSettings
    let usage: NotchViewModel
    let player = NowPlayingMonitor()
    let lyrics = IslandLyricsService()
    let system = IslandSystemMonitor()
    let bluetooth = IslandBluetoothMonitor()

    var onOpenSettings: (() -> Void)?
    var onRefreshProvider: ((String) async -> Void)?
    var onCapture: ((IslandCaptureKind) -> Void)?

    init(settings: IslandSettings, usage: NotchViewModel) {
        self.settings = settings
        self.usage = usage
        showsLyrics = UserDefaults.standard.bool(forKey: "isla.verLetra")
    }

    /// Hay algo para la columna de música: una canción, o el aviso de que
    /// macOS no deja leer el reproductor.
    var hasMusic: Bool {
        settings.media && (player.current != nil || player.blocked != nil)
    }

    /// El anillo que se ve plegada: el de Claude si está, si no el primero.
    var headlineSnapshot: ProviderSnapshot? {
        guard settings.aiRings else { return nil }
        return usage.snapshots.first { $0.id.hasPrefix("claude") } ?? usage.snapshots.first
    }

    var mode: IslandLayout.Mode {
        if expanded { return .expanded }
        return bluetooth.toast != nil && settings.toasts ? .toast : .collapsed
    }

    /// Los anillos de la isla abierta, en grupos: IA, sistema, Bluetooth.
    var cells: [IslandCell] {
        var cells: [IslandCell] = []
        if settings.aiRings { cells += usage.snapshots.map { IslandCell.ai($0) } }
        if settings.system {
            let reading = system.reading
            var memory: Double?
            if let reading, reading.memoryTotal > 0 { memory = reading.memoryFraction }
            cells.append(.cpu(reading?.cpu))
            cells.append(.memory(memory))
            if let disks = reading?.disks, !disks.isEmpty {
                cells += disks.map { IslandCell.disk($0) }
            } else {
                cells.append(.diskPlaceholder)
            }
        }
        if settings.bluetooth { cells += bluetooth.devices.map { IslandCell.bluetooth($0) } }
        return cells
    }

    var layoutInput: IslandLayout.Input {
        IslandLayout.Input(mode: mode, notch: notch, menuBarHeight: menuBarHeight,
                           screenWidth: screenWidth, hasMusic: hasMusic,
                           hasCompactContent: hasMusic || headlineSnapshot != nil,
                           cells: cells.count)
    }

    func refreshProvider(_ id: String) {
        guard let onRefreshProvider else { return }
        Task { @MainActor in await onRefreshProvider(id) }
    }
}

/// Un anillo de la isla abierta.
enum IslandCell: Identifiable {
    case ai(ProviderSnapshot)
    case cpu(Double?)
    case memory(Double?)
    case disk(IslandDisk)
    case diskPlaceholder
    case bluetooth(IslandBTDevice)

    var id: String {
        switch self {
        case .ai(let snapshot):     return "ai." + snapshot.id
        case .cpu:                  return "sys.cpu"
        case .memory:               return "sys.ram"
        case .disk(let disk):       return "sys.disk." + disk.id
        case .diskPlaceholder:      return "sys.disk"
        case .bluetooth(let device): return "bt." + device.id
        }
    }
}

/// La ventana de la isla: sin bordes, sobre la barra de menús y en todos los
/// escritorios, y sin robar el foco al tocarla, como el notch.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // La isla es oscura siempre: los colores de la app que cambian con el
        // modo claro u oscuro (el texto de los anillos) se leen en oscuro.
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// La ventana es mucho más grande que la isla; fuera de la isla, los clics
/// pasan a lo que haya debajo.
final class IslandHostingView: NSHostingView<IslandRootView> {
    /// Donde está la isla, con el origen arriba a la izquierda.
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// El primer clic ya toca el botón: la isla nunca es la ventana activa.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// **Map Ranking — la isla dinámica de Codenotch en la Mac.**
///
/// Arriba al centro de la pantalla con la barra de menús. En una Mac con
/// notch se funde con él (plegada es negra y del alto del notch, con alas a
/// los lados); sin notch es una cápsula en la barra de menús. Al pasar el
/// mouse se abre: música a la izquierda (30 %) y anillos a la derecha (70 %).
@MainActor
final class IslandController {
    let model: IslandModel
    var onOpenSettings: (() -> Void)? {
        get { model.onOpenSettings }
        set { model.onOpenSettings = newValue }
    }
    var onRefreshProvider: ((String) async -> Void)? {
        get { model.onRefreshProvider }
        set { model.onRefreshProvider = newValue }
    }
    /// La isla se abrió: los números se van a leer (ver `UsageStore.refreshBecauseSomeoneIsLooking`).
    var onLook: (() -> Void)?

    private var settings: IslandSettings { model.settings }
    private var panel: IslandPanel?
    private var hosting: IslandHostingView?
    private var cancellables = Set<AnyCancellable>()
    private var running: Set<AnyCancellable> = []
    private var mouseMonitors: [Any] = []
    private var cursorTimer: Timer?
    private var fullScreenTimer: Timer?
    private var collapseWork: DispatchWorkItem?

    /// Hover in es inmediato; al salir espera un poco, por si el puntero solo
    /// se resbaló del borde.
    static let foldGrace: TimeInterval = 0.35
    static let motion = Animation.spring(response: 0.42, dampingFraction: 0.82)

    init(settings: IslandSettings, usage: NotchViewModel) {
        model = IslandModel(settings: settings, usage: usage)
        model.onCapture = { [weak self] kind in self?.capture(kind) }
    }

    /// Si con la isla encendida el notch clásico se oculta: solo cuando los dos
    /// ocuparían el borde de arriba.
    nonisolated static func replacesNotch(enabled: Bool, edge: NotchEdge) -> Bool {
        enabled && edge == .top
    }

    func start() {
        settings.$enabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setRunning(on) }
            .store(in: &cancellables)
    }

    // MARK: - Encender y apagar

    private func setRunning(_ on: Bool) {
        if on {
            guard running.isEmpty else { return }
            if panel == nil { makePanel() }
            place()
            panel?.orderFrontRegardless()
            bindSettings()
            watchCursor()
            watchFullScreen()
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.place() }
                .store(in: &running)
        } else {
            running.removeAll()
            for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
            mouseMonitors.removeAll()
            cursorTimer?.invalidate()
            cursorTimer = nil
            fullScreenTimer?.invalidate()
            fullScreenTimer = nil
            collapseWork?.cancel()
            collapseWork = nil
            model.expanded = false
            model.player.enabled = false
            model.lyrics.enabled = false
            model.system.active = false
            model.bluetooth.enabled = false
            panel?.orderOut(nil)
        }
    }

    /// Cada ajuste apaga o enciende lo suyo: lo apagado deja de leerse.
    private func bindSettings() {
        settings.$media.combineLatest(settings.$lyrics)
            .receive(on: RunLoop.main)
            .sink { [weak self] media, lyrics in
                guard let self else { return }
                self.model.player.enabled = media
                self.model.lyrics.enabled = media && lyrics
                self.model.lyrics.track(self.model.player.current)
            }
            .store(in: &running)
        settings.$bluetooth
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.model.bluetooth.enabled = on }
            .store(in: &running)
        settings.$toasts
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.model.bluetooth.toastsEnabled = on }
            .store(in: &running)
        settings.$system
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSystemPolling() }
            .store(in: &running)
        settings.$hidesInFullScreen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkFullScreen() }
            .store(in: &running)
        model.player.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in self?.model.lyrics.track(playing) }
            .store(in: &running)

        // Cualquier cambio puede cambiar el tamaño de la isla: el área que
        // atiende el puntero se recalcula con él.
        Publishers.MergeMany([
            model.objectWillChange.eraseToAnyPublisher(),
            settings.objectWillChange.eraseToAnyPublisher(),
            model.player.objectWillChange.eraseToAnyPublisher(),
            model.system.objectWillChange.eraseToAnyPublisher(),
            model.bluetooth.objectWillChange.eraseToAnyPublisher(),
            model.usage.objectWillChange.eraseToAnyPublisher(),
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateInteractiveRect() }
        .store(in: &running)
    }

    // MARK: - Ventana

    private func makePanel() {
        let size = IslandLayout.panelSize
        let panel = IslandPanel(contentRect: CGRect(origin: .zero, size: size))
        let hosting = IslandHostingView(rootView: IslandRootView(model: model))
        // El tamaño de la ventana lo decide la isla, no SwiftUI.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NotchContainerView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        self.hosting = hosting
    }

    /// La pantalla con la barra de menús.
    private static func homeScreen() -> NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    private func place() {
        guard let panel, let screen = Self.homeScreen() else { return }
        model.notch = screen.hardwareNotch.map { IslandLayout.Notch(width: $0.width, height: $0.height) }
        model.menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        model.screenWidth = screen.frame.width
        let size = IslandLayout.panelSize
        let origin = CGPoint(x: (screen.frame.midX - size.width / 2).rounded(),
                             y: screen.frame.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        updateInteractiveRect()
    }

    private var islandRect: CGRect {
        IslandLayout.frame(model.layoutInput)
    }

    private func updateInteractiveRect() {
        hosting?.interactiveRect = islandRect
        cursorMoved()
    }

    // MARK: - Hover

    /// Igual que el notch: un monitor global ve al puntero llegar mientras la
    /// ventana ignora el mouse, uno local lo ve irse, y un sondeo lento cubre
    /// el puntero quieto bajo una isla que cambió de tamaño.
    private func watchCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.cursorMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func pointerInside() -> Bool {
        guard let panel else { return false }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        // Abierta, un margen: el puntero no tiene que quedar exacto en el borde.
        let slop: CGFloat = model.expanded ? 8 : 2
        var rect = islandRect.insetBy(dx: -slop, dy: -slop)
        // Pegada al borde de arriba, la fila 0 de la pantalla también cuenta.
        rect.origin.y = min(rect.origin.y, 0)
        return rect.contains(local)
    }

    private func cursorMoved() {
        guard let panel, !running.isEmpty, !model.hiddenForCapture else { return }
        let inside = pointerInside()
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.expanded { setExpanded(true) }
        } else if model.expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.pointerInside() { self.setExpanded(false) }
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldGrace, execute: work)
        }
    }

    private func setExpanded(_ open: Bool) {
        guard model.expanded != open else { return }
        withAnimation(Self.motion) { model.expanded = open }
        model.player.fastPolling = open
        updateSystemPolling()
        if open {
            model.bluetooth.poll()
            onLook?()
        }
        hosting?.interactiveRect = islandRect
    }

    private func updateSystemPolling() {
        model.system.active = model.expanded && settings.system && !running.isEmpty
    }

    // MARK: - Pantalla completa

    private func watchFullScreen() {
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullScreen() }
        }
        poll.tolerance = 0.5
        RunLoop.main.add(poll, forMode: .common)
        fullScreenTimer = poll
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkFullScreen() }
            .store(in: &running)
    }

    private func checkFullScreen() {
        let hide = settings.hidesInFullScreen
            && FullScreenDetector.isFullScreenAppFrontmost(on: Self.homeScreen())
        if hide != model.fullScreenHidden {
            withAnimation(.easeOut(duration: 0.2)) { model.fullScreenHidden = hide }
        }
    }

    // MARK: - Capturas

    private func capture(_ kind: IslandCaptureKind) {
        if kind != .record { setExpanded(false) }
        IslandCapture.run(kind) { [weak self] hidden in
            guard let self else { return }
            self.model.hiddenForCapture = hidden
            if hidden {
                self.panel?.orderOut(nil)
            } else if !self.running.isEmpty {
                self.panel?.orderFrontRegardless()
            }
        }
    }
}
