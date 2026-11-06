import Foundation
import SwiftProtobuf

@_silgen_name("ak_start") private func ak_start(_ lang: UnsafePointer<CChar>) -> Bool
@_silgen_name("ak_run") private func ak_run(_ n: UnsafePointer<CChar>, _ i: UnsafePointer<UInt8>?, _ l: Int,
    _ o: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ ol: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("ak_db") private func ak_db(_ i: UnsafePointer<UInt8>?, _ l: Int,
    _ o: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ ol: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("ak_post") private func ak_post(_ n: UnsafePointer<CChar>, _ restricted: Bool, _ i: UnsafePointer<UInt8>?, _ l: Int,
    _ o: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ ol: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("ak_free_buf") private func ak_free_buf(_ p: UnsafeMutablePointer<UInt8>?, _ l: Int)

struct BackendError: LocalizedError {
    var kind: Anki_Backend_BackendError.Kind?
    var message: String
    var errorDescription: String? { message }
    var isInterrupted: Bool { kind == .interrupted }
    var isAuth: Bool { kind == .syncAuthError }
}

/// Thin typed wrapper over the Rust backend. Every call blocks, so call it off the main actor.
enum Backend {
    static func start() { _ = ak_start("en") }

    private static func withBuffer(_ f: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32) -> (Int32, Data) {
        var out: UnsafeMutablePointer<UInt8>? = nil, n = 0
        let code = f(&out, &n)
        defer { ak_free_buf(out, n) }
        return (code, out.map { Data(bytes: $0, count: n) } ?? Data())
    }

    static func raw(_ name: String, _ input: Data) throws -> Data {
        let (code, data) = input.withUnsafeBytes { b in
            withBuffer { o, l in
                name.withCString { ak_run($0, b.bindMemory(to: UInt8.self).baseAddress, b.count, o, l) }
            }
        }
        switch code {
        case 0: return data
        case 1:
            let e = try Anki_Backend_BackendError(serializedBytes: data)
            throw BackendError(kind: e.kind, message: e.message)
        default: throw BackendError(message: String(decoding: data, as: UTF8.self))
        }
    }

    static func call<O: SwiftProtobuf.Message>(_ name: String, _ input: some SwiftProtobuf.Message = Anki_Generic_Empty()) throws -> O {
        try O(serializedBytes: try raw(name, input.serializedData()))
    }

    static func run(_ name: String, _ input: some SwiftProtobuf.Message = Anki_Generic_Empty()) throws {
        _ = try raw(name, input.serializedData())
    }

    /// Runs a read-only SQL query and returns its rows.
    static func query(_ sql: String) throws -> [[Any]] {
        let req: [String: Any] = ["kind": "query", "sql": sql, "args": [], "first_row_only": false]
        let body = try JSONSerialization.data(withJSONObject: req)
        let (code, data) = body.withUnsafeBytes { b in
            withBuffer { o, l in ak_db(b.bindMemory(to: UInt8.self).baseAddress, b.count, o, l) }
        }
        guard code == 0 else { throw BackendError(message: "query failed: \(String(decoding: data, as: UTF8.self))") }
        return try JSONSerialization.jsonObject(with: data) as? [[Any]] ?? []
    }

    static func count(_ sql: String) throws -> Int { (try query(sql).first?.first as? Int) ?? 0 }

    static func post(_ name: String, restricted: Bool, _ body: Data) -> (Int, Data) {
        let (code, data) = body.withUnsafeBytes { b in
            withBuffer { o, l in
                name.withCString { ak_post($0, restricted, b.bindMemory(to: UInt8.self).baseAddress, b.count, o, l) }
            }
        }
        return (Int(code), data)
    }
}

/// Runs blocking backend work off the main actor.
func background<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: f).value
}
