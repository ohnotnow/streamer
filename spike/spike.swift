// Throwaway spike: one file, decoded, encoded to AAC, ADTS-framed, served at
// http://127.0.0.1:8090/stream at real-time pace. Loops the file forever.
// Build: swiftc -O spike/spike.swift -o spike/spike
// Run:   spike/spike music_to_be_murdered_by.mp3

import AVFoundation
import Foundation
import Network

let sampleRate = 44100.0
let channels: AVAudioChannelCount = 2
let bitRate = 192_000
let framesPerPacket = 1024.0
let leadSeconds = 2.0

let queue = DispatchQueue(label: "spike")

// MARK: ADTS

func adtsHeader(payloadLength: Int) -> [UInt8] {
    let length = payloadLength + 7
    let profile = 1  // AAC LC (object type 2) minus 1
    let frequencyIndex = 4  // 44100 Hz
    let channelConfig = Int(channels)
    return [
        0xFF,
        0xF1,  // MPEG-4, layer 0, no CRC
        UInt8((profile << 6) | (frequencyIndex << 2) | (channelConfig >> 2)),
        UInt8(((channelConfig & 3) << 6) | (length >> 11)),
        UInt8((length >> 3) & 0xFF),
        UInt8(((length & 7) << 5) | 0x1F),
        0xFC,
    ]
}

// MARK: Decoding (one fixed PCM format whatever the file is)

let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)!

final class Decoder {
    let url: URL
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?

    init(url: URL) { self.url = url }

    func open() {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .audio).first!
        let reader = try! AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        reader.startReading()
        self.reader = reader
        self.output = output
        log("opened \(url.lastPathComponent)")
    }

    /// Next chunk of PCM, reopening the file at the end (stands in for "next track").
    func next() -> AVAudioPCMBuffer {
        if output == nil { open() }
        guard let sample = output!.copyNextSampleBuffer() else {
            log("end of file, looping")
            output = nil
            return next()
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return buffer
    }
}

// MARK: Encoding

var aacDescription = AudioStreamBasicDescription(
    mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
    mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
    mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
let aacFormat = AVAudioFormat(streamDescription: &aacDescription)!

final class Encoder {
    let decoder: Decoder
    let converter = AVAudioConverter(from: pcmFormat, to: aacFormat)!

    init(decoder: Decoder) {
        self.decoder = decoder
        converter.bitRate = bitRate
    }

    /// Some ADTS frames; the converter pulls PCM from the decoder as it needs it.
    func nextFrames() -> [Data] {
        let out = AVAudioCompressedBuffer(
            format: aacFormat, packetCapacity: 16,
            maximumPacketSize: converter.maximumOutputPacketSize)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .haveData
            return self.decoder.next()
        }
        guard status != .error else { fatalError("encode failed: \(String(describing: error))") }

        var frames: [Data] = []
        for i in 0..<Int(out.packetCount) {
            let packet = out.packetDescriptions![i]
            var frame = Data(adtsHeader(payloadLength: Int(packet.mDataByteSize)))
            frame.append(
                out.data.advanced(by: Int(packet.mStartOffset))
                    .assumingMemoryBound(to: UInt8.self),
                count: Int(packet.mDataByteSize))
            frames.append(frame)
        }
        return frames
    }
}

// MARK: Broadcasting (paced, pauses with no listeners)

final class Broadcaster {
    let encoder: Encoder
    var listeners: [ObjectIdentifier: NWConnection] = [:]
    var startedAt: Date?
    var packetsSent = 0.0
    var pending: [Data] = []
    var timer: DispatchSourceTimer?

    init(encoder: Encoder) { self.encoder = encoder }

    func add(_ connection: NWConnection) {
        listeners[ObjectIdentifier(connection)] = connection
        log("listener joined (\(listeners.count))")
        if timer == nil { start() }
    }

    func remove(_ connection: NWConnection) {
        guard listeners.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
        log("listener left (\(listeners.count))")
        if listeners.isEmpty { pause() }
    }

    func start() {
        startedAt = Date()
        packetsSent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("encoding")
    }

    func pause() {
        timer?.cancel()
        timer = nil
        log("paused, nobody listening")
    }

    func tick() {
        let due = (Date().timeIntervalSince(startedAt!) + leadSeconds) * sampleRate / framesPerPacket
        while packetsSent < due {
            if pending.isEmpty { pending = encoder.nextFrames() }
            let frame = pending.removeFirst()
            for connection in listeners.values {
                connection.send(content: frame, completion: .contentProcessed { error in
                    if error != nil { queue.async { self.remove(connection) } }
                })
            }
            packetsSent += 1
        }
    }
}

// MARK: Server

let streamHeaders = """
    HTTP/1.1 200 OK\r
    Content-Type: audio/aac\r
    Cache-Control: no-cache\r
    Connection: close\r
    \r

    """

func serve(broadcaster: Broadcaster) throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8090)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: broadcaster.remove(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.split(separator: "\r\n").first ?? ""
            log("request: \(firstLine)")
            if firstLine.hasPrefix("GET /stream ") {
                connection.send(content: streamHeaders.data(using: .utf8), completion: .idempotent)
                broadcaster.add(connection)
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
    listener.stateUpdateHandler = { log("server: \($0)") }
    listener.start(queue: queue)
    return listener
}

func log(_ message: String) {
    let time = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("\(time) \(message)")
    fflush(stdout)
}

// MARK: Main

let path = CommandLine.arguments.dropFirst().first ?? "music_to_be_murdered_by.mp3"
let broadcaster = Broadcaster(encoder: Encoder(decoder: Decoder(url: URL(fileURLWithPath: path))))
let listener = try serve(broadcaster: broadcaster)
log("http://127.0.0.1:8090/stream")
dispatchMain()
