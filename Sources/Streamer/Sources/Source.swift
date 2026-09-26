import Foundation

/// Something that can be played: a Music playlist or a folder. Just a name and its tracks, in order.
protocol Source {
    var name: String { get }
    func trackURLs() throws -> [URL]
}
