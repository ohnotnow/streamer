import AVFoundation
import CoreAudio

/// Another app's audio as it plays, through a Core Audio process tap, handed on in
/// `TrackDecoder.pcmFormat`. The app goes quiet at the desk while the tap is read and plays normally
/// again once it stops (`mutedWhenTapped`).
///
/// Needs NSAudioCaptureUsageDescription in Info.plist. Without it, or if the user says no, the tap
/// still runs but every sample is zero, and the app is muted all the same (found 2026-09-27 with
/// spike/tap.swift). `LiveBroadcaster` warns about a long silence for that reason.
@MainActor
final class ProcessTap: LiveFeed {
    enum Failure: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)

        var description: String {
            switch self {
            case .coreAudio(let what, let status): "\(what) failed (OSStatus \(status))"
            }
        }
    }

    /// Exact bundle IDs, e.g. Chrome plays from `com.google.Chrome.helper`, not `com.google.Chrome`.
    let bundleIDs: [String]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Where Core Audio calls with each buffer, and where it is converted.
    private let queue = DispatchQueue(label: "uk.ohnotnow.streamer.tap")

    init(bundleIDs: [String]) {
        self.bundleIDs = bundleIDs
    }

    func start(deliver: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {
        do {
            try open(deliver: deliver)
        } catch {
            stop()
            throw error
        }
    }

    /// Safe to call more than once.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func open(deliver: @escaping @MainActor (AVAudioPCMBuffer) -> Void) throws {
        // The processes running now, and the bundle IDs so ones that start later (Chrome's helpers
        // come and go) join the tap too.
        let description = CATapDescription(stereoMixdownOfProcesses: runningProcesses())
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = true
        description.name = "Streamer"
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the tap")

        // A tap is read through an aggregate device, clocked by the current output device.
        let outputDevice = try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        let outputUID = try Self.readString(outputDevice, kAudioDevicePropertyDeviceUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Streamer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Creating the aggregate device")

        // The aggregate delivers at the output device's rate, whatever the tap's own format says:
        // with 44.1 kHz Bluetooth headphones, trusting the tap's rate made speech audibly fast (2026-09-27).
        var format = try Self.read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        format.mSampleRate = try Self.read(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        guard let tapFormat = AVAudioFormat(streamDescription: &format),
              let converter = AVAudioConverter(from: tapFormat, to: TrackDecoder.pcmFormat) else {
            throw Failure.coreAudio("Reading the tap format", kAudioHardwareUnsupportedOperationError)
        }

        let block = Self.ioBlock(resampler: Resampler(converter: converter, inputFormat: tapFormat), deliver: deliver)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, block), "Creating the IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Starting the aggregate device")
    }

    /// Made outside the main actor on purpose. Written inline in `open`, the block inherited main-actor
    /// isolation and Swift 6 checked the executor when Core Audio called it on its own thread: a
    /// crash (dispatch_assert_queue) on the first buffer (2026-09-27).
    private nonisolated static func ioBlock(resampler: Resampler, deliver: @escaping @MainActor (AVAudioPCMBuffer) -> Void) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            guard let buffer = resampler.convert(input) else { return }
            let handOver = HandOver(buffer: buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(handOver.buffer) } }
        }
    }

    /// Process objects for the bundle IDs that Core Audio knows about now.
    private func runningProcesses() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (try? Self.readString($0, kAudioProcessPropertyBundleID)).map(bundleIDs.contains) == true }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw Failure.coreAudio(what, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        if status != noErr { throw Failure.coreAudio("Reading property \(selector)", status) }
        return value
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw Failure.coreAudio("Reading property \(selector)", status) }
        return value.takeRetainedValue() as String
    }
}

/// Converts the tap's buffers (float, at the output device's rate) to `TrackDecoder.pcmFormat`. Used only
/// on the tap's queue. One converter for the whole run, so the resampling carries on smoothly from
/// one buffer to the next.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat) {
        self.converter = converter
        self.inputFormat = inputFormat
    }

    /// A new buffer, since the input is only valid during Core Audio's call.
    func convert(_ input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil) else { return nil }
        let ratio = TrackDecoder.pcmFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: TrackDecoder.pcmFormat, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // "No data now", never "end of stream", which would flush the converter.
            guard !handedOver else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Carries a freshly made buffer from the tap's queue to the main actor. Nothing else holds it.
private struct HandOver: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
