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
    /// "MacBook Pro Microphone", "<name> iPhone Microphone"). nil if it
    /// can't be read. Used to warn when capture is coming from a device
    /// likely to deliver silence (an iPhone Continuity mic on a call, a
    /// virtual device).
    static func defaultInputDeviceName() -> String? {
        guard let device = defaultDeviceID(input: true) else { return nil }
        return try? CoreAudioHAL.getString(device, kAudioObjectPropertyName, step: "default input name")
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

    // Both lookups map any failure to nil (`try?`), and nil equals no
    // transport type, which is what keeps AEC off on an unknown route. The
    // `as` pins the generic to the plain integer type: an inferred Optional
    // would ask the HAL for a 5-byte value.

    private static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice
        return try? CoreAudioHAL.get(
            AudioObjectID(kAudioObjectSystemObject), selector,
            step: input ? "default input device" : "default output device") as AudioDeviceID
    }

    private static func transportType(input: Bool) -> UInt32? {
        guard let device = defaultDeviceID(input: input) else { return nil }
        return try? CoreAudioHAL.get(device, kAudioDevicePropertyTransportType, step: "transport type") as UInt32
    }
}
