//
// Queries the current default audio devices' transport types, so the mic's
// echo cancellation can be enabled only when it both helps and works:
//   - helps:  output is the built-in SPEAKERS (audible in the room → the
//             mic picks it up → bleed worth cancelling). Headphones (any
//             transport) play into your ears → no bleed → AEC pointless.
//   - works:  the mic is NOT Bluetooth. AVAudioEngine voice processing over
//             a BT input captures pure silence (macOS VPIO+BT bug).
//
// Unknown/failed lookups conservatively report "not built-in speakers" /
// "is bluetooth-ish" so AEC stays off — a missed AEC is harmless; a wrong
// AEC silences the mic.
//

import CoreAudio
import Foundation

enum AudioRoute {
    /// True when the default output is the built-in speakers (room audio
    /// that the mic can pick up).
    static func defaultOutputIsBuiltInSpeakers() -> Bool {
        transportType(input: false) == kAudioDeviceTransportTypeBuiltIn
    }

    /// True when the default input is a Bluetooth device (VPIO breaks on it).
    static func defaultInputIsBluetooth() -> Bool {
        transportType(input: true) == kAudioDeviceTransportTypeBluetooth
    }

    /// Human-readable name of the current default input device (e.g.
    /// "MacBook Pro Microphone", "iPhone Microphone"). nil if it
    /// can't be read. Used to warn when capture is coming from a device
    /// likely to deliver silence (an iPhone Continuity mic on a call, a
    /// virtual device).
    static func defaultInputDeviceName() -> String? {
        guard let device = defaultDeviceID(input: true) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Whether the default input looks likely to capture silence for a
    /// meeting: an iPhone/iPad Continuity mic (busy when you're on a call) or
    /// a virtual audio device (Zoom/Teams/loopback). Built-in and normal
    /// USB/Bluetooth mics return false.
    static func defaultInputLooksRisky() -> Bool {
        guard let name = defaultInputDeviceName()?.lowercased() else { return false }
        let riskyMarkers = ["iphone", "ipad", "continuity", "zoomaudiodevice", "virtual", "loopback"]
        return riskyMarkers.contains { name.contains($0) }
    }

    private static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func transportType(input: Bool) -> UInt32? {
        guard let device = defaultDeviceID(input: input) else { return nil }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }
}
