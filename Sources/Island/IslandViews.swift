import AppKit
import SwiftUI

/// **Map Ranking — la isla dinámica dibujada.** Plegada: la cápsula con la
/// canción, el anillo de Claude o el aviso de Bluetooth. Abierta: la música a
/// la izquierda (30 %) y los anillos a la derecha (70 %). Los tamaños salen de
/// `IslandLayout`, el mismo cálculo que usa el controlador para el mouse.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var settings: IslandSettings
    @ObservedObject private var usage: NotchViewModel
    @ObservedObject private var player: NowPlayingMonitor
    @ObservedObject private var system: IslandSystemMonitor
    @ObservedObject private var bluetooth: IslandBluetoothMonitor

    init(model: IslandModel) {
        self.model = model
        settings = model.settings
        usage = model.usage
        player = model.player
        system = model.system
        bluetooth = model.bluetooth
    }

    var body: some View {
        let input = model.layoutInput
        let size = IslandLayout.size(input)
        let radii = IslandLayout.radii(input)
        let shape = IslandShape(flare: radii.flare, top: radii.top, bottom: radii.bottom)
        // Pegada al notch físico y plegada, la isla es negra: así se funde con él.
        let black = input.notch != nil && !model.expanded
        let hidden = model.hiddenForCapture || (model.fullScreenHidden && !model.expanded)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandSurface(shape: shape, glass: settings.glass,
                              tint: IslandColor.color(settings.color), black: black)
                if model.expanded {
                    IslandExpanded(model: model, input: input)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                } else {
                    IslandCompact(model: model, input: input)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 18, y: 8)
            .opacity(hidden ? 0 : 1)
            .padding(.top, IslandLayout.topGap(input))
            Spacer(minLength: 0)
        }
        .frame(width: IslandLayout.panelSize.width, height: IslandLayout.panelSize.height)
        .animation(IslandController.motion, value: input)
        .environment(\.colorScheme, .dark)
        .environment(\.codenotchAccentColor, usage.accentColor.color)
        .environment(\.weeklyRingDashed, usage.weeklyRingDashed)
        .environment(\.usageWatchLimit, usage.watchLimit)
        .environment(\.usageCriticalLimit, usage.criticalLimit)
        .environment(\.colorTransitionStyle, usage.colorTransitionStyle)
    }
}

// MARK: - Forma y superficie

/// La silueta: pegada al notch, sale del borde de la pantalla con una curva
/// (`flare`) y redondea abajo; sin notch es una cápsula o un rectángulo
/// redondeado. Animable, para que abrir y plegar sea un solo movimiento.
struct IslandShape: Shape {
    var flare: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(top, bottom)) }
        set {
            flare = newValue.first
            top = newValue.second.first
            bottom = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let f = max(0, min(flare, rect.width / 4, rect.height / 2))
        if f > 0 {
            let left = rect.minX + f
            let right = rect.maxX - f
            let b = max(0, min(bottom, (right - left) / 2, rect.height - f))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + f),
                              control: CGPoint(x: right, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                        tangent2End: CGPoint(x: left, y: rect.maxY), radius: b)
            path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                        tangent2End: CGPoint(x: left, y: rect.minY), radius: b)
            path.addLine(to: CGPoint(x: left, y: rect.minY + f))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: left, y: rect.minY))
        } else {
            let t = max(0, min(top, rect.width / 2, rect.height / 2))
            let b = max(0, min(bottom, rect.width / 2, rect.height / 2))
            path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: t)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: b)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: b)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: t)
        }
        path.closeSubpath()
        return path
    }
}

/// Vidrio o color liso, con un filo de luz; negro cuando se funde con el notch.
struct IslandSurface: View {
    var shape: IslandShape
    var glass: Bool
    var tint: Color?
    var black: Bool

    var body: some View {
        ZStack {
            Group {
                if glass {
                    IslandGlass(shape: shape, tint: tint)
                } else {
                    shape.fill(tint ?? Color(hex: IslandColor.base))
                }
            }
            .opacity(black ? 0 : 1)
            shape.fill(Color.black).opacity(black ? 1 : 0)
            shape.stroke(Color.white.opacity(black ? 0 : 0.10), lineWidth: 1)
        }
    }
}

/// En macOS 26, Liquid Glass (el oscuro: vidrio claro sobre negro
/// transparente, la receta del SDK); antes, el desenfoque del sistema.
struct IslandGlass: View {
    var shape: IslandShape
    var tint: Color?

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.55)) } ?? Glass.clear, in: shape)
                .background { shape.fill(Color.black.opacity(tint == nil ? 0.55 : 0.25)) }
        } else {
            IslandBackdrop()
                .clipShape(shape)
                .overlay { shape.fill((tint ?? Color.black).opacity(tint == nil ? 0.45 : 0.55)) }
        }
    }
}

