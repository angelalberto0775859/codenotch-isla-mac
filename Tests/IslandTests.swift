import AppKit
import XCTest
@testable import Codenotch

/// Map Ranking — la isla dinámica: lo que se puede probar sin pantalla, ni
/// reproductor, ni Bluetooth. Las de LRC y LRCLIB son las mismas de
/// `windows/codenotch/src/lyrics.rs`, para que las dos islas lean igual.
final class IslandTests: XCTestCase {
    // MARK: - Letras

    func testLRCLinesComeOutTimedAndInOrder() {
        let lines = LRC.parse("[ar: Someone]\n[00:12.50] second\n[00:01.00][00:30.00] first and again\n[00:20.00]\nplain words")
        XCTAssertEqual(lines, [
            IslandLyricLine(ms: 1000, text: "first and again"),
            IslandLyricLine(ms: 12500, text: "second"),
            IslandLyricLine(ms: 20000, text: ""),
            IslandLyricLine(ms: 30000, text: "first and again"),
        ])
    }

    func testStampsAndTags() {
        XCTAssertEqual(LRC.stamp("01:02.34"), 62340)
        XCTAssertEqual(LRC.stamp("00:00"), 0)
        XCTAssertNil(LRC.stamp("ar: Someone"))
        XCTAssertNil(LRC.stamp("sin tiempo"))
    }

    func testTheTimedEntryOfTheRightLengthWins() throws {
        let json = """
        [{"duration":250,"plainLyrics":"a","syncedLyrics":null},
         {"duration":201,"plainLyrics":"b","syncedLyrics":"[00:01.00] b"},
         {"duration":330,"plainLyrics":"c","syncedLyrics":"[00:01.00] c"}]
        """
        let entries = try JSONDecoder().decode([LRCLibEntry].self, from: Data(json.utf8))
        XCTAssertEqual(LRCLib.best(entries, album: "", durationMs: 200_000)?.plainLyrics, "b")
    }

    func testWithoutALengthTimedLyricsStillWin() {
        let entries = [
            LRCLibEntry(duration: 200, plainLyrics: "solo texto"),
            LRCLibEntry(duration: 400, plainLyrics: "con tiempos", syncedLyrics: "[00:01.00] x"),
        ]
        XCTAssertEqual(LRCLib.best(entries, album: "", durationMs: 0)?.plainLyrics, "con tiempos")
    }

    func testTheSameAlbumBreaksATie() {
        let entries = [
            LRCLibEntry(duration: 200, albumName: "Otro", syncedLyrics: "[00:01.00] a"),
            LRCLibEntry(duration: 200, albumName: "El Álbum", syncedLyrics: "[00:01.00] b"),
        ]
        XCTAssertEqual(LRCLib.best(entries, album: "el álbum", durationMs: 200_000)?.albumName, "El Álbum")
    }

    func testWhatAnEntryBecomes() {
        XCTAssertEqual(LRCLib.lyrics(trackKey: "k", entry: LRCLibEntry(instrumental: true)).status,
                       .instrumental)
        XCTAssertEqual(LRCLib.lyrics(trackKey: "k", entry: LRCLibEntry(plainLyrics: " hola ")).status, .plain)
        XCTAssertEqual(LRCLib.lyrics(trackKey: "k", entry: LRCLibEntry(syncedLyrics: "[00:02.00] hola")).lines,
                       [IslandLyricLine(ms: 2000, text: "hola")])
        XCTAssertEqual(LRCLib.lyrics(trackKey: "k", entry: nil).status, .none)
    }

