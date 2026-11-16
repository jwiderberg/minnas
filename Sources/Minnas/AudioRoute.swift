//
// The current default audio devices, for the mic's logs and the harnesses:
// the input's name (and whether it looks likely to capture silence) and
// whether the output is the built-in speakers. Unknown or failed lookups
// report "not built-in speakers".
//

import CoreAudio
import Foundation

enum AudioRoute {
    /// True when the default output is the built-in speakers (room audio
    /// that the mic can pick up).
    static func defaultOutputIsBuiltInSpeakers() -> Bool {
        transportType(input: false) == kAudioDeviceTransportTypeBuiltIn
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
    // transport type, so an unknown route is "not built-in speakers". The
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
