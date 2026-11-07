import CoreAudio
import Foundation
import Testing
@testable import Minnas

@Suite struct CaptureSupportTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: RestartBackoff

    @Test func constantsAreUnchanged() {
        #expect(RestartBackoff.baseSeconds == 3)
        #expect(RestartBackoff.maxSeconds == 60)
        #expect(RestartBackoff.attemptsPerBatch == 20)
        #expect(RestartBackoff.retryDelay == .seconds(1))
    }

    /// Every restart after the first that never delivered a buffer doubles
    /// the threshold, up to the 60 s cap.
    @Test func thresholdBacksOffAndCaps() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0)
        var seen = [backoff.threshold]
        for restart in 1...6 {
            // No buffer at all since the attach: a silent restart.
            backoff.noteRestartScheduled(restartsSoFar: restart, lastBufferAt: nil, now: t0)
            seen.append(backoff.threshold)
        }
        #expect(seen == [3, 6, 12, 24, 48, 60, 60])
        #expect(backoff.silentRestarts == 6)
    }

    @Test func firstRestartNeverIncrements() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0)
        backoff.noteRestartScheduled(restartsSoFar: 0, lastBufferAt: nil, now: t0.addingTimeInterval(4))
        #expect(backoff.silentRestarts == 0)
        #expect(backoff.threshold == 3)
    }

    @Test func restartAfterDeliveryResetsSilentRestarts() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0)
        backoff.noteRestartScheduled(restartsSoFar: 1, lastBufferAt: nil, now: t0)
        backoff.noteRestartScheduled(restartsSoFar: 2, lastBufferAt: nil, now: t0)
        #expect(backoff.silentRestarts == 2)
        backoff.noteAttached(at: t0.addingTimeInterval(10))
        // A buffer arrived after the latest attach.
        backoff.noteRestartScheduled(restartsSoFar: 3, lastBufferAt: t0.addingTimeInterval(11), now: t0.addingTimeInterval(20))
        #expect(backoff.silentRestarts == 0)
        #expect(backoff.threshold == 3)
    }

    @Test func bufferBeforeTheAttachCountsAsSilent() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0.addingTimeInterval(10))
        backoff.noteRestartScheduled(restartsSoFar: 1, lastBufferAt: t0.addingTimeInterval(5), now: t0.addingTimeInterval(20))
        #expect(backoff.silentRestarts == 1)
    }

    @Test func stalledSinceIsSetOnceAndClearedOnRecovery() {
        var backoff = RestartBackoff()
        #expect(backoff.stalledSince == nil)
        backoff.noteRestartScheduled(restartsSoFar: 0, lastBufferAt: nil, now: t0)
        backoff.noteRestartScheduled(restartsSoFar: 1, lastBufferAt: nil, now: t0.addingTimeInterval(30))
        #expect(backoff.stalledSince == t0)
        backoff.noteRecovered()
        #expect(backoff.stalledSince == nil)
    }

    /// The stall clock runs from the later of the last buffer and the last
    /// attach, so a fresh attach gets a full threshold even when the last
    /// buffer is old.
    @Test func overdueUsesTheLaterOfLastBufferAndAttach() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0.addingTimeInterval(100))
        let oldBuffer = t0
        #expect(backoff.overdue(lastBufferAt: oldBuffer, now: t0.addingTimeInterval(102)) == nil)
        #expect(backoff.overdue(lastBufferAt: oldBuffer, now: t0.addingTimeInterval(103.5)) == 3)
        // A buffer after the attach moves the clock forward.
        #expect(backoff.overdue(lastBufferAt: t0.addingTimeInterval(110), now: t0.addingTimeInterval(112)) == nil)
        #expect(backoff.overdue(lastBufferAt: t0.addingTimeInterval(110), now: t0.addingTimeInterval(113.5)) == 3)
        // No buffer yet: from the attach.
        #expect(backoff.overdue(lastBufferAt: nil, now: t0.addingTimeInterval(103)) == nil)
        #expect(backoff.overdue(lastBufferAt: nil, now: t0.addingTimeInterval(103.01)) == 3)
    }

    @Test func overdueReportsTheBackedOffThreshold() {
        var backoff = RestartBackoff()
        backoff.noteAttached(at: t0)
        backoff.noteRestartScheduled(restartsSoFar: 1, lastBufferAt: nil, now: t0)
        backoff.noteRestartScheduled(restartsSoFar: 2, lastBufferAt: nil, now: t0)
        #expect(backoff.overdue(lastBufferAt: nil, now: t0.addingTimeInterval(11)) == nil)
        #expect(backoff.overdue(lastBufferAt: nil, now: t0.addingTimeInterval(12.5)) == 12)
    }

    // MARK: Date epoch bits

    @Test func epochBitsRoundTrip() {
        let dates = [t0, Date(timeIntervalSince1970: 1_800_000_000.123456), Date(timeIntervalSince1970: -5)]
        for date in dates {
            #expect(Date(epochBits: date.epochBits) == date)
        }
        #expect(t0.epochBits == t0.timeIntervalSince1970.bitPattern)
    }

    @Test func zeroEpochBitsIsNil() {
        #expect(Date(epochBits: 0) == nil)
    }

    // MARK: Small constants

    @Test func signalEpsilonAndHostClock() {
        #expect(CaptureSignal.epsilon == 0.0001)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        #expect(HostClock.ticksPerSecond == 1e9 * Double(tb.denom) / Double(tb.numer))
    }

    // MARK: CoreAudioHAL

    @Test func fourCCPrintsCodesAndNumbers() {
        #expect(CoreAudioHAL.fourCC(OSStatus(kAudioHardwareBadDeviceError)) == "!dev")
        #expect(CoreAudioHAL.fourCC(OSStatus(kAudioHardwareUnknownPropertyError)) == "who?")
        #expect(CoreAudioHAL.fourCC(-50) == "-50")
        #expect(CoreAudioHAL.fourCC(-1) == "-1")
        #expect(CoreAudioHAL.fourCC(0) == "0")
    }

    @Test func failureDescriptionMatchesTheTapEngineText() {
        let failure = CoreAudioHAL.Failure(step: "create tap", status: OSStatus(kAudioHardwareBadDeviceError))
        let expected = "create tap failed (OSStatus \(kAudioHardwareBadDeviceError) '!dev')"
        #expect(failure.description == expected)
        let tapText = SystemAudioTapError.coreAudio(step: "create tap", status: OSStatus(kAudioHardwareBadDeviceError)).description
        #expect(failure.description == tapText)
        #expect(CoreAudioHAL.Failure(step: "x", status: -50).description == "x failed (OSStatus -50 '-50')")
    }

    @Test func describeInterleavedInt16() {
        let f = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        #expect(CoreAudioHAL.describe(f) == "48000.0Hz/2ch/16biti/interleaved/'lpcm'")
    }

    @Test func describeNonInterleavedFloat32() {
        let f = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        #expect(CoreAudioHAL.describe(f) == "48000.0Hz/2ch/32bitf/planar/'lpcm'")
    }
}