    func testTheLineFollowsTheSong() {
        let lyrics = IslandLyrics(trackKey: "k", status: .synced, lines: [
            IslandLyricLine(ms: 1000, text: "uno"),
            IslandLyricLine(ms: 5000, text: "dos"),
            IslandLyricLine(ms: 9000, text: "tres"),
        ])
        XCTAssertNil(lyrics.lineIndex(at: 0))
        XCTAssertEqual(lyrics.lineIndex(at: 1000), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 4999), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 5000), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 60_000), 2)
    }

    // MARK: - Música

    func testTheSongMovesOnlyWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1_000)
        var playing = NowPlaying(player: .music, title: "t", artist: "a", album: "b", duration: 100,
                                 position: 10, readAt: start, isPlaying: true)
        XCTAssertEqual(playing.elapsed(at: start.addingTimeInterval(5)), 15, accuracy: 0.001)
        XCTAssertEqual(playing.elapsed(at: start.addingTimeInterval(500)), 100, accuracy: 0.001)
        playing.isPlaying = false
        XCTAssertEqual(playing.elapsed(at: start.addingTimeInterval(5)), 10, accuracy: 0.001)
    }

    func testClock() {
        XCTAssertEqual(NowPlaying.clock(0), "0:00")
        XCTAssertEqual(NowPlaying.clock(65), "1:05")
        XCTAssertEqual(NowPlaying.clock(754.9), "12:34")
    }

    func testSpotifyAnswerIsReadWithItsLengthInMilliseconds() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "playing"), at: 1)
        list.insert(NSAppleEventDescriptor(string: "Canción"), at: 2)
        list.insert(NSAppleEventDescriptor(string: "Artista"), at: 3)
        list.insert(NSAppleEventDescriptor(string: "Álbum"), at: 4)
        list.insert(NSAppleEventDescriptor(int32: 200_000), at: 5)
        list.insert(NSAppleEventDescriptor(double: 12.5), at: 6)
        list.insert(NSAppleEventDescriptor(string: "https://i.scdn.co/image/abc"), at: 7)
        let reading = IslandMusic.reading(from: list, player: .spotify, now: Date())
        XCTAssertEqual(reading?.title, "Canción")
        XCTAssertEqual(reading?.artist, "Artista")
        XCTAssertEqual(reading?.duration ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(reading?.position ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(reading?.isPlaying, true)
        XCTAssertEqual(reading?.artworkURL, "https://i.scdn.co/image/abc")
    }

    func testAStoppedPlayerHasNoSong() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "stopped"), at: 1)
        XCTAssertNil(IslandMusic.reading(from: list, player: .music, now: Date()))
    }

    func testScriptsNameTheRightApp() {
        XCTAssertTrue(IslandMusic.stateScript(for: .music).contains("tell application \"Music\""))
        XCTAssertTrue(IslandMusic.stateScript(for: .spotify).contains("artwork url"))
        XCTAssertFalse(IslandMusic.stateScript(for: .music).contains("artwork url"))
        XCTAssertEqual(IslandMusic.commandScript(.next, for: .spotify),
                       "tell application \"Spotify\" to next track")
        XCTAssertEqual(IslandMusic.seekScript(to: 61.5, for: .music),
                       "tell application \"Music\" to set player position to 61.50")
    }

    // MARK: - Sistema

    func testCPUUseBetweenTwoReadings() {
        let earlier = IslandSystem.CPUTicks(busy: 100, total: 1000)
        let later = IslandSystem.CPUTicks(busy: 400, total: 2000)
        XCTAssertEqual(IslandSystem.cpuFraction(from: earlier, to: later) ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertNil(IslandSystem.cpuFraction(from: later, to: earlier))
    }

    func testFreeSpaceReadsLikeFinder() {
        XCTAssertEqual(IslandSystem.freeText(45_600_000_000), "45.6 GB")
        XCTAssertEqual(IslandSystem.freeText(123_400_000_000), "123 GB")
        XCTAssertEqual(IslandSystem.freeText(1_500_000_000_000), "1.5 TB")
        XCTAssertEqual(IslandSystem.percentText(0.344), "34%")
        XCTAssertEqual(IslandSystem.percentText(nil), "—")
    }

    func testThisMacAnswers() {
        XCTAssertNotNil(IslandSystem.cpuTicks())
        let memory = IslandSystem.memory()
        XCTAssertNotNil(memory)
        XCTAssertGreaterThan(memory?.total ?? 0, 0)
        XCTAssertLessThanOrEqual(memory?.used ?? 0, memory?.total ?? 0)
    }

    // MARK: - Bluetooth

    func testDeviceKinds() {
        XCTAssertEqual(IslandBTDevice.kind(name: "AirPods Pro de Angel", majorClass: 0), .headphones)
        XCTAssertEqual(IslandBTDevice.kind(name: "Magic Keyboard", majorClass: 5), .keyboard)
        XCTAssertEqual(IslandBTDevice.kind(name: "Magic Trackpad", majorClass: 5), .trackpad)
        XCTAssertEqual(IslandBTDevice.kind(name: "MX Master 3S", majorClass: 5), .mouse)
        XCTAssertEqual(IslandBTDevice.kind(name: "DualSense Wireless Controller", majorClass: 5), .gamepad)
        XCTAssertEqual(IslandBTDevice.kind(name: "Bocina", majorClass: 0x04), .headphones)
        XCTAssertEqual(IslandBTDevice.kind(name: "Cosa", majorClass: 0), .other)
        XCTAssertEqual(IslandBTDevice.normalize("AA:BB:CC:DD:EE:FF"), "aa-bb-cc-dd-ee-ff")
    }

    // MARK: - Color y capturas

    func testColors() {
        XCTAssertEqual(IslandColor.normalized("#1c1c1e"), "#1C1C1E")
        XCTAssertEqual(IslandColor.normalized(" abcdef "), "#ABCDEF")
        XCTAssertNil(IslandColor.normalized("#12345"))
        XCTAssertNil(IslandColor.normalized("zzzzzz"))
        XCTAssertEqual(IslandColor.value("#FF0000"), 0xFF0000)
        XCTAssertNil(IslandColor.color(""))
    }

    func testScreenshotNamesLikeMacOS() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 30
        parts.hour = 1
        parts.minute = 23
        parts.second = 45
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(IslandCapture.fileName(at: date), "Captura de pantalla 2026-10-30 a las 1.23.45.png")
    }

    // MARK: - Geometría

    private func input(_ mode: IslandLayout.Mode = .collapsed, notch: IslandLayout.Notch? = nil,
                       music: Bool = true, compact: Bool = true, cells: Int = 6) -> IslandLayout.Input {
        IslandLayout.Input(mode: mode, notch: notch, menuBarHeight: notch == nil ? 24 : 32,
                           screenWidth: 1512, hasMusic: music, hasCompactContent: compact, cells: cells)
    }

    private let macBookNotch = IslandLayout.Notch(width: 200, height: 32)

    func testOpenIsSplitThirtySeventy() {
        let open = input(.expanded)
        XCTAssertEqual(IslandLayout.size(open).width, 680)
        XCTAssertEqual(IslandLayout.musicWidth(totalWidth: 680), 189)
        XCTAssertEqual(IslandLayout.ringsWidth(open), 441)
        XCTAssertEqual(IslandLayout.columns(open), 6)
        XCTAssertLessThan(IslandLayout.size(input(.expanded, music: false)).width, 680)
    }

    func testFoldedOnANotchIsTheNotchsHeight() {
        let folded = IslandLayout.size(input(notch: macBookNotch))
        XCTAssertEqual(folded.height, 32)
        XCTAssertEqual(folded.width, 200 + 2 * IslandLayout.wing + 2 * IslandLayout.flare)
        XCTAssertEqual(IslandLayout.size(input(notch: macBookNotch, music: false, compact: false)).width, 200)
        XCTAssertGreaterThan(IslandLayout.size(input(.toast, notch: macBookNotch)).width, folded.width)
        XCTAssertEqual(IslandLayout.topGap(input(notch: macBookNotch)), 0)
    }

    func testWithoutANotchItIsACapsuleInTheMenuBar() {
        let folded = input()
        XCTAssertEqual(IslandLayout.size(folded).height, 22)
        XCTAssertEqual(IslandLayout.topGap(folded), 1)
        let radii = IslandLayout.radii(folded)
        XCTAssertEqual(radii.top, 11)
        XCTAssertEqual(radii.bottom, 11)
        XCTAssertEqual(radii.flare, 0)
    }

    func testRingsWrapAndStopAtThreeRows() {
        let many = input(.expanded, cells: 30)
        XCTAssertEqual(IslandLayout.rows(many), 3)
        XCTAssertEqual(IslandLayout.visibleCells(many), 18)
        XCTAssertEqual(IslandLayout.rows(input(.expanded, cells: 0)), 0)
    }

    func testEveryIslandFitsItsWindowAndIsCentred() {
        for mode in [IslandLayout.Mode.collapsed, .toast, .expanded] {
            for notch in [nil, macBookNotch] {
                for cells in [0, 6, 40] {
                    let frame = IslandLayout.frame(input(mode, notch: notch, cells: cells))
                    let panel = CGRect(origin: .zero, size: IslandLayout.panelSize)
                    XCTAssertTrue(panel.contains(frame), "\(mode) \(String(describing: notch)) \(cells)")
                    XCTAssertEqual(frame.midX, panel.midX, accuracy: 1)
                }
            }
        }
    }

    func testTheIslandOnlyHidesTheNotchOnTheTopEdge() {
        XCTAssertTrue(IslandController.replacesNotch(enabled: true, edge: .top))
        XCTAssertFalse(IslandController.replacesNotch(enabled: true, edge: .right))
        XCTAssertFalse(IslandController.replacesNotch(enabled: false, edge: .top))
    }
}

@MainActor
final class IslandSettingsTests: XCTestCase {
    func testEverythingStartsOnAndIsRemembered() throws {
        let suite = "isla.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = IslandSettings(defaults: defaults)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.media)
        XCTAssertTrue(settings.lyrics)
        XCTAssertTrue(settings.glass)
        XCTAssertEqual(settings.color, "")

        settings.media = false
        settings.color = "#3A1C5C"
        let again = IslandSettings(defaults: defaults)
        XCTAssertFalse(again.media)
        XCTAssertEqual(again.color, "#3A1C5C")
    }

    func testTheOpenIslandListsItsRingsByGroup() {
        let suite = "isla.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IslandSettings(defaults: defaults)
        let model = IslandModel(settings: settings, usage: NotchViewModel())
        // Sin lecturas todavía: CPU, RAM y el disco por llegar.
        XCTAssertEqual(model.cells.map(\.id), ["sys.cpu", "sys.ram", "sys.disk"])
        settings.system = false
        XCTAssertTrue(model.cells.isEmpty)
        XCTAssertEqual(model.mode, .collapsed)
        XCTAssertFalse(model.hasMusic)
    }
}
