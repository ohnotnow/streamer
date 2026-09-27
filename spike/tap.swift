// Throwaway spike: can Streamer capture another app's audio with a Core Audio process tap, and
// does the tapped app go quiet while it is captured?
// `list` shows the processes Core Audio knows about. `record` taps every process whose bundle ID
// starts with a prefix, writes what it hears to a WAV file and prints the peak level each second.
// Recording needs its own app bundle: run from a terminal, macOS asks on the terminal's behalf and
// refuses because the terminal has no NSAudioCaptureUsageDescription. `open` makes it ask as itself.
// Build: swiftc -O spike/tap.swift -o spike/tap
//        rm -rf spike/Tap.app && mkdir -p spike/Tap.app/Contents/MacOS
//        cp spike/tap spike/Tap.app/Contents/MacOS/ && cp spike/tap-Info.plist spike/Tap.app/Contents/Info.plist
//        codesign -s - spike/Tap.app
// Run:   spike/tap list
//        open -W --stdout "$PWD/spike/tap.log" spike/Tap.app --args record org.mozilla 20 "$PWD/spike/tap.wav"

import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed: OSStatus \(status)") }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

let system = AudioObjectID(kAudioObjectSystemObject)

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func processObjects() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    check(AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size), "Reading the process list size")
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids), "Reading the process list")
    return ids
}

func describe(_ process: AudioObjectID) -> String {
    let pid = read(process, kAudioProcessPropertyPID, pid_t(0)) ?? 0
    let output = read(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1 ? "playing" : "-"
    let bundleID = readString(process, kAudioProcessPropertyBundleID) ?? "?"
    return "object \(process)  pid \(pid)  \(output)  \(bundleID)"
}

func list() {
    for process in processObjects() { print(describe(process)) }
}

func record(prefix: String, seconds: Double, path: String) throws {
    let targets = processObjects().filter { readString($0, kAudioProcessPropertyBundleID)?.hasPrefix(prefix) == true }
    if targets.isEmpty { fail("No audio process has a bundle ID starting with \(prefix). Try `list`.") }
    print("Tapping:")
    for process in targets { print("  " + describe(process)) }

    let description = CATapDescription(stereoMixdownOfProcesses: targets)
    description.name = "Streamer tap spike"
    description.uuid = UUID()
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    var tapID = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the tap")

    guard var format = read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else {
        fail("Reading the tap format failed")
    }
    print("Tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) channels,",
          "\(format.mBitsPerChannel) bits, flags \(String(format.mFormatFlags, radix: 16))")

    guard let outputDevice = read(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
          let outputUID = readString(outputDevice, kAudioDevicePropertyDeviceUID) else {
        fail("Reading the default output device failed")
    }
    let composition: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Streamer tap spike",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [
            [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Creating the aggregate device")

    guard let avFormat = AVAudioFormat(streamDescription: &format) else { fail("The tap format is not usable") }
    let file = try AVAudioFile(
        forWriting: URL(fileURLWithPath: path), settings: avFormat.settings,
        commonFormat: avFormat.commonFormat, interleaved: avFormat.isInterleaved)

    // Everything below runs on this one queue, so the counters need no locking.
    let queue = DispatchQueue(label: "tap")
    var peak: Float = 0
    var frames = 0
    var procID: AudioDeviceIOProcID?
    check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
        }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
        frames += Int(pcm.frameLength)
        try? file.write(from: pcm)
    }, "Creating the IO proc")
    check(AudioDeviceStart(aggregateID, procID), "Starting the aggregate device")
    print("Recording \(Int(seconds))s to \(path). Firefox should be silent until it finishes.")

    var second = 0
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        second += 1
        let db = peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "silence"
        print("t=\(second)s  peak \(db)  frames \(frames)")
        peak = 0
        if Double(second) >= seconds {
            timer.cancel()
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID!)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            file.close()
            print("Done. Firefox should be audible again.")
            exit(0)
        }
    }
    timer.resume()
    dispatchMain()
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "list":
    list()
case "record" where args.count >= 3:
    try record(
        prefix: args[2],
        seconds: args.count > 3 ? Double(args[3]) ?? 20 : 20,
        path: args.count > 4 ? args[4] : "spike/tap.wav")
default:
    fail("Usage: tap list | tap record <bundle-id-prefix> [seconds] [file.wav]")
}
