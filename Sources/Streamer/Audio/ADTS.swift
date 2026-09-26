/// The 7-byte ADTS header that turns bare AAC packets into a stream players can join at any
/// frame. Fixed to the pipeline's one format: AAC LC, 44.1 kHz, stereo, no CRC.
enum ADTS {
    static let headerLength = 7

    static func header(payloadLength: Int) -> [UInt8] {
        let length = payloadLength + headerLength  // 13 bits, header included
        let profile = 1  // AAC LC is object type 2, written as type minus 1
        let frequencyIndex = 4  // 44100 Hz
        let channelConfig = 2  // stereo
        return [
            0xFF,
            0xF1,  // sync continued, MPEG-4, layer 0, no CRC
            UInt8((profile << 6) | (frequencyIndex << 2) | (channelConfig >> 2)),
            UInt8(((channelConfig & 3) << 6) | (length >> 11)),
            UInt8((length >> 3) & 0xFF),
            UInt8(((length & 7) << 5) | 0x1F),  // buffer fullness 0x7FF (variable rate) starts here
            0xFC,  // rest of buffer fullness, one raw data block
        ]
    }
}
