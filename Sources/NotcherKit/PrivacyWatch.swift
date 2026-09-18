import AVFoundation
import Combine
import CoreAudio
import Foundation
import CoreMediaIO

/// Live camera & microphone in-use indicators — public property APIs only.
///
/// - Microphone: the default input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`
///   property is true while ANY process is capturing from it. Public CoreAudio.
/// - Camera: `kCMIODevicePropertyDeviceIsRunningSomewhere` on CMIO devices.
///   Public CoreMediaIO since macOS 12.3 — exactly what the system LED reacts to.
/// - Poll at 1 s (cheap property reads); no private hooks, no log parsing.
@MainActor
public final class PrivacyWatch: ObservableObject {
    @Published public private(set) var cameraActive = false
    @Published public private(set) var micActive = false

    public var cameraActiveChanged: ((Bool) -> Void)?
    public var micActiveChanged: ((Bool) -> Void)?

    private var poll: Timer?

    public init() {
        scan()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    public func stop() {
        poll?.invalidate()
        poll = nil
    }

    public var privacyActive: Bool { cameraActive || micActive }

    private func scan() {
        let cam = Self.cameraInUse()
        let mic = Self.micInUse()
        if cam != cameraActive {
            cameraActive = cam
            cameraActiveChanged?(cam)
        }
        if mic != micActive {
            micActive = mic
            micActiveChanged?(mic)
        }
    }

    // MARK: - Pure readers (probed without a camera)

    /// True while any process is capturing from the default input device.
    nonisolated public static func micInUse() -> Bool {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return false }
        var running = UInt32(0)
        var rSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let rStatus = AudioObjectGetPropertyData(id, &runAddr, 0, nil, &rSize, &running)
        return rStatus == noErr && running != 0
    }

    /// True while any process is streaming from any CMIO video device.
    nonisolated public static func cameraInUse() -> Bool {
        var size: UInt32 = 0
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, size, &used, &devices) == noErr
        else { return false }
        for device in devices {
            var running = UInt32(0)
            var runUsed: UInt32 = 0
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let status = CMIOObjectGetPropertyData(device, &runAddr, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size),
                                                   &runUsed, &running)
            if status == noErr, running != 0 { return true }
        }
        return false
    }
}