/// El desenfoque de lo que hay detrás de la ventana (macOS 15).
struct IslandBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Plegada

struct IslandCompact: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var player: NowPlayingMonitor
    @ObservedObject private var usage: NotchViewModel
    @ObservedObject private var bluetooth: IslandBluetoothMonitor
    var input: IslandLayout.Input

    init(model: IslandModel, input: IslandLayout.Input) {
        self.model = model
        player = model.player
        usage = model.usage
        bluetooth = model.bluetooth
        self.input = input
    }

    private var toast: IslandBTDevice? {
        input.mode == .toast ? bluetooth.toast : nil
    }

    /// La portada o el anillo, del alto que deja la franja.
    private var artSize: CGFloat {
        if let notch = input.notch { return max(14, min(22, notch.height - 10)) }
        return max(14, IslandLayout.capsuleHeight(menuBarHeight: input.menuBarHeight) - 8)
    }

    var body: some View {
        if let notch = input.notch {
            if input.hasCompactContent || toast != nil {
                HStack(spacing: 0) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: notch.width)
                    trailing.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, IslandLayout.flare + 10)
            }
        } else {
            HStack(spacing: 8) {
                leading
                if toast == nil { middle }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder private var leading: some View {
        if let device = toast {
            HStack(spacing: 6) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
        } else if model.hasMusic, player.current != nil {
            IslandArtwork(image: player.artwork, size: artSize, radius: 5)
        } else if let snapshot = model.headlineSnapshot {
            IslandRing(snapshot: snapshot, usage: usage, diameter: artSize, showsReading: false)
                .frame(width: artSize, height: artSize)
        }
    }

    @ViewBuilder private var middle: some View {
        if model.hasMusic, let playing = player.current {
            Text(verbatim: playing.artist.isEmpty ? playing.title : "\(playing.title) · \(playing.artist)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        } else if let snapshot = model.headlineSnapshot {
            Text(verbatim: snapshot.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let device = toast {
            Text(verbatim: device.battery.map { "\($0)%" } ?? "Conectado")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(IslandGauge.battery(device.battery))
        } else if model.hasMusic, let playing = player.current {
            IslandWaveform(playing: playing.isPlaying)
        } else if let snapshot = model.headlineSnapshot {
            Text(verbatim: ProviderReading(snapshot: snapshot, weeklyRing: usage.weeklyRing,
                                           showsRemaining: usage.showsRemainingInNotch).text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

/// Barras que bailan mientras suena (a ~12 cuadros por segundo, para gastar poco).
struct IslandWaveform: View {
    var playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !playing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { bar in
                    let phase = sin(time * (6.0 + Double(bar) * 1.9) + Double(bar) * 1.4)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2.5, height: playing ? 5 + 10 * CGFloat((phase + 1) / 2) : 3)
                }
            }
            .frame(width: 22, height: 16)
        }
    }
}

struct IslandArtwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Un anillo de IA, el mismo `ProviderCell` del notch, a la escala de la isla.
struct IslandRing: View {
    var snapshot: ProviderSnapshot
    @ObservedObject var usage: NotchViewModel
    var diameter: CGFloat
    var showsReading: Bool

    var body: some View {
        let scale = diameter / NotchLayout.ringDiameter
        let width = NotchLayout.ringDiameter + 24
        ProviderCell(snapshot: snapshot,
                     activity: usage.activity(for: snapshot),
                     isRefreshing: usage.isRefreshing(snapshot),
                     weeklyRing: usage.weeklyRing,
                     showsWeeklyReading: false,
                     showsReading: showsReading,
                     showsRemaining: usage.showsRemainingInNotch,
                     shutRingsWhenSpent: usage.shutRingsWhenSpent)
            .frame(width: width, height: NotchLayout.cellExtent)
            .scaleEffect(scale)
            .frame(width: width * scale, height: NotchLayout.cellExtent * scale)
    }
}

// MARK: - Abierta

struct IslandExpanded: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var settings: IslandSettings
    @ObservedObject private var player: NowPlayingMonitor
    var input: IslandLayout.Input

    init(model: IslandModel, input: IslandLayout.Input) {
        self.model = model
        settings = model.settings
        player = model.player
        self.input = input
    }

    var body: some View {
        let width = IslandLayout.size(input).width
        VStack(spacing: IslandLayout.headerGap) {
            header
                .frame(height: IslandLayout.header(input))
            HStack(alignment: .top, spacing: IslandLayout.columnGap) {
                if input.hasMusic {
                    IslandMusicColumn(model: model, lyrics: model.lyrics)
                        .frame(width: IslandLayout.musicWidth(totalWidth: width),
                               height: IslandLayout.musicHeight, alignment: .top)
                }
                IslandRings(model: model, input: input)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, IslandLayout.padding)
            Spacer(minLength: 0)
        }
    }

    /// Capturas a la izquierda, configuración a la derecha; con notch físico,
    /// a los lados de él.
    private var header: some View {
        HStack(spacing: 4) {
            if settings.tools {
                IslandToolButton(symbol: "camera.viewfinder", label: "Captura de pantalla completa") {
                    model.onCapture?(.fullScreen)
                }
                IslandToolButton(symbol: "crop", label: "Recortar una parte de la pantalla") {
                    model.onCapture?(.region)
                }
                IslandToolButton(symbol: "record.circle", label: "Grabar la pantalla") {
                    model.onCapture?(.record)
                }
            }
            Spacer(minLength: 0)
            IslandToolButton(symbol: "gearshape.fill", label: "Configuración") {
                model.onOpenSettings?()
            }
        }
        .padding(.horizontal, IslandLayout.padding + (input.notch != nil ? IslandLayout.flare : 0))
    }
}

/// Con toque en lugar de `Button`: la ventana de la isla nunca es la activa, y
/// así responde igual que el engranaje del notch.
struct IslandToolButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.75))
            .frame(width: 28, height: 22)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.16 : 0.07)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .help(label)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Música

