import AudioToolbox
import Combine
import CoreAudio
import CoreFoundation
import Foundation
import IOKit
import IOKit.graphics

/// Volume + brightness HUD.
///
/// - Volume: CoreAudio default-output device via PUBLIC APIs only —
///   `kAudioDevicePropertyVolumeScalar` + `kAudioDevicePropertyMute` and
///   their `AudioObjectAddPropertyListenerBlock` listeners. Master element
///   first, per-channel fallback (some outputs expose no master channel).
///   Default-output switches (AirPods!) re-bind automatically.
/// - Brightness: IODisplayConnect (public IOKit). Modern Apple Silicon
///   MacBooks return kIOReturnUnsupported on the internal panel (verified
///   live on this OS), so support is runtime-probed and the surface is
///   gracefully omitted where the OS disallows it. Never a crash.
@MainActor
public final class HudEngine: ObservableObject {
    public static let enabledKey = "hud.enabled"

    @Published public private(set) var volume: Double = 0
    @Published public private(set) var muted = false
    @Published public private(set) var brightness: Double = 0
    @Published public private(set) var brightnessSupported = false

    /// Volume change callback → coordinator shows the HUD surface.
    public var onVolumeChange: ((Double, Bool) -> Void)?
    public var onBrightnessChange: ((Double) -> Void)?

    private var deviceID: AudioDeviceID = 0
    private var listenersInstalled = false
    /// Debounce: the listener fires in bursts while a key repeats.
    private var volumeEmitWork: DispatchWorkItem?
    private var brightEmitWork: DispatchWorkItem?
    private var lastEmittedVolume: Double = -1
    private var lastEmittedMute = false

    /// Static copy of the volume listener callback context: the CoreAudio
    /// listener block must not capture a MainActor self strongly.
    nonisolated(unsafe) static var liveVolumeSink: (() -> Void)?

    public init() {
        enabled = Self.isEnabled()
        Self.liveVolumeSink = { [weak self] in
            Task { @MainActor in self?.volumeChangedLive() }
        }
        refreshDevice()
        refreshSnapshot()
    }

    public static func isEnabled() -> Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// UI-facing toggle state (UserDefaults-backed; engines are process
    /// services, so the toggle lives on the store, not the instance).
    @Published public private(set) var enabled: Bool

    public func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        enabled = on
    }

    // MARK: - Device plumbing

    private func refreshDevice() {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != 0 else {
            deviceID = 0
            return
        }
        if deviceID != id {
            if listenersInstalled { removeListeners(from: deviceID) }
            listenersInstalled = false
            deviceID = id
        }
        installListeners()
        watchDefaultDeviceChange()
    }

    private var defaultDeviceWatcher = false

    /// Default output can switch (AirPods!): re-bind when it does.
    private func watchDefaultDeviceChange() {
        guard !defaultDeviceWatcher else { return }
        defaultDeviceWatcher = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            Task { @MainActor in
                self.refreshDevice()
                self.refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        volume = Self.readVolume(device: deviceID) ?? 0
        muted = Self.readMute(device: deviceID) ?? false
        if let b = Self.readBrightness() {
            brightness = b
            brightnessSupported = true
        } else {
            brightnessSupported = false
        }
    }

    // MARK: - Listeners

    private func installListeners() {
        guard deviceID != 0, !listenersInstalled else { return }
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, .main) { _, _ in
            Self.liveVolumeSink?()
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, .main) { _, _ in
            Self.liveVolumeSink?()
        }
        listenersInstalled = true
    }

    private func removeListeners(from device: AudioDeviceID) {
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &volAddr, .main) { _, _ in }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &muteAddr, .main) { _, _ in }
    }

    private func volumeChangedLive() {
        let v = Self.readVolume(device: deviceID) ?? volume
        let m = Self.readMute(device: deviceID) ?? muted
        volume = v
        muted = m
        guard Self.isEnabled() else { return }
        volumeEmitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if v != self.lastEmittedVolume || m != self.lastEmittedMute {
                    self.lastEmittedVolume = v
                    self.lastEmittedMute = m
                    self.onVolumeChange?(v, m)
                }
            }
        }
        volumeEmitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Readers (static + pure for probing)

    /// Master element first; falls back to channel 1 (left) when the device
    /// exposes no master channel.
    public static func readVolume(device: AudioDeviceID) -> Double? {
        guard device != 0 else { return nil }
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            var scalar = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &scalar)
            if status == noErr { return Double(scalar) }
        }
        return nil
    }

    public static func readMute(device: AudioDeviceID) -> Bool? {
        guard device != 0 else { return nil }
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
            if status == noErr { return value != 0 }
        }
        return nil
    }

    // MARK: - Brightness (public IOKit; runtime-probed)

    nonisolated(unsafe) private static let brightnessKey = CFStringCreateWithCString(
        kCFAllocatorDefault, "brightness", CFStringGetSystemEncoding())

    /// First IODisplayConnect that accepts a brightness read. The returned
    /// service is +1 retained; caller releases.
    nonisolated public static func findBrightnessService() -> io_service_t? {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("IODisplayConnect"),
                                              &iterator)
        guard kr == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var candidate = IOIteratorNext(iterator)
        while candidate != 0 {
            var level: Float = 0
            if IODisplayGetFloatParameter(candidate, 0, brightnessKey, &level) == KERN_SUCCESS {
                return candidate
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(iterator)
        }
        return nil
    }

    nonisolated public static func readBrightness() -> Double? {
        guard let svc = findBrightnessService() else { return nil }
        defer { IOObjectRelease(svc) }
        var level: Float = 0
        guard IODisplayGetFloatParameter(svc, 0, brightnessKey, &level) == KERN_SUCCESS else {
            return nil
        }
        return Double(level)
    }

    @discardableResult
    public func setBrightness(_ value: Double) -> Bool {
        guard let svc = Self.findBrightnessService() else { return false }
        defer { IOObjectRelease(svc) }
        let v = Float(min(1, max(0, value)))
        guard IODisplaySetFloatParameter(svc, 0, Self.brightnessKey, v) == KERN_SUCCESS else {
            return false
        }
        brightness = Double(v)
        return true
    }
}
