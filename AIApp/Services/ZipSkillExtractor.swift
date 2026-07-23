import Foundation
import Compression

/// Minimal ZIP reader to pull `SKILL.md` (or first `*.md`) out of a skill pack.
/// Reads the central directory (robust to data descriptors / streamed zips) and
/// inflates DEFLATE entries via libcompression, so real GitHub/Anthropic skill
/// zips work — not just uncompressed ones.
enum ZipSkillExtractor {
    enum ExtractError: LocalizedError {
        case notAZip
        case noSkillMarkdown

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Datei ist kein gültiges ZIP."
            case .noSkillMarkdown: return "Im ZIP wurde keine SKILL.md gefunden."
            }
        }
    }

    static func skillMarkdown(from data: Data) throws -> String {
        guard data.count > 30, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4b else {
            throw ExtractError.notAZip
        }
        var entries = centralDirectoryEntries(data)
        if entries.isEmpty {
            // Minimal / streamed zips without a central directory: walk local headers.
            entries = localHeaderEntries(data)
        }
        // Prefer SKILL.md, else the shortest-path .md file.
        let mdEntries = entries.filter { $0.name.lowercased().hasSuffix(".md") && !$0.name.hasSuffix("/") }
        guard !mdEntries.isEmpty else { throw ExtractError.noSkillMarkdown }
        let preferred = mdEntries.first { $0.name.lowercased().hasSuffix("skill.md") }
            ?? mdEntries.sorted { $0.name.count < $1.name.count }.first!

        guard let body = readEntry(preferred, from: data) else {
            throw ExtractError.noSkillMarkdown
        }
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - Central directory

    private struct CDEntry {
        var name: String
        var method: Int
        var compSize: Int
        var uncompSize: Int
        var localHeaderOffset: Int
    }

    private static func centralDirectoryEntries(_ data: Data) -> [CDEntry] {
        // Find End Of Central Directory record (0x06054b50), scanning from the end.
        let base = data.startIndex
        let count = data.count
        var eocd = -1
        var i = count - 22
        let minI = max(0, count - 22 - 65_536)  // EOCD may have up to 64KB comment
        while i >= minI {
            if readUInt32(data, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }
        let cdCount = Int(readUInt16(data, eocd + 10))
        var offset = Int(readUInt32(data, eocd + 16))  // start of central directory
        var entries: [CDEntry] = []
        for _ in 0..<cdCount {
            guard offset + 46 <= count, readUInt32(data, offset) == 0x02014b50 else { break }
            let method = Int(readUInt16(data, offset + 10))
            let compSize = Int(readUInt32(data, offset + 20))
            let uncompSize = Int(readUInt32(data, offset + 24))
            let nameLen = Int(readUInt16(data, offset + 28))
            let extraLen = Int(readUInt16(data, offset + 30))
            let commentLen = Int(readUInt16(data, offset + 32))
            let localOffset = Int(readUInt32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= count else { break }
            let name = String(decoding: data.subdata(in: (base + nameStart)..<(base + nameStart + nameLen)), as: UTF8.self)
            entries.append(CDEntry(name: name, method: method, compSize: compSize,
                                   uncompSize: uncompSize, localHeaderOffset: localOffset))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Fallback for zips with no central directory: walk local file headers.
    /// Sizes must be in the local header (no data descriptor) to bound the payload.
    private static func localHeaderEntries(_ data: Data) -> [CDEntry] {
        var entries: [CDEntry] = []
        var offset = 0
        let count = data.count
        while offset + 30 <= count, readUInt32(data, offset) == 0x04034b50 {
            let method = Int(readUInt16(data, offset + 8))
            let compSize = Int(readUInt32(data, offset + 18))
            let uncompSize = Int(readUInt32(data, offset + 22))
            let nameLen = Int(readUInt16(data, offset + 26))
            let extraLen = Int(readUInt16(data, offset + 28))
            let nameStart = offset + 30
            guard nameStart + nameLen + extraLen + compSize <= count else { break }
            let name = String(decoding: data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLen)), as: UTF8.self)
            entries.append(CDEntry(name: name, method: method, compSize: compSize,
                                   uncompSize: uncompSize, localHeaderOffset: offset))
            offset = nameStart + nameLen + extraLen + compSize
            if compSize == 0 { break }  // data descriptor — boundary unknown
        }
        return entries
    }

    private static func readEntry(_ entry: CDEntry, from data: Data) -> Data? {
        let base = data.startIndex
        let o = entry.localHeaderOffset
        guard o + 30 <= data.count, readUInt32(data, o) == 0x04034b50 else { return nil }
        let nameLen = Int(readUInt16(data, o + 26))
        let extraLen = Int(readUInt16(data, o + 28))
        let dataStart = o + 30 + nameLen + extraLen
        guard dataStart + entry.compSize <= data.count else { return nil }
        let payload = data.subdata(in: (base + dataStart)..<(base + dataStart + entry.compSize))
        switch entry.method {
        case 0:  // stored
            return payload
        case 8:  // deflate
            return inflateRawDeflate(payload, expectedSize: entry.uncompSize)
        default:
            return nil
        }
    }

    /// Apple's COMPRESSION_ZLIB decodes the *raw* DEFLATE stream that ZIP stores
    /// (no zlib header), despite the name.
    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = min(max(expectedSize, 4_096), 8 * 1024 * 1024)  // guard against zip bombs
        var dst = Data(count: cap)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, cap, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    // MARK: - Little-endian readers

    private static func readUInt16(_ data: Data, _ o: Int) -> UInt16 {
        let b = data.startIndex + o
        return UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ o: Int) -> UInt32 {
        let b = data.startIndex + o
        return UInt32(data[b])
            | (UInt32(data[b + 1]) << 8)
            | (UInt32(data[b + 2]) << 16)
            | (UInt32(data[b + 3]) << 24)
    }
}