struct IslandMusicColumn: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var player: NowPlayingMonitor
    @ObservedObject var lyrics: IslandLyricsService

    init(model: IslandModel, lyrics: IslandLyricsService) {
        self.model = model
        player = model.player
        self.lyrics = lyrics
    }

    var body: some View {
        if let playing = player.current {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content(playing, now: context.date)
            }
        } else if let blocked = player.blocked {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(verbatim: "macOS no deja a Codenotch leer \(blocked.displayName).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: "Actívalo en Ajustes del Sistema › Privacidad y seguridad › Automatización, y vuelve a encender Música en la configuración de la isla.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func content(_ playing: NowPlaying, now: Date) -> some View {
        let elapsed = playing.elapsed(at: now)
        let showsLyrics = model.showsLyrics && model.settings.lyrics
        return VStack(alignment: .leading, spacing: 9) {
            if showsLyrics {
                IslandLyricsView(lyrics: lyrics.current, trackKey: playing.trackKey,
                                 ms: Int(elapsed * 1000))
                    .frame(height: 64)
            } else {
                HStack(spacing: 10) {
                    IslandArtwork(image: player.artwork, size: 64, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: playing.title.isEmpty ? "Sin título" : playing.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(verbatim: playing.artist)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                        Text(verbatim: playing.player.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 64)
            }
            IslandProgress(elapsed: elapsed, duration: playing.duration) { fraction in
                player.seek(toFraction: fraction)
            }
            controls(playing)
        }
    }

    private func controls(_ playing: NowPlaying) -> some View {
        HStack(spacing: 0) {
            IslandControl(symbol: "backward.fill", size: 14) { player.send(.previous) }
            IslandControl(symbol: playing.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                player.send(.playPause)
            }
            IslandControl(symbol: "forward.fill", size: 14) { player.send(.next) }
            Spacer(minLength: 0)
            if model.settings.lyrics {
                IslandControl(symbol: model.showsLyrics ? "quote.bubble.fill" : "quote.bubble",
                              size: 13, dimmed: !model.showsLyrics) {
                    model.showsLyrics.toggle()
                }
            }
        }
        .frame(height: 26)
    }
}

struct IslandControl: View {
    var symbol: String
    var size: CGFloat
    var dimmed: Bool = false
    var action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(dimmed ? 0.55 : 1))
            .frame(width: 34, height: 26)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// La barra de avance; tocarla salta a esa parte de la canción.
struct IslandProgress: View {
    var elapsed: TimeInterval
    var duration: TimeInterval
    var onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let fraction = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: max(4, proxy.size.width * CGFloat(fraction)))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard proxy.size.width > 0 else { return }
                    onSeek(Double(value.location.x / proxy.size.width))
                })
            }
            .frame(height: 10)
            HStack {
                Text(verbatim: NowPlaying.clock(elapsed))
                Spacer(minLength: 0)
                Text(verbatim: duration > 0 ? "-" + NowPlaying.clock(max(0, duration - elapsed)) : "")
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// La letra en lugar de la portada: la línea que suena en grande, la anterior
/// y la siguiente tenues.
struct IslandLyricsView: View {
    var lyrics: IslandLyrics?
    var trackKey: String
    var ms: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lyrics, lyrics.trackKey == trackKey {
                switch lyrics.status {
                case .synced:
                    synced(lyrics)
                case .plain:
                    Text(verbatim: lyrics.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                case .instrumental:
                    note("Instrumental")
                case .loading:
                    note("Buscando la letra…")
                case .none:
                    note("No hay letra para esta canción")
                }
            } else {
                note("Buscando la letra…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func synced(_ lyrics: IslandLyrics) -> some View {
        // Un cuarto de segundo antes: la línea aparece cuando se empieza a cantar.
        let index = lyrics.lineIndex(at: ms + 250)
        let previous = index.flatMap { $0 > 0 ? lyrics.lines[$0 - 1].text : nil } ?? ""
        let current = index.map { lyrics.lines[$0].text } ?? ""
        let following = (index ?? -1) + 1
        let next = following < lyrics.lines.count ? lyrics.lines[following].text : ""
        line(previous, dim: true)
        line(current.isEmpty ? "♪" : current, dim: false)
            .animation(.easeOut(duration: 0.25), value: index)
        line(next, dim: true)
    }

    private func line(_ text: String, dim: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: dim ? 11 : 13.5, weight: dim ? .medium : .bold))
            .foregroundStyle(.white.opacity(dim ? 0.42 : 1))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
    }
}

// MARK: - Anillos

struct IslandRings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var usage: NotchViewModel
    var input: IslandLayout.Input

    init(model: IslandModel, input: IslandLayout.Input) {
        self.model = model
        usage = model.usage
        self.input = input
    }

    var body: some View {
        let shown = Array(model.cells.prefix(IslandLayout.visibleCells(input)))
        if shown.isEmpty {
            Text(verbatim: "Nada que mostrar: enciende algo en Configuración › Isla dinámica.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: IslandLayout.emptyRingsHeight)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(IslandLayout.cellWidth),
                                                         spacing: IslandLayout.cellSpacing),
                                     count: IslandLayout.columns(input)),
                      alignment: .leading, spacing: IslandLayout.cellSpacing) {
                ForEach(shown) { cell in
                    view(for: cell)
                        .frame(width: IslandLayout.cellWidth, height: IslandLayout.cellHeight)
                }
            }
        }
    }

    @ViewBuilder private func view(for cell: IslandCell) -> some View {
        switch cell {
        case .ai(let snapshot):
            VStack(spacing: 1) {
                IslandRing(snapshot: snapshot, usage: usage, diameter: IslandGauge.diameter,
                           showsReading: true)
                IslandCaption(text: snapshot.displayName)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.refreshProvider(snapshot.id) }
        case .cpu(let fraction):
            IslandGauge(fraction: fraction, color: IslandGauge.load(fraction), symbol: "cpu",
                        value: IslandSystem.percentText(fraction), label: "CPU")
                .onTapGesture { model.system.refresh() }
        case .memory(let fraction):
            IslandGauge(fraction: fraction, color: IslandGauge.load(fraction), symbol: "memorychip",
                        value: IslandSystem.percentText(fraction), label: "RAM")
                .onTapGesture { model.system.refresh() }
        case .disk(let disk):
            IslandGauge(fraction: disk.usedFraction, color: IslandGauge.disk(disk.usedFraction),
                        symbol: "internaldrive", value: IslandSystem.freeText(disk.free),
                        label: disk.name)
                .onTapGesture { model.system.refresh() }
        case .diskPlaceholder:
            IslandGauge(fraction: nil, color: IslandGauge.load(nil), symbol: "internaldrive",
                        value: "—", label: "Disco")
        case .bluetooth(let device):
            IslandGauge(fraction: device.battery.map { Double($0) / 100 },
                        color: IslandGauge.battery(device.battery), symbol: device.symbol,
                        value: device.battery.map { "\($0)%" } ?? "—", label: device.shortName)
        }
    }
}

