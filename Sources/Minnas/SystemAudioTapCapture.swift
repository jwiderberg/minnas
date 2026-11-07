//
// System audio capture via a Core Audio process tap (macOS 14.2+).
//
// Why a second engine: ScreenCaptureKit audio rides on the Screen Recording
// grant (and its periodic "is recording your screen" reminders). A process
// tap needs only the narrower "System Audio Recording" grant
// (NSAudioCaptureUsageDescription in Info.plist) and excludes processes
// natively.
//
// The plumbing (Apple: "Capturing system audio with Core Audio taps"):
//   1. CATapDescription(stereoGlobalTapButExcludeProcesses:) — every
//      process's output mixed to stereo, minus the excluded process
//      OBJECTS (Core Audio AudioObjectIDs, not PIDs; translated with
//      kAudioHardwarePropertyTranslatePIDToProcessObject).
//   2. AudioHardwareCreateProcessTap → a tap object. A tap is not a device;
//      nothing can do IO on it directly.
//   3. AudioHardwareCreateAggregateDevice with the tap in
//      kAudioAggregateDeviceTapListKey (kAudioSubTapUIDKey = the tap's
//      UUID) and the current default output device as main sub-device, so
//      the aggregate runs on that device's clock. Private
//      (kAudioAggregateDeviceIsPrivateKey) so it never shows up in other
//      apps' device lists and dies with our process.
//   4. AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart on the
//      aggregate: the tap's audio arrives as the aggregate's (last) input
//      stream. Every other stream is switched off for our IOProc
//      (kAudioDevicePropertyIOProcStreamUsage) so the aggregate never runs
//      the sub-device's input — that would light up a headset mic, or flip
//      AirPods into the low-quality call (HFP) profile for the whole meeting.
//   Teardown is the reverse: AudioDeviceStop, AudioDeviceDestroyIOProcID,
//   AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap —
//   on stop() and on every restart.
// Structure follows Guilherme Rambo's AudioCap sample (MIT,
// github.com/insidegui/AudioCap); the code is our own.
//
// Realtime rule: the IOProc runs on the HAL's IO thread. It only copies
// samples into a preallocated single-producer/single-consumer ring (no
// allocation, no locks, no actors) and is built in a nonisolated static
// func (a closure formed in a @MainActor method inherits main-actor
// isolation and traps on the audio thread — see MicCapture). A 20 ms timer
// on writeQueue drains the ring, resamples to 48 kHz if the device runs at
// another rate, and appends to the AVAssetWriter.
//
// Output: the same CAF the ScreenCaptureKit engine writes (48 kHz stereo
// 16-bit interleaved PCM via the same AVAssetWriter settings), so
// transcription and AudioDuplication can't tell the engines apart.
//
// Alignment: buffers carry their IOProc host time (mach ticks → seconds).
// The file's own timeline is a sample counter; whenever the next buffer's
// host time is ahead of it (a restart, a ring overflow, a dropped append)
// the gap is padded with zeros (≤ 300 s, finite, 2 s writer deadline —
// PaddedCAFWriter, shared with SystemAudioCapture), so the track stays
// aligned with the mic.
//
// Liveness, as SystemAudioCapture: no buffer for 3 s → restart (backing off
// for restarts that never deliver); a restart rebuilds tap + aggregate on
// the CURRENT default output device with the excluded PIDs resolved again.
// A kAudioHardwarePropertyDefaultOutputDevice listener restarts on a
// device switch (the AirPods case). 20 failed restarts → the engine gives
// up for good (gaveUp, running = false: no later health tick or device
// switch starts another batch) and onUnexpectedStop fires once. A teardown
// whose destroy call fails keeps that handle and retries it on the next
// teardown; a rebuild never runs on top of an unreleased tap/aggregate, so
// a destroy that keeps failing counts as a failed restart attempt.
//
// Sample rate: the converter's input rate is the aggregate's tap input
// stream's virtual format (kAudioStreamPropertyVirtualFormat), read at
// build time — that is the format the IOProc actually receives. The tap's
// own kAudioTapPropertyFormat is only the fallback when that query fails;
// both are logged when they differ.
//
// Exclusion limitation: Config.systemAudioExcludedBundleIDs() matches
// EXACT bundle ids. Apps that play audio from a helper process with a
// different bundle id (Teams, Zoom, browsers and other Electron apps can
// route call audio through such helpers) are NOT excluded by listing the
// main app's id — the helper's own id has to be listed. Both the
// NSRunningApplication lookup and the Core Audio process-object bundle-id
// scan below compare for equality, never by prefix.
//
// Permission: there is no API to ask whether "System Audio Recording" is
// granted, and without it the tap silently delivers zeros. 10 s of pure
// digital zeros while buffers keep arriving (≥ 1/s) sets permissionSuspect
// (10, not 15: AppDelegate's silence pre-flight runs 15 s after start and
// reads the flag, so the flag has to be set before then).
// It cannot tell "denied" from "nothing is playing" (a tap of an idle Mac
// is also exact zeros) — it is a hint for the UI, never a reason to stop.
//

import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import Synchronization
import os.log

private let tapLog = Logger(subsystem: "com.jwiderberg.minnas", category: "SystemAudioTapCapture")

enum SystemAudioTapError: Error, CustomStringConvertible {
    case noDefaultOutputDevice
    case coreAudio(step: String, status: OSStatus)
    case writerInitFailed(underlying: Error)
    /// A previous tap / aggregate / IOProc could not be destroyed; building
    /// a new one on top would leak it silently.
    case teardownIncomplete
    /// TAP_TEST_FAIL_RESTARTS=1 (test-only hook, see SystemAudioTapCapture.init).
    case testInjectedRestartFailure

