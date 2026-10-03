import Foundation
import UIKit
import GameController
import CoreMIDI
import CoreMotion
import QuartzCore

struct ActionEvent {
    var action: GameAction
    var down: Bool
    /// Axis value for whammy (-1…1), 1/0 for buttons.
    var value: Double
    /// MIDI velocity for drums.
    var velocity: Int?
    /// Host time (CACurrentMediaTime clock).
    var time: Double
    /// Which device produced it (for routing to players).
    var device: String = InputDevice.keyboardID
}

struct InputDevice: Identifiable, Hashable {
    enum Kind: String { case controller, keyboard, midi, touch }
    static let keyboardID = "kb"
    static let touchID = "touch"
    var id: String
    var name: String
    var kind: Kind
}

/// Collects every input source — game controllers (incl. guitars and kits
/// that present as gamepads), hardware keyboards, CoreMIDI drum kits and
/// touch — timestamps it, maps it through the bindings and queues it for the
/// game loop.
final class InputManager: ObservableObject, @unchecked Sendable {
    static let shared = InputManager()

    @Published private(set) var devices: [InputDevice] = []
    /// A controller, hardware keyboard or MIDI kit is connected (the menus
    /// then show a button legend). `devices` always lists the keyboard, so
    /// this is tracked separately.
    @Published private(set) var hasPhysicalInput = false
    @Published var capturing: GameAction? = nil

    /// Read on the input queue and CoreMIDI's thread, edited on main.
    private var _bindings = Bindings.load()
    private let bindingsLock = NSLock()
    var bindings: Bindings {
        get { bindingsLock.lock(); defer { bindingsLock.unlock() }; return _bindings }
        set {
            bindingsLock.lock(); _bindings = newValue; bindingsLock.unlock()
            newValue.save()
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    /// Start pressed in a menu on some device: return true if that joined a
    /// new player (then it isn't also a menu action).
    var joinHandler: ((String) -> Bool)?
    /// True while a song is being played; events are queued instead of
    /// going to the menu handler.
    var gameplayActive = false

    private let queue = DispatchQueue(label: "strumline.input", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [ActionEvent] = []
    private var buttonState: [String: Bool] = [:]
    private var captureHandler: ((InputBinding) -> Void)?
    private var midiClient = MIDIClientRef()
    private var midiPort = MIDIPortRef()
    private let motion = CMMotionManager()
    private var lastTilt = 0.0
    /// Rotating the phone to change orientation is not a star power flick.
    private var lastOrientationChange = 0.0

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
            self?.refreshDevices()
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices() }
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            if let k = n.object as? GCKeyboard { self?.attach(k) }
            self?.refreshDevices()
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices() }
        for c in GCController.controllers() { attach(c) }
        if let k = GCKeyboard.coalesced { attach(k) }
        GCController.shouldMonitorBackgroundEvents = false
        DispatchQueue.main.async { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        nc.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lastOrientationChange = CACurrentMediaTime()
        }
        setupMIDI()
        refreshDevices()
    }

    static func id(of c: GCController) -> String {
        // Stable while connected; includes the name so it reads well.
        "gc:\(c.vendorName ?? "Controller"):\(ObjectIdentifier(c).hashValue)"
    }

