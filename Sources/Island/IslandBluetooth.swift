import AppKit
import Combine
import IOBluetooth
import IOKit

/// **Map Ranking — Bluetooth** para la isla: los dispositivos conectados con
/// su batería, y un aviso plegado cuando uno se conecta. Como `bluetooth.rs`
/// en Windows.
///
/// La lista sale de IOBluetooth (macOS pide permiso de Bluetooth la primera
/// vez). La batería, de dos lugares, porque macOS no la publica para todos:
/// los audífonos de Apple la responden por métodos internos de
/// `IOBluetoothDevice`, y los teclados, ratones y trackpads por el registro de
/// IOKit. Un dispositivo sin ninguno de los dos se muestra sin porcentaje.
struct IslandBTDevice: Equatable, Identifiable {
    enum Kind: Equatable {
        case headphones, keyboard, mouse, trackpad, gamepad, other
    }

    /// La dirección, en minúsculas y con guiones.
    var id: String
    var name: String
    /// 0…100, si se sabe.
    var battery: Int?
    var kind: Kind

    var symbol: String {
        switch kind {
        case .headphones: return "headphones"
        case .keyboard:   return "keyboard"
        case .mouse:      return "magicmouse"
        case .trackpad:   return "rectangle.and.hand.point.up.left"
        case .gamepad:    return "gamecontroller"
        case .other:      return "dot.radiowaves.left.and.right"
        }
    }

    /// "AirPods Pro" → "AirPods Pro"; nombres largos, recortados para el anillo.
    var shortName: String {
        name.count > 12 ? String(name.prefix(11)) + "…" : name
    }

    static func kind(name: String, majorClass: UInt32) -> Kind {
        let lower = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        if has(["airpods", "buds", "headphone", "beats", "audífono", "auricular", "earbud", "headset", "wh-", "wf-"]) {
            return .headphones
        }
        if has(["keyboard", "teclado"]) { return .keyboard }
        if has(["trackpad"]) { return .trackpad }
        if has(["mouse", "ratón", "raton", "mx master", "mx anywhere"]) { return .mouse }
        if has(["controller", "gamepad", "dualsense", "dualshock", "xbox", "joy-con", "control"]) {
            return .gamepad
        }
        // Clase mayor del Bluetooth clásico: 0x04 audio, 0x05 periféricos.
        if majorClass == 0x04 { return .headphones }
        return .other
    }

    static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }
}

@MainActor
final class IslandBluetoothMonitor: ObservableObject {
    @Published private(set) var devices: [IslandBTDevice] = []
    /// El que se acaba de conectar, unos segundos.
    @Published private(set) var toast: IslandBTDevice?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            timer?.invalidate()
            timer = nil
            known = nil
            if enabled { start() } else { devices = []; toast = nil }
        }
    }
    var toastsEnabled = true

    private var timer: Timer?
    /// Las direcciones conectadas en la lectura anterior; nil antes de la
    /// primera, para no avisar de lo que ya estaba conectado al abrir la app.
    private var known: Set<String>?
    private var toastWork: Task<Void, Never>?

    private func start() {
        poll()
        // La lista es barata de leer; cada 5 s alcanza para el aviso.
        let ticker = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        ticker.tolerance = 1
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func poll() {
        guard enabled else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let hid = Self.hidBatteries()
        var list: [IslandBTDevice] = []
        for device in paired where device.isConnected() {
            let address = IslandBTDevice.normalize(device.addressString ?? "")
            let name = device.name ?? "Dispositivo"
            let battery = Self.appleBattery(device) ?? hid[address]
            list.append(IslandBTDevice(id: address, name: name, battery: battery,
                                       kind: IslandBTDevice.kind(name: name,
                                                                 majorClass: UInt32(device.deviceClassMajor))))
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let connected = Set(list.map(\.id))
        if let known, toastsEnabled, let newcomer = list.first(where: { !known.contains($0.id) }) {
            show(toast: newcomer)
        }
        known = connected
        if list != devices { devices = list }
    }

    private func show(toast device: IslandBTDevice) {
        toastWork?.cancel()
        toast = device
        toastWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Los audífonos de Apple (AirPods, Beats) responden su batería por métodos
    /// internos de `IOBluetoothDevice`. Se llaman solo si existen y devuelven un
    /// byte, así un macOS que los cambie simplemente no da porcentaje.
    private static func appleBattery(_ device: IOBluetoothDevice) -> Int? {
        if let single = byteProperty(device, "batteryPercentSingle") { return single }
        let buds = ["batteryPercentLeft", "batteryPercentRight"].compactMap { byteProperty(device, $0) }
        if let lowest = buds.min() { return lowest }
        return byteProperty(device, "batteryPercentCombined")
    }

    private static func byteProperty(_ object: NSObject, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return nil }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard String(cString: encoding) == "C" else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let value = unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
        return value > 0 && value <= 100 ? Int(value) : nil
    }

    /// Teclados, ratones y trackpads (los de Apple y muchos otros) publican
    /// `BatteryPercent` en el registro de IOKit, con su dirección.
    private static func hidBatteries() -> [String: Int] {
        var batteries: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS
        else { return batteries }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString,
                                                          kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString,
                                                          kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let percent, let address, percent > 0, percent <= 100 {
                batteries[IslandBTDevice.normalize(address)] = percent
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return batteries
    }
}