    var description: String {
        switch self {
        case .noDefaultOutputDevice: return "no default output device"
        case .coreAudio(let step, let status): return "\(step) failed (OSStatus \(status) '\(CoreAudioHAL.fourCC(status))')"
        case .writerInitFailed(let underlying): return "asset writer init failed: \(underlying)"
        case .teardownIncomplete: return "previous tap/aggregate not released; refusing to build on top of it"
        case .testInjectedRestartFailure: return "rebuild failed on purpose (TAP_TEST_FAIL_RESTARTS=1)"
        }
    }
}

/// Lock-free SPSC ring of fixed-size slots between the IOProc (producer)
/// and writeQueue (consumer). Everything is allocated up front; the IOProc
/// touches only raw pointers and atomics. Each slot holds up to
/// `slotFrames` interleaved stereo Float32 frames plus their host time and
/// sample rate. 512 × 1024 frames ≈ 10 s at 48 kHz of slack for a writer
/// that stalls; beyond that the IOProc drops and counts (the drain pads).
final class TapRing: @unchecked Sendable {
    static let slotCount = 512          // power of two
    static let slotFrames = 1024
    let samples: UnsafeMutablePointer<Float>
    let hostTimes: UnsafeMutablePointer<UInt64>
    let frameCounts: UnsafeMutablePointer<Int>
    let rates: UnsafeMutablePointer<Double>
    /// Slots written / read so far (monotonic; index = value & mask).
    let head = Atomic<Int>(0)
    let tail = Atomic<Int>(0)
    /// IO cycles delivered (liveness), slots dropped for a full ring, and
    /// the mach time of the last IO cycle.
    let cycles = Atomic<UInt64>(0)
    let overflows = Atomic<UInt64>(0)
    let lastCycleTicks = Atomic<UInt64>(0)

    init() {
        samples = .allocate(capacity: Self.slotCount * Self.slotFrames * 2)
        samples.initialize(repeating: 0, count: Self.slotCount * Self.slotFrames * 2)
        hostTimes = .allocate(capacity: Self.slotCount)
        hostTimes.initialize(repeating: 0, count: Self.slotCount)
        frameCounts = .allocate(capacity: Self.slotCount)
        frameCounts.initialize(repeating: 0, count: Self.slotCount)
        rates = .allocate(capacity: Self.slotCount)
        rates.initialize(repeating: 0, count: Self.slotCount)
    }

    deinit {
        samples.deallocate()
        hostTimes.deallocate()
        frameCounts.deallocate()
        rates.deallocate()
    }
}

/// Hands one buffer to AVAudioConverter's input block, then reports
/// "no data now" (the block may be called again within one convert()).
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Where the tap's samples sit in the aggregate's input buffer list, fixed
/// per build (the IOProc captures a copy).
struct TapLayout: Sendable {
    var bufferIndex: Int     // first ABL buffer belonging to the tap
    var interleaved: Bool    // one buffer with N channels, or one buffer per channel
    var channels: Int
    var sampleRate: Double
}

final class SystemAudioTapCapture: SystemAudioEngine, @unchecked Sendable {
    private let outputURL: URL
    private let ring = TapRing()

    // MARK: Main-actor state (watchdog / restart)
    private var running = false
    private var stoppingByRequest = false
    private var restartTask: Task<Void, Never>?
    private var deviceChangedDuringRestart = false
    /// Terminal: 20 rebuild attempts failed. Set before onUnexpectedStop so
    /// neither checkHealth nor a device switch starts another batch.
    private var gaveUp = false
    private var backoff = RestartBackoff()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private(set) var restartCount = 0
    var stalledSince: Date? { backoff.stalledSince }

    // MARK: controlQueue state (Core Audio objects)
    private let controlQueue = DispatchQueue(label: "minnas.system-tap.control")
    private let listenerQueue = DispatchQueue(label: "minnas.system-tap.listener")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // MARK: writeQueue state (writer, timeline, analysis)
    private let writeQueue: DispatchQueue
    /// The file, confined to writeQueue. Its timeline end is at 48 kHz, in
    /// the host-time domain.
    private let caf: PaddedCAFWriter
    private var drainTimer: DispatchSourceTimer?
    private var padPending = false
    private var seenOverflows: UInt64 = 0
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var zeroRunStart: Double?
    private var zeroRunBuffers = 0
    private var finished = false

    // MARK: Cross-thread counters
    private let peakBits = Atomic<UInt32>(0)
    private let signalLatch = Atomic<Bool>(false)
    private let lastSignalBits = Atomic<UInt64>(0)
    /// Writer drops, failure, padding and timeout; outlives the writer.
    private let cafStats = CAFWriterStats()
    /// Outer bound on stop()'s hop onto writeQueue: longer than the 10 s
    /// finishWriting wait inside finishOnWriteQueue so that wait normally
    /// wins; this one only fires when the queue itself is stuck.
    static let stopDeadline: Double = 15
    private let suspect = Atomic<Bool>(false)

    var onUnexpectedStop: (@Sendable () -> Void)?

    static let fileRate: Double = 48000
    static let suspectAfterSeconds: Double = 10
    /// Aggregate-device UIDs start with this, so the leak check can find ours.
    static let aggregateUIDPrefix = "com.jwiderberg.minnas.tap."

