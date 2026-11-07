//
// Thin helpers over the Core Audio HAL property API
// (AudioObjectGetPropertyData and friends). Every call names its step, and a
// failure carries that step with the OSStatus, printed as
// "<step> failed (OSStatus <n> '<fourCC>')".
//
// Callers that must fail closed (AudioRoute: a wrong transport type turns
// echo cancellation on over Bluetooth, which silences the mic) wrap these in
// `try?` and treat nil as "unknown".
//

import CoreAudio
import Foundation

enum CoreAudioHAL {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus

        var description: String { "\(step) failed (OSStatus \(status) '\(CoreAudioHAL.fourCC(status))')" }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    /// One fixed-size property value.
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       step: String) throws -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        // Zeroed so a short write leaves zeros, not uninitialised memory.
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw), step)
        return raw.load(as: T.self)
    }

    /// A CFString property (name, UID). A noErr read that returns no string
    /// is a failure with status -1.
    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          step: String) throws -> String {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &value) { ptr in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr), step)
        }
        guard let value else { throw Failure(step: step, status: -1) }
        return value.takeRetainedValue() as String
    }

    /// A variable-length array property (device list, tap list, streams).
    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            step: String) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), step)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw), step)
        let n = Int(size) / MemoryLayout<T>.stride
        return (0..<n).map { raw.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }

    /// An OSStatus as its four-character code when all four bytes are
    /// printable ASCII ('!dev', 'who?'), else as the decimal number.
    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
        return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) ? String(decoding: bytes, as: UTF8.self) : String(status)
    }

    /// e.g. "48000.0Hz/2ch/32bitf/planar/'lpcm'".
    static func describe(_ f: AudioStreamBasicDescription) -> String {
        let float = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(f.mSampleRate)Hz/\(f.mChannelsPerFrame)ch/\(f.mBitsPerChannel)bit\(float ? "f" : "i")/\(interleaved ? "interleaved" : "planar")/'\(fourCC(OSStatus(bitPattern: f.mFormatID)))'"
    }
}