    func refreshDevices() {
        var d: [InputDevice] = [InputDevice(id: InputDevice.touchID, name: "Touchscreen", kind: .touch)]
        d.append(InputDevice(id: InputDevice.keyboardID, name: "Keyboard", kind: .keyboard))
        for c in GCController.controllers() {
            d.append(InputDevice(id: InputManager.id(of: c), name: c.vendorName ?? c.productCategory, kind: .controller))
        }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
            d.append(InputDevice(id: "midi:\(src)", name: (name?.takeRetainedValue() as String?) ?? "MIDI Source", kind: .midi))
        }
        let devices = d
        let physical = !GCController.controllers().isEmpty || GCKeyboard.coalesced != nil || MIDIGetNumberOfSources() > 0
        DispatchQueue.main.async {
            self.devices = devices
            self.hasPhysicalInput = physical
        }
    }

    // MARK: Capture (rebinding)

    func beginCapture(_ action: GameAction, completion: @escaping (InputBinding) -> Void) {
        lock.lock()
        captureHandler = completion
        lock.unlock()
        capturing = action
    }

    func cancelCapture() {
        lock.lock()
        captureHandler = nil
        lock.unlock()
        capturing = nil
    }

    /// True if the binding was captured (and must not also be dispatched).
    private func capture(_ b: InputBinding) -> Bool {
        lock.lock()
        let h = captureHandler
        captureHandler = nil
        lock.unlock()
        guard let h else { return false }
        DispatchQueue.main.async {
            self.capturing = nil
            h(b)
        }
        return true
    }

    // MARK: Dispatch

    func drain() -> [ActionEvent] {
        lock.lock()
        defer { pending.removeAll(keepingCapacity: true); lock.unlock() }
        return pending.sorted { $0.time < $1.time }
    }

    func clearQueue() {
        lock.lock(); pending.removeAll(); lock.unlock()
    }

    /// Touch controls and tilt feed actions in directly.
    func inject(_ action: GameAction, down: Bool, value: Double = 1, time: Double) {
        push(ActionEvent(action: action, down: down, value: value, velocity: nil, time: time, device: InputDevice.touchID))
    }

    private func push(_ e: ActionEvent) {
        if gameplayActive {
            lock.lock(); pending.append(e); lock.unlock()
        } else if e.down {
            menu([e.action], device: e.device)
        }
    }

    private func menu(_ actions: Set<GameAction>, device: String) {
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async {
            if actions.contains(.pause), !actions.contains(.menuBack), let j = self.joinHandler, j(device) { return }
            // Every action bound to one physical press arrives together.
            MainActor.assumeIsolated { MenuFocus.shared.dispatch(actions) }
        }
    }

    /// One physical press or release, as the actions bound to it: to the
    /// menus outside a song (presses only), queued for the game during one.
    private func deliver(_ actions: [GameAction], down: Bool, value: Double, velocity: Int? = nil, time: Double, device: String) {
        guard gameplayActive else {
            if down { menu(Set(actions), device: device) }
            return
        }
        for a in actions { push(ActionEvent(action: a, down: down, value: value, velocity: velocity, time: time, device: device)) }
    }

    private func dispatch(_ b: InputBinding, down: Bool, value: Double = 1, velocity: Int? = nil, time: Double, device: String) {
        if down, capture(b) { return }
        deliver(bindings.actions(for: b), down: down, value: value, velocity: velocity, time: time, device: device)
    }

    // MARK: Keyboard

    private func attach(_ k: GCKeyboard) {
        k.handlerQueue = queue
        k.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
            self?.keyEvent(code.rawValue, down: pressed, time: CACurrentMediaTime(), source: .gameController)
        }
    }

    /// Hardware keys arrive both through GCKeyboard and through UIKit's
    /// responder chain (KeyCatcher). An event the *other* path already
    /// delivered (same key, same direction, within 40 ms) is its twin and is
    /// dropped. Matching on time rather than "is the key down" means a twin
    /// that lags past a quick release can't come back as a second press
    /// (a double strum).
    enum KeySource { case gameController, uikit }
    private struct KeyEdge: Hashable { var code: Int; var down: Bool; var gc: Bool }
    private var lastEdge: [KeyEdge: Double] = [:]
    private var keyDown = Set<Int>()
    private let keyLock = NSLock()

    func keyEvent(_ code: Int, down: Bool, time: Double, source: KeySource) {
        let mine = KeyEdge(code: code, down: down, gc: source == .gameController)
        var other = mine
        other.gc.toggle()
        keyLock.lock()
        if let t = lastEdge[other], abs(time - t) < 0.04 {
            lastEdge[other] = nil  // consumed: a later real press isn't mistaken for it
            keyLock.unlock()
            return
        }
        lastEdge[mine] = time
        let changed = down ? keyDown.insert(code).inserted : keyDown.remove(code) != nil
        keyLock.unlock()
        if changed { dispatch(.key(code), down: down, time: time, device: InputDevice.keyboardID) }
    }

    // MARK: Controllers

    private func attach(_ c: GCController) {
        c.handlerQueue = queue
        let profile = c.physicalInputProfile
        let dev = InputManager.id(of: c)
        profile.valueDidChangeHandler = { [weak self] _, element in
            self?.handle(element: element, time: CACurrentMediaTime(), device: dev)
        }
    }

    /// Every name iOS gives an element ("Button A", "Cross Button", …),
    /// stable order, primary first. Bindings may use any of them.
    private func names(_ e: GCControllerElement) -> [String] {
        var out: [String] = []
        if let f = e.aliases.first { out.append(f) }
        out += e.aliases.sorted().filter { !out.contains($0) }
        if let l = e.localizedName, !out.contains(l) { out.append(l) }
        return out.isEmpty ? ["Element"] : out
    }

    private func name(_ e: GCControllerElement) -> String { names(e)[0] }

    private func setButton(_ keys: [String], _ pressed: Bool, time: Double, device: String) {
        let stateKey = device + "|" + keys[0]
        if buttonState[stateKey] == pressed { return }
        buttonState[stateKey] = pressed
        if pressed, capture(.button(keys[0])) { return }
        // Union of the actions bound to any of the element's names.
        var actions: [GameAction] = []
        for k in keys { for a in bindings.actions(for: .button(k)) where !actions.contains(a) { actions.append(a) } }
        deliver(actions, down: pressed, value: pressed ? 1 : 0, time: time, device: device)
    }

    private func handle(element: GCControllerElement, time: Double, device: String) {
        if let dpad = element as? GCControllerDirectionPad {
            let all = names(dpad)
            let n = all[0]
            func dirs(_ d: String) -> [String] { all.map { $0 + "." + d } }
            setButton(dirs("up"), dpad.up.isPressed, time: time, device: device)
            setButton(dirs("down"), dpad.down.isPressed, time: time, device: device)
            setButton(dirs("left"), dpad.left.isPressed, time: time, device: device)
            setButton(dirs("right"), dpad.right.isPressed, time: time, device: device)
            axis(n + " X Axis", Double(dpad.xAxis.value), time: time, device: device)
            axis(n + " Y Axis", Double(dpad.yAxis.value), time: time, device: device)
        } else if let b = element as? GCControllerButtonInput {
            let all = names(b)
            let n = all[0]
            setButton(all, b.isPressed, time: time, device: device)
            if b.isAnalog { axis(n, Double(b.value), time: time, device: device) }
        } else if let a = element as? GCControllerAxisInput {
            axis(name(a), Double(a.value), time: time, device: device)
        }
    }

    private func axis(_ key: String, _ v: Double, time: Double, device: String) {
        // Axis-as-button for capture and for bindings like "stick up = strum".
        for positive in [true, false] {
            let stateKey = device + "|" + key + (positive ? "+" : "-")
            let on = positive ? v > 0.6 : v < -0.6
            guard buttonState[stateKey] != on else { continue }
            buttonState[stateKey] = on
            if on, capture(.axis(key, positive: positive)) { return }
            let acts = bindings.actions(for: .axis(key, positive: positive)).filter { $0 != .whammy }
            deliver(acts, down: on, value: v, time: time, device: device)
        }
        // Continuous value for whammy (once, even if bound in both directions).
        guard gameplayActive else { return }
        if [true, false].contains(where: { bindings.actions(for: .axis(key, positive: $0)).contains(.whammy) }) {
            push(ActionEvent(action: .whammy, down: true, value: v, velocity: nil, time: time, device: device))
        }
    }

    // MARK: MIDI

    private func setupMIDI() {
        MIDIClientCreateWithBlock("Strumline" as CFString, &midiClient) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                self?.connectMIDISources()
                self?.refreshDevices()
            }
        }
        MIDIInputPortCreateWithProtocol(midiClient, "Strumline In" as CFString, ._1_0, &midiPort) { [weak self] list, ref in
            let src = ref.map { UInt32(truncatingIfNeeded: Int(bitPattern: $0)) } ?? 0
            self?.handleMIDI(list, device: "midi:\(src)")
        }
        connectMIDISources()
    }

    private func connectMIDISources() {
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(midiPort, src, UnsafeMutableRawPointer(bitPattern: Int(src)))
        }
    }

    private func handleMIDI(_ list: UnsafePointer<MIDIEventList>, device: String) {
        for packet in list.unsafeSequence() {
            let t = packet.pointee.timeStamp == 0 ? CACurrentMediaTime() : hostSeconds(packet.pointee.timeStamp)
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let type = w >> 28
                    let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(type)]
                    if type == 2 {
                        let status = (w >> 16) & 0xF0
                        let note = Int((w >> 8) & 0x7F)
                        let vel = Int(w & 0x7F)
                        if status == 0x90 && vel > 0 {
                            dispatch(.midi(note), down: true, value: Double(vel) / 127, velocity: vel, time: t, device: device)
                        } else if status == 0x80 || (status == 0x90 && vel == 0) {
                            dispatch(.midi(note), down: false, time: t, device: device)
                        }
                    }
                    i += size
                }
            }
        }
    }

    // MARK: Phone tilt → star power

    func startTilt(_ on: Bool) {
        guard on, motion.isDeviceMotionAvailable else { motion.stopDeviceMotionUpdates(); return }
        motion.deviceMotionUpdateInterval = 1 / 60
        motion.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] m, _ in
            guard let self, let m else { return }
            // A quick upward flick of the phone.
            let r = m.rotationRate
            let mag = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            let now = CACurrentMediaTime()
            if mag > 8 && now - self.lastTilt > 1.0 && now - self.lastOrientationChange > 1.5 {
                self.lastTilt = now
                self.push(ActionEvent(action: .tilt, down: true, value: 1, velocity: nil, time: now, device: InputDevice.touchID))
            }
        }
    }
}