    /// nil only if CoreMedia refuses the description (out of memory);
    /// setUpWriter turns that into a start() error.
    private static let fileFormat: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: fileRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &desc)
        guard status == noErr else {
            tapLog.error("CMAudioFormatDescriptionCreate status \(status, privacy: .public)")
            return nil
        }
        return desc
    }()

    /// TEST-ONLY hook (--tap-test proof of the gave-up path): with
    /// TAP_TEST_FAIL_RESTARTS=1 in the environment every REBUILD throws, so
    /// the 20-attempt batch exhausts. The initial build in start() is
    /// unaffected. Read once here so the restart loop never touches the
    /// environment.
    private let testFailRestarts: Bool

    init(outputURL: URL) {
        self.outputURL = outputURL
        let writeQueue = DispatchQueue(label: "minnas.system-tap.write")
        self.writeQueue = writeQueue
        self.caf = PaddedCAFWriter(queue: writeQueue, stats: cafStats, log: tapLog)
        self.testFailRestarts = ProcessInfo.processInfo.environment["TAP_TEST_FAIL_RESTARTS"] == "1"
        if testFailRestarts {
            tapLog.error("TAP_TEST_FAIL_RESTARTS=1: every tap rebuild will fail (test hook)")
        }
    }

    // MARK: SystemAudioEngine

    var hasSignal: Bool { signalLatch.load(ordering: .relaxed) }
    var lastSignalAt: Date? { Date(epochBits: lastSignalBits.load(ordering: .relaxed)) }
    var lastBufferAt: Date? {
        let ticks = ring.lastCycleTicks.load(ordering: .relaxed)
        guard ticks != 0 else { return nil }
        let ago = Double(mach_absolute_time() &- ticks) / HostClock.ticksPerSecond
        return Date().addingTimeInterval(-max(0, ago))
    }
    var buffersDelivered: UInt64 { ring.cycles.load(ordering: .relaxed) }
    var buffersDropped: UInt64 { cafStats.dropped &+ ring.overflows.load(ordering: .relaxed) }
    var paddedSecondsTotal: Double { cafStats.paddedSeconds }
    var hasWriterFailed: Bool { cafStats.hasFailed }
    var permissionSuspect: Bool { suspect.load(ordering: .relaxed) }

    func snapshotPeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    func start() async throws {
        try await onWriteThrowing { try self.setUpWriter() }
        do {
            try await onControlThrowing { try self.build() }
        } catch {
            await onWrite { self.caf.cancelBeforeFirstAppend() }
            throw error
        }
        await onWrite { self.startDrainTimer() }
        await startOnMain()
    }

    @MainActor
    private func startOnMain() {
        running = true
        backoff.noteAttached()
        installDeviceListener()
    }

    @MainActor
    func checkHealth() {
        guard running, !gaveUp, !stoppingByRequest, restartTask == nil else { return }
        if let threshold = backoff.overdue(lastBufferAt: lastBufferAt) {
            scheduleRestart(reason: "no buffers for \(Int(threshold)) s")
        }
    }

    /// Test hook: stop IO on the aggregate without telling the watchdog, the
    /// way a device going away would.
    func simulateStreamDeath() async {
        await onControl {
            guard self.aggregateID != kAudioObjectUnknown, let proc = self.ioProcID else { return }
            let status = AudioDeviceStop(self.aggregateID, proc)
            tapLog.notice("simulated tap death (AudioDeviceStop status \(status, privacy: .public))")
        }
    }

    @MainActor
    func stop() async {
        stoppingByRequest = true
        running = false
        removeDeviceListener()
        // Let an in-flight rebuild finish before tearing down, so nothing it
        // creates outlives stop().
        if let restartTask {
            restartTask.cancel()
            await restartTask.value
        }
        restartTask = nil
        if await !onControl({ self.teardown() }) {
            // Private objects die with the process; nothing more to retry
            // once this engine is discarded.
            tapLog.error("stop: tap/aggregate could not be fully released (see the destroy errors above)")
        }
        // Bounded hop onto writeQueue. If the queue itself is wedged (an
        // append that never returns), the finish closure never starts and
        // the 10 s wait inside it never arms, so race the hop against a
        // deadline from a global queue; whoever claims the latch first
        // resumes stop(). A finish that lands later still runs on the
        // queue and finalises the file.
        let latch = FinishLatch()
        let finishedInTime: Bool = await withCheckedContinuation { cont in
            writeQueue.async {
                self.finishOnWriteQueue()
                if latch.claim() { cont.resume(returning: true) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.stopDeadline) {
                if latch.claim() { cont.resume(returning: false) }
            }
        }
        if !finishedInTime {
            cafStats.markTimedOut()
            tapLog.error("stop: the finish did not complete within \(Int(Self.stopDeadline), privacy: .public) s of being queued (the write queue was stuck, or the writer wait above also timed out); abandoning the writer")
        }
        tapLog.notice("stop: cycles=\(self.buffersDelivered, privacy: .public) hasSignal=\(self.hasSignal, privacy: .public) restarts=\(self.restartCount, privacy: .public) dropped=\(self.buffersDropped, privacy: .public) paddedSeconds=\(String(format: "%.1f", self.paddedSecondsTotal), privacy: .public) writerFailed=\(self.hasWriterFailed, privacy: .public) writerTimedOut=\(self.cafStats.hasTimedOut, privacy: .public) permissionSuspect=\(self.permissionSuspect, privacy: .public)")
    }

    // MARK: Restart

    @MainActor
    private func scheduleRestart(reason: String, deviceChange: Bool = false, settle: Duration = .zero) {
        guard running, !gaveUp, !stoppingByRequest else { return }
        guard restartTask == nil else {
            if deviceChange { deviceChangedDuringRestart = true }
            return
        }
        backoff.noteRestartScheduled(restartsSoFar: restartCount, lastBufferAt: lastBufferAt)
        tapLog.error("system audio tap restarting (\(reason, privacy: .public))")
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if settle > .zero { try? await Task.sleep(for: settle) }
            var succeeded = false
            for attempt in 1...RestartBackoff.attemptsPerBatch {
                guard self.running, !self.stoppingByRequest, !Task.isCancelled else { break }
                self.deviceChangedDuringRestart = false
                do {
                    let failOnPurpose = self.testFailRestarts
                    try await self.onControlThrowing {
                        // A handle that would not destroy is kept and
                        // retried on the next attempt; never build a second
                        // tap/aggregate beside it.
                        guard self.teardown() else { throw SystemAudioTapError.teardownIncomplete }
                        if failOnPurpose { throw SystemAudioTapError.testInjectedRestartFailure }
                        try self.build()
                    }
                    guard !self.stoppingByRequest, !Task.isCancelled else { break }  // stop() tears down
                    self.backoff.noteAttached()
                    self.restartCount += 1
                    self.backoff.noteRecovered()
                    tapLog.notice("system audio tap rebuilt (\(reason, privacy: .public), attempt \(attempt, privacy: .public))")
                    succeeded = true
                    break
                } catch {
                    tapLog.error("system audio tap rebuild attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    try? await Task.sleep(for: RestartBackoff.retryDelay)
                }
            }
            self.restartTask = nil
            guard self.running, !self.stoppingByRequest else { return }
            if !succeeded {
                // Terminal, and marked so BEFORE the callback: otherwise
                // the next 10 Hz health tick sees running && no restartTask
                // and starts another 20-attempt batch, forever.
                self.gaveUp = true
                self.running = false
                tapLog.error("system audio tap restart gave up after 20 attempts; capture is over until stop()")
                self.onUnexpectedStop?()
                return
            }
            // The default output moved again while we were rebuilding on the
            // previous one.
            if self.deviceChangedDuringRestart {
                self.deviceChangedDuringRestart = false
                self.scheduleRestart(reason: "default output changed during restart", deviceChange: true,
                                     settle: .milliseconds(300))
            }
        }
    }

    @MainActor
    fileprivate func defaultOutputChanged() {
        guard running, !gaveUp, !stoppingByRequest else { return }
        // Connecting AirPods fires this several times in a row; settle
        // briefly so we rebuild once, on the device that stuck.
        scheduleRestart(reason: "default output device changed", deviceChange: true, settle: .milliseconds(300))
    }

    @MainActor
    private func installDeviceListener() {
        var address = CoreAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block = Self.makeDeviceListener(owner: self)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        if status == noErr {
            deviceListener = block
        } else {
            tapLog.error("default-output listener not installed (status \(status, privacy: .public)); device switches rely on the watchdog")
        }
    }

    @MainActor
    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        var address = CoreAudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        deviceListener = nil
    }

    /// nonisolated: the HAL calls this on listenerQueue; a closure formed in
    /// a @MainActor method would carry main-actor isolation there. The hop
    /// to the main actor takes a strong `let` bound inside the block: Swift
    /// 6.2 treats the weak capture box itself as task-isolated and refuses to
    /// send it into the Task (6.3 accepts it). The reference lives only until
    /// the Task runs.
    private nonisolated static func makeDeviceListener(owner: SystemAudioTapCapture) -> AudioObjectPropertyListenerBlock {
        return { [weak owner] _, _ in
            guard let owner else { return }
            Task { @MainActor in owner.defaultOutputChanged() }
        }
    }

    // MARK: Queue bridges

    private func onControlThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            controlQueue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func onControl<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            controlQueue.async { cont.resume(returning: work()) }
        }
    }

    private func onWriteThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            writeQueue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func onWrite(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { cont in
            writeQueue.async { work(); cont.resume() }
        }
    }

    // MARK: Build / teardown (controlQueue only)

    private func build() throws {
        // The handles below would overwrite a leftover one and leak it.
        guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown, ioProcID == nil else {
            throw SystemAudioTapError.teardownIncomplete
        }
        let excluded = Self.excludedProcessObjects()

        let outputID: AudioObjectID = try CoreAudioHAL.get(AudioObjectID(kAudioObjectSystemObject),
                                                           kAudioHardwarePropertyDefaultOutputDevice, step: "read default output device")
        guard outputID != kAudioObjectUnknown else { throw SystemAudioTapError.noDefaultOutputDevice }
        let outputUID = try CoreAudioHAL.getString(outputID, kAudioDevicePropertyDeviceUID, step: "read output device UID")

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded.objects)
        description.name = "Minnas system audio"
        description.uuid = UUID()
        description.isPrivate = true          // visible to this process only
        description.muteBehavior = .unmuted   // the user keeps hearing everything
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioHAL.check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap")
        tapID = newTap

        do {
            let tapFormat: AudioStreamBasicDescription = try CoreAudioHAL.get(newTap, kAudioTapPropertyFormat, step: "read tap format")

            let aggregateUID = Self.aggregateUIDPrefix + UUID().uuidString
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Minnas Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 0,
                // Off on purpose: with tap auto-start, IO waits until some
                // tapped process plays, so a quiet start would deliver no
                // buffers — the watchdog would read that as a dead tap and
                // the file would lose wall-clock time to the 300 s pad cap.
                // Without it the aggregate runs on the output device's clock
                // and the tap delivers zeros while nothing plays.
                kAudioAggregateDeviceTapAutoStartKey: 0,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    // The tap mixes processes on other devices' clocks too;
                    // let the aggregate resample them to the main device.
                    kAudioSubTapDriftCompensationKey: 1,
                ]],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate),
                                   "AudioHardwareCreateAggregateDevice")
            aggregateID = newAggregate

            // The tap's stream comes after the sub-device's own input
            // streams (a USB headset or a virtual device has some; speakers don't).
            let inputStreams = try CoreAudioHAL.getArray(newAggregate, kAudioDevicePropertyStreams, AudioObjectID.self,
                                                         scope: kAudioObjectPropertyScopeInput, step: "read aggregate input streams")
            let outputStreams = (try? CoreAudioHAL.getArray(newAggregate, kAudioDevicePropertyStreams, AudioObjectID.self,
                                                            scope: kAudioObjectPropertyScopeOutput, step: "read aggregate output streams")) ?? []
            guard let tapStream = inputStreams.last else {
                throw SystemAudioTapError.coreAudio(step: "aggregate has no input stream for the tap", status: -1)
            }
            // What the IOProc receives is the aggregate's tap stream in its
            // virtual format, on the main sub-device's clock — not
            // necessarily what the tap object reports. That format is the
            // converter's input; the tap's is only a fallback.
            let streamFormat: AudioStreamBasicDescription
            let formatSource: String
            do {
                streamFormat = try CoreAudioHAL.get(tapStream, kAudioStreamPropertyVirtualFormat, step: "read tap stream virtual format")
                formatSource = "stream"
            } catch {
                tapLog.error("tap stream format unreadable (\(String(describing: error), privacy: .public)); using the tap's own format \(CoreAudioHAL.describe(tapFormat), privacy: .public)")
                streamFormat = tapFormat
                formatSource = "tap(fallback)"
            }
            if streamFormat.mSampleRate != tapFormat.mSampleRate
                || streamFormat.mChannelsPerFrame != tapFormat.mChannelsPerFrame
                || streamFormat.mFormatFlags != tapFormat.mFormatFlags {
                tapLog.notice("tap stream format \(CoreAudioHAL.describe(streamFormat), privacy: .public) differs from tap format \(CoreAudioHAL.describe(tapFormat), privacy: .public); using the stream's")
            }
            // The IOProc reads Float32 samples; anything else would be
            // copied as garbage.
            guard streamFormat.mFormatID == kAudioFormatLinearPCM,
                  streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  streamFormat.mBitsPerChannel == 32,
                  streamFormat.mSampleRate > 0, streamFormat.mSampleRate.isFinite else {
                throw SystemAudioTapError.coreAudio(step: "tap stream format \(CoreAudioHAL.describe(streamFormat)) is not Float32 PCM",
                                                    status: -1)
            }
            let interleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            let channels = max(1, Int(streamFormat.mChannelsPerFrame))
            let tapBuffers = interleaved ? 1 : channels
            let layout = TapLayout(bufferIndex: max(0, inputStreams.count - tapBuffers), interleaved: interleaved,
                                   channels: channels, sampleRate: streamFormat.mSampleRate)

            var newProc: AudioDeviceIOProcID?
            try CoreAudioHAL.check(AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, nil,
                                                                      Self.makeIOBlock(ring: ring, layout: layout)),
                                   "AudioDeviceCreateIOProcIDWithBlock")
            guard let proc = newProc else {
                throw SystemAudioTapError.coreAudio(step: "AudioDeviceCreateIOProcIDWithBlock returned no IOProc id", status: -1)
            }
            ioProcID = proc
            let usageOK = try Self.restrictStreamUsage(device: newAggregate, proc: proc, inputCount: inputStreams.count,
                                                       tapRange: layout.bufferIndex..<(layout.bufferIndex + tapBuffers),
                                                       outputCount: outputStreams.count)
            try CoreAudioHAL.check(AudioDeviceStart(newAggregate, proc), "AudioDeviceStart")

            tapLog.notice("tap capture up: output=\(outputUID, privacy: .public) format(\(formatSource, privacy: .public))=\(CoreAudioHAL.describe(streamFormat), privacy: .public) tapFormat=\(CoreAudioHAL.describe(tapFormat), privacy: .public) aggregateInputStreams=\(inputStreams.count, privacy: .public) outputStreams=\(outputStreams.count, privacy: .public) tapBuffer=\(layout.bufferIndex, privacy: .public) streamUsageRestricted=\(usageOK, privacy: .public) excluded=\(excluded.summary, privacy: .public)")
        } catch {
            teardown()
            throw error
        }
    }

    /// Idempotent: releases whatever exists, in reverse creation order.
    /// A handle whose destroy call fails is KEPT (and logged with its
    /// status) so the next teardown retries it instead of forgetting a live
    /// aggregate or tap. Returns true when nothing is left.
    @discardableResult
    private func teardown() -> Bool {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            let stopStatus = AudioDeviceStop(aggregateID, proc)
            if stopStatus != noErr {
                // Not a handle; the destroy below still runs (it is what
                // releases the IOProc).
                tapLog.error("teardown: AudioDeviceStop status \(stopStatus, privacy: .public) '\(CoreAudioHAL.fourCC(stopStatus), privacy: .public)'")
            }
            let status = AudioDeviceDestroyIOProcID(aggregateID, proc)
            if status == noErr {
                ioProcID = nil
            } else {
                tapLog.error("teardown: AudioDeviceDestroyIOProcID status \(status, privacy: .public) '\(CoreAudioHAL.fourCC(status), privacy: .public)'; keeping the IOProc id to retry")
            }
        }
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr {
                aggregateID = AudioObjectID(kAudioObjectUnknown)
                // The IOProc belonged to the aggregate and is gone with it.
                ioProcID = nil
            } else {
                tapLog.error("teardown: AudioHardwareDestroyAggregateDevice status \(status, privacy: .public) '\(CoreAudioHAL.fourCC(status), privacy: .public)'; keeping aggregate \(self.aggregateID, privacy: .public) to retry")
            }
        } else {
            // No aggregate means no IOProc can exist.
            ioProcID = nil
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                tapID = AudioObjectID(kAudioObjectUnknown)
            } else {
                tapLog.error("teardown: AudioHardwareDestroyProcessTap status \(status, privacy: .public) '\(CoreAudioHAL.fourCC(status), privacy: .public)'; keeping tap \(self.tapID, privacy: .public) to retry")
            }
        }
        return tapID == kAudioObjectUnknown && aggregateID == kAudioObjectUnknown && ioProcID == nil
    }

    /// The IOProc. Realtime thread: copy into the ring and count, nothing
    /// else. nonisolated static so the closure has no actor isolation.
    private nonisolated static func makeIOBlock(ring: TapRing, layout: TapLayout) -> AudioDeviceIOBlock {
        let mask = TapRing.slotCount - 1
        let slotFrames = TapRing.slotFrames
        let ticksPerFrame = HostClock.ticksPerSecond / max(1, layout.sampleRate)
        return { _, inInputData, inInputTime, outOutputData, _ in
            let now = mach_absolute_time()
            ring.cycles.wrappingAdd(1, ordering: .relaxed)
            ring.lastCycleTicks.store(now, ordering: .relaxed)

            // We never play anything; make sure whatever output streams are
            // still enabled carry silence.
            let outs = UnsafeMutableAudioBufferListPointer(outOutputData)
            for out in outs where out.mData != nil {
                memset(out.mData, 0, Int(out.mDataByteSize))
            }

            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let needed = layout.interleaved ? 1 : min(2, layout.channels)
            guard ins.count >= layout.bufferIndex + needed else { return }
            let first = ins[layout.bufferIndex]
            guard let firstData = first.mData else { return }
            let left = firstData.assumingMemoryBound(to: Float.self)
            let frames: Int
            let stride: Int
            var right = left
            if layout.interleaved {
                stride = max(1, Int(first.mNumberChannels))
                frames = Int(first.mDataByteSize) / (4 * stride)
                if stride >= 2 { right = left + 1 }
            } else {
                stride = 1
                frames = Int(first.mDataByteSize) / 4
                if needed == 2, let r = ins[layout.bufferIndex + 1].mData {
                    right = r.assumingMemoryBound(to: Float.self)
                }
            }
            guard frames > 0 else { return }
            let startTicks = inInputTime.pointee.mFlags.contains(.hostTimeValid) ? inInputTime.pointee.mHostTime : now

            var offset = 0
            while offset < frames {
                let h = ring.head.load(ordering: .relaxed)
                let t = ring.tail.load(ordering: .acquiring)
                if h &- t >= TapRing.slotCount {
                    ring.overflows.wrappingAdd(1, ordering: .relaxed)
                    return
                }
                let slot = h & mask
                let n = min(slotFrames, frames - offset)
                let dest = ring.samples + slot * slotFrames * 2
                var i = 0
                while i < n {
                    let s = (offset + i) * stride
                    dest[2 * i] = left[s]
                    dest[2 * i + 1] = right[s]
                    i += 1
                }
                ring.hostTimes[slot] = startTicks &+ UInt64(Double(offset) * ticksPerFrame)
                ring.frameCounts[slot] = n
                ring.rates[slot] = layout.sampleRate
                ring.head.store(h &+ 1, ordering: .releasing)
                offset += n
            }
        }
    }

    // MARK: Writer (writeQueue only)

    /// PaddedCAFWriter's open errors, as the NSError domain/codes this
    /// engine has always reported (-1 start, -2 format, -3 canAdd).
    private func setUpWriter() throws {
        guard let fileFormat = Self.fileFormat else {
            throw SystemAudioTapError.writerInitFailed(
                underlying: NSError(domain: "SystemAudioTapCapture", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "could not create the 48 kHz Float32 format description"]))
        }
        do throws(PaddedCAFWriter.OpenError) {
            try caf.open(url: outputURL, sourceFormatHint: fileFormat)
        } catch {
            switch error {
            case .create(let underlying):
                throw SystemAudioTapError.writerInitFailed(underlying: underlying)
            case .inputRefused:
                throw SystemAudioTapError.writerInitFailed(
                    underlying: NSError(domain: "SystemAudioTapCapture", code: -3,
                                        userInfo: [NSLocalizedDescriptionKey: "asset writer refused the audio input (canAdd == false)"]))
            case .startFailed(let underlying):
                throw SystemAudioTapError.writerInitFailed(
                    underlying: underlying ?? NSError(domain: "SystemAudioTapCapture", code: -1))
            }
        }
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func finishOnWriteQueue() {
        drainTimer?.cancel()
        drainTimer = nil
        drain()
        finished = true
        // Bounded: a wedged writer must not hang stop() forever; on timeout
        // the writer is abandoned (never cancelled, which would delete the
        // file) and cafStats records it.
        _ = caf.finishBlocking(timeout: PaddedCAFWriter.finishTimeout)
    }

    /// Moves every filled slot from the ring into the file.
    private func drain() {
        guard !finished else { return }
        let mask = TapRing.slotCount - 1
        let overflows = ring.overflows.load(ordering: .relaxed)
        if overflows != seenOverflows {
            seenOverflows = overflows
            padPending = true
            tapLog.error("tap ring overflowed (\(overflows, privacy: .public) slots dropped so far); the hole will be padded")
        }
        while true {
            let t = ring.tail.load(ordering: .relaxed)
            let h = ring.head.load(ordering: .acquiring)
            guard t != h else { break }
            let slot = t & mask
            let frames = ring.frameCounts[slot]
            let rate = ring.rates[slot]
            let hostSeconds = Double(ring.hostTimes[slot]) / HostClock.ticksPerSecond
            let samples = UnsafePointer(ring.samples + slot * TapRing.slotFrames * 2)
            analyze(samples, count: frames * 2, hostSeconds: hostSeconds)
            if rate == Self.fileRate {
                append(UnsafeRawPointer(samples), frames: frames, hostSeconds: hostSeconds)
            } else {
                resampleAndAppend(samples, frames: frames, rate: rate, hostSeconds: hostSeconds)
            }
            ring.tail.store(t &+ 1, ordering: .releasing)
        }
    }

    /// Peak meter, signal latch, and the permission heuristic.
    private func analyze(_ samples: UnsafePointer<Float>, count: Int, hostSeconds: Double) {
        var peak: Float = 0
        var anyNonZero = false
        for i in 0..<count {
            let v = samples[i]
            if v != 0 { anyNonZero = true }
            let a = abs(v)
            if a > peak { peak = a }
        }
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        if peak > CaptureSignal.epsilon {
            signalLatch.store(true, ordering: .relaxed)
            lastSignalBits.store(Date().epochBits, ordering: .relaxed)
        }
        if anyNonZero {
            zeroRunStart = nil
            zeroRunBuffers = 0
            if suspect.exchange(false, ordering: .relaxed) {
                tapLog.notice("system audio tap has signal again; permissionSuspect cleared")
            }
            return
        }
        if zeroRunStart == nil { zeroRunStart = hostSeconds }
        zeroRunBuffers += 1
        let run = hostSeconds - (zeroRunStart ?? hostSeconds)
        if run >= Self.suspectAfterSeconds, Double(zeroRunBuffers) >= run, !suspect.load(ordering: .relaxed) {
            suspect.store(true, ordering: .relaxed)
            tapLog.error("system audio tap: \(Int(run), privacy: .public) s of pure digital zeros while buffers keep arriving — System Audio Recording permission may be missing (or nothing is playing)")
        }
    }

    /// `rate` is the slot's rate, i.e. the tap stream's virtual-format rate
    /// read at build time (see build()); the ring always holds interleaved
    /// stereo Float32, so that rate is all the converter's input format
    /// needs from the device.
    private func resampleAndAppend(_ samples: UnsafePointer<Float>, frames: Int, rate: Double, hostSeconds: Double) {
        if converter == nil || converterRate != rate {
            guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true),
                  let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.fileRate, channels: 2, interleaved: true),
                  let c = AVAudioConverter(from: inFormat, to: outFormat) else {
                tapLog.error("no converter from \(rate, privacy: .public) Hz; dropping tap audio")
                return
            }
            tapLog.notice("tap delivers \(rate, privacy: .public) Hz; resampling to 48 kHz")
            converter = c
            converterRate = rate
        }
        guard let converter,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                               frameCapacity: AVAudioFrameCount(Double(frames) * Self.fileRate / rate) + 64),
              let inData = inBuffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        inData.copyMemory(from: samples, byteCount: frames * 8)
        // The input block is @Sendable; it runs synchronously inside
        // convert() on this queue, so a one-shot box is enough.
        let feed = OneShotInput(inBuffer)
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            guard let buffer = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuffer.frameLength > 0,
              let outData = outBuffer.audioBufferList.pointee.mBuffers.mData else { return }
        append(UnsafeRawPointer(outData), frames: Int(outBuffer.frameLength), hostSeconds: hostSeconds)
    }

    /// Appends 48 kHz interleaved stereo Float32 frames at the file's
    /// timeline end, padding first when the buffer's host time is ahead of it.
    private func append(_ data: UnsafeRawPointer, frames: Int, hostSeconds: Double) {
        guard caf.isOpen, frames > 0, let fileFormat = Self.fileFormat else { return }
        if !caf.sessionStarted {
            caf.startSession(atSourceTime: CMTime(value: CMTimeValue((hostSeconds * Self.fileRate).rounded()),
                                                  timescale: CMTimeScale(Self.fileRate)),
                             seedTimeline: true)
        } else {
            let gap = hostSeconds - caf.timelineEnd.seconds
            // 50 ms swallows host-time jitter and resampler latency; after a
            // known hole (drop/overflow) any measurable gap is real.
            if gap > 0.05 || (padPending && gap > 0.002) {
                fillGap(seconds: gap, format: fileFormat)
            }
        }
        padPending = false

        // Not the realtime thread, so a short wait is fine; past it the
        // buffer is dropped and the next one pads the hole.
        switch caf.appendFrames(data, frames: frames, format: fileFormat, readyWait: 0.1) {
        case .appended, .writerFailed:
            break
        case .dropped(let dropped):
            if dropped == 1 || dropped.isMultiple(of: 100) {
                tapLog.error("writer input not ready; dropped tap buffer (\(dropped, privacy: .public) so far)")
            }
            padPending = true
        }
    }

    /// Zeros covering `gap` seconds from the timeline end (PaddedCAFWriter:
    /// capped, finite, 2 s writer deadline).
    private func fillGap(seconds gap: Double, format: CMAudioFormatDescription) {
        switch caf.fillGap(seconds: gap, format: format) {
        case .noTimeline, .belowMinimum:
            break
        case .rejected(let gap):
            tapLog.error("system-audio tap gap \(String(format: "%.3f", gap), privacy: .public) s is non-finite or over the \(Int(PaddedCAFWriter.maxFillSeconds), privacy: .public) s cap; not padding it")
        case .filled(let padded, let gap):
            if padded >= 0.25 {
                tapLog.notice("padded system track with \(String(format: "%.2f", padded), privacy: .public) s of silence (gap \(String(format: "%.2f", gap), privacy: .public) s)")
            }
        }
    }

    // MARK: Exclusions

    /// Process objects to keep out of the tap: every running app whose
    /// bundle id is configured (by PID, via NSRunningApplication), any
    /// Core Audio process object reporting that bundle id itself, and this
    /// process. Resolved on every (re)build, so an app launched mid-call is
    /// excluded from the next restart on. A process that has never touched
    /// audio has no process object yet and can't be listed.
    private static func excludedProcessObjects() -> (objects: [AudioObjectID], summary: String) {
        let bundleIDs = Set(Config.systemAudioExcludedBundleIDs())
        var objects = Set<AudioObjectID>()
        var matched: [String] = []
        var pids: [pid_t] = [getpid()]
        for id in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                pids.append(app.processIdentifier)
                matched.append("\(id)(\(app.processIdentifier))")
            }
        }
        for pid in pids {
            var qualifier = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = CoreAudioHAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
            if status == noErr, object != kAudioObjectUnknown { objects.insert(object) }
        }
        if !bundleIDs.isEmpty,
           let all = try? CoreAudioHAL.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                                AudioObjectID.self, step: "list process objects") {
            for object in all where !objects.contains(object) {
                if let bundle = try? CoreAudioHAL.getString(object, kAudioProcessPropertyBundleID, step: "process bundle id"),
                   bundleIDs.contains(bundle) {
                    objects.insert(object)
                    matched.append("\(bundle)[obj \(object)]")
                }
            }
        }
        let configured = bundleIDs.isEmpty ? "none" : bundleIDs.sorted().joined(separator: ",")
        let summary = "configured=\(configured) running=\(matched.isEmpty ? "none" : matched.joined(separator: ",")) processObjects=\(objects.count)"
        return (objects.sorted(), summary)
    }

    // MARK: Stream usage

    /// Switches off, for our IOProc only, every aggregate stream except the
    /// tap's. Returns false (and leaves everything on) if the HAL refuses —
    /// capture still works, the sub-device input just runs needlessly.
    /// Throws only if the imported struct's field offsets are unavailable
    /// (offset(of:) is nil for a non-stored property) — writing the
    /// variable-length struct by hand would then be guesswork.
    private static func restrictStreamUsage(device: AudioObjectID, proc: AudioDeviceIOProcID, inputCount: Int,
                                            tapRange: Range<Int>, outputCount: Int) throws -> Bool {
        guard let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn),
              let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mNumberStreams) else {
            throw SystemAudioTapError.coreAudio(step: "AudioHardwareIOProcStreamUsage field offsets unavailable", status: -1)
        }
        func apply(scope: AudioObjectPropertyScope, count: Int, keep: Range<Int>) -> Bool {
            guard count > 0 else { return true }
            let byteCount = max(flagsOffset + 4 * count, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
            raw.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
            var address = CoreAudioHAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
            var size = UInt32(byteCount)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return false }
            for i in 0..<count {
                raw.storeBytes(of: keep.contains(i) ? UInt32(1) : UInt32(0), toByteOffset: flagsOffset + 4 * i, as: UInt32.self)
            }
            return AudioObjectSetPropertyData(device, &address, 0, nil, size, raw) == noErr
        }
        let inputOK = apply(scope: kAudioObjectPropertyScopeInput, count: inputCount, keep: tapRange)
        let outputOK = apply(scope: kAudioObjectPropertyScopeOutput, count: outputCount, keep: 0..<0)
        return inputOK && outputOK
    }

    // MARK: Leak check (harness)

    /// Live Core Audio tap objects and aggregate devices of ours, as seen
    /// from this process (private ones are invisible to everyone else).
    static func liveObjectCounts() -> (taps: Int, aggregates: Int) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let taps = (try? CoreAudioHAL.getArray(system, kAudioHardwarePropertyTapList, AudioObjectID.self, step: "list taps"))?.count ?? -1
        let devices = (try? CoreAudioHAL.getArray(system, kAudioHardwarePropertyDevices, AudioObjectID.self, step: "list devices")) ?? []
        let ours = devices.filter { ((try? CoreAudioHAL.getString($0, kAudioDevicePropertyDeviceUID, step: "uid")) ?? "").hasPrefix(aggregateUIDPrefix) }
        return (taps, ours.count)
    }
}
