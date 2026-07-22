import Foundation

/// Minimal ZIP reader to pull `SKILL.md` (or first `*.md`) out of a skill pack zip.
/// Supports **stored** entries (compression method 0). Deflated zips: unzip once
/// and import the markdown file instead.
enum ZipSkillExtractor {
    enum ExtractError: LocalizedError {
        case notAZip
        case noSkillMarkdown
        case deflatedUnsupported

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Datei ist kein gültiges ZIP."
            case .noSkillMarkdown: return "Im ZIP wurde keine SKILL.md gefunden."
            case .deflatedUnsupported:
                return "Dieses ZIP ist komprimiert. Bitte SKILL.md entpacken und als .md importieren."
            }
        }
    }

    static func skillMarkdown(from data: Data) throws -> String {
        guard data.count > 30, data[0] == 0x50, data[1] == 0x4b else {
            throw ExtractError.notAZip
        }
        var offset = 0
        var candidates: [(path: String, body: Data)] = []
        var sawDeflated = false

        while offset + 30 <= data.count {
            let sig = readUInt32(data, offset)
            if sig != 0x04034b50 { break }
            let method = Int(readUInt16(data, offset + 8))
            let compSize = Int(readUInt32(data, offset + 18))
            let nameLen = Int(readUInt16(data, offset + 26))
            let extraLen = Int(readUInt16(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen + compSize <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            let path = String(decoding: nameData, as: UTF8.self)
            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + compSize
            let payload = data.subdata(in: dataStart..<dataEnd)
            offset = dataEnd

            if path.hasSuffix("/") { continue }
            let lower = path.lowercased()
            guard lower.hasSuffix(".md") else { continue }

            if method == 8 {
                sawDeflated = true
                continue
            }
            guard method == 0 else { continue }
            candidates.append((path, payload))
        }

        if candidates.isEmpty {
            throw sawDeflated ? ExtractError.deflatedUnsupported : ExtractError.noSkillMarkdown
        }
        let preferred = candidates.first { $0.path.lowercased().hasSuffix("skill.md") }
            ?? candidates.sorted { $0.path.count < $1.path.count }.first!
        return String(decoding: preferred.body, as: UTF8.self)
    }

    private static func readUInt16(_ data: Data, _ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ o: Int) -> UInt32 {
        UInt32(data[o])
            | (UInt32(data[o + 1]) << 8)
            | (UInt32(data[o + 2]) << 16)
            | (UInt32(data[o + 3]) << 24)
    }
}
