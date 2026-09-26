import Foundation

/// Every audio file under a folder, however deep, sorted by path so track numbers in file names give
/// album order. ALAC has no extension of its own: it lives in `.m4a`.
struct FolderSource: Source {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "aiff", "aif", "wav", "flac"]

    let url: URL

    var name: String { url.lastPathComponent }

    /// Throws if the folder is missing.
    func trackURLs() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url])
        }
        return walker.compactMap { $0 as? URL }
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