struct IslandCaption: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: IslandLayout.cellWidth)
    }
}

/// Un anillo propio de la isla (sistema y Bluetooth), del tamaño de los de IA.
struct IslandGauge: View {
    static let diameter: CGFloat = 35
    static let lineWidth: CGFloat = 4

    var fraction: Double?
    var color: Color
    var symbol: String
    var value: String
    var label: String

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(fraction ?? 0, 0), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.65), value: fraction)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .padding(.bottom, 2)
            Text(verbatim: value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            IslandCaption(text: label)
        }
        .contentShape(Rectangle())
    }

    /// CPU y RAM: verde, amarillo desde el 60 %, rojo desde el 85 %.
    static func load(_ fraction: Double?) -> Color {
        guard let fraction else { return Color.white.opacity(0.5) }
        if fraction >= 0.85 { return Palette.critical }
        if fraction >= 0.6 { return Palette.watch }
        return Palette.ample
    }

    /// Disco usado: amarillo desde el 75 %, rojo desde el 90 %.
    static func disk(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return Palette.critical }
        if fraction >= 0.75 { return Palette.watch }
        return Palette.ample
    }

    /// Batería: roja con 20 % o menos, amarilla con 40 % o menos.
    static func battery(_ percent: Int?) -> Color {
        guard let percent else { return Color.white.opacity(0.7) }
        if percent <= 20 { return Palette.critical }
        if percent <= 40 { return Palette.watch }
        return Palette.ample
    }
}
