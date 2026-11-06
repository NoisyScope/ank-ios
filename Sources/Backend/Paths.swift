import Foundation

enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let root = documents.appendingPathComponent("anki")
    static let collection = root.appendingPathComponent("collection.anki2")
    static let media = root.appendingPathComponent("media")
    static let mediaDB = root.appendingPathComponent("media.db")
    static let backups = root.appendingPathComponent("backups")
    static let imports = FileManager.default.temporaryDirectory.appendingPathComponent("imports")

    static func prepare() {
        for d in [media, backups, imports] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

private let logLock = NSLock()
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    print(s)
    #if SELFTEST
    let u = Paths.documents.appendingPathComponent("app.log"), d = Data((s + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: u) }
    #endif
}
