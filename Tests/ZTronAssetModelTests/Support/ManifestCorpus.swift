import Foundation
import ZTronAssetModel

/// Seeded manifest generators and mutators for the R-MAN-3 fuzz corpus and the R-MAN-4 property tests.
///
/// Every value is a pure function of its seed (SplitMix64), so a failing case is reproduced from the seed its
/// expectation prints.
enum ManifestCorpus {
    /// The payload limit every 32 MiB case targets (`ManifestLimits().maxPayloadBytes`, R-MAN-2).
    static let payloadLimit = Int(ManifestLimits().maxPayloadBytes)

    // MARK: - Realistic manifests

    /// The JSON text of one realistic entry (about 350 bytes, like a production catalog entry): a dotted
    /// identifier, an AWS-tier remote path, three directory components, a file name, a size and a checksum.
    static func entryJSON(_ index: Int, random: inout SplitMix64) -> String {
        let extensions = ["heic", "png", "jpg", "svg", "mp4", "mp3", "wav"]
        let areas = ["Vehytherion Temple", "Control Room", "Nacht der Untoten", "Crypt", "Cinematics", "Audio"]
        let words = random.next()
        let ext = extensions[Int(words % UInt64(extensions.count))]
        let area = areas[Int((words >> 8) % UInt64(areas.count))]
        let checksum = (0..<4).map { _ in ManifestCorpus.hex16(random.next()) }.joined()
        let identifier = "bo7.ri.easter.egg.asset.\(index).variant\(words >> 40)"
        return "{\"identifier\":\"\(identifier)\",\"fileExtension\":\"\(ext)\","
            + "\"remotePath\":\"media/\(checksum.prefix(16))/\(identifier).\(ext)\","
            + "\"localPathComponents\":[\"Black Ops 7\",\"Rex Infernus\",\"\(area)\"],"
            + "\"localFileName\":\"Asset \(index)\",\"byteSize\":\(words % 50_000_000),\"checksum\":\"\(checksum)\"}"
    }

    /// A bare-array manifest of realistic entries whose size stays at most `maxBytes`, and its entry count.
    /// Identifiers are unique, so it decodes under the default options while it holds at most 100,000 entries.
    static func manifest(maxBytes: Int, seed: UInt64) -> (data: Data, entryCount: Int) {
        var random = SplitMix64(seed: seed)
        var text = "["
        text.reserveCapacity(maxBytes)
        var index = 0
        while true {
            let entry = ManifestCorpus.entryJSON(index, random: &random)
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            if index > 0 {
                text += ","
            }
            text += entry
            index += 1
        }
        text += "]"
        return (Data(text.utf8), index)
    }

    /// A manifest of exactly `count` realistic entries.
    static func manifest(entryCount count: Int, seed: UInt64) -> Data {
        var random = SplitMix64(seed: seed)
        let entries = (0..<count).map { ManifestCorpus.entryJSON($0, random: &random) }
        return Data(("[" + entries.joined(separator: ",") + "]").utf8)
    }

    // MARK: - Allocation worst cases

    /// `count` minimal entries whose identifier, remote path and file name are each `length` bytes: just past the
    /// 15-byte inline limit, every one is a heap string, the densest heap per payload byte a valid entry allows.
    static func shortStringEntries(length: Int, count: Int) -> Data {
        var text = "["
        let filler = String(repeating: "f", count: length)
        for index in 0..<count {
            let prefix = "\(index)-"
            let identifier = prefix + String(repeating: "i", count: max(0, length - prefix.utf8.count))
            text += (index == 0 ? "" : ",")
                + "{\"identifier\":\"\(identifier)\",\"fileExtension\":\"p\",\"remotePath\":\"\(filler)\","
                + "\"localPathComponents\":[],\"localFileName\":\"\(filler)\"}"
        }
        return Data((text + "]").utf8)
    }

    /// Entries with 32 path components of `length` bytes each, up to `maxBytes`: array elements cost three JSON
    /// bytes of punctuation but a 16-byte slot plus a heap string each.
    static func shortComponentEntries(length: Int, maxBytes: Int) -> Data {
        var text = "["
        var index = 0
        while index < 100_000 {
            let components = (0..<32).map { component -> String in
                let prefix = "\(index)-\(component)-"
                return "\"" + prefix + String(repeating: "x", count: max(0, length - prefix.utf8.count)) + "\""
            }
            let entry = "{\"identifier\":\"i\(index)\",\"fileExtension\":\"p\",\"remotePath\":\"r\",\"localPathComponents\":["
                + components.joined(separator: ",") + "]}"
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            text += (index == 0 ? "" : ",") + entry
            index += 1
        }
        return Data((text + "]").utf8)
    }

    /// Minimal entries carrying `tagCount` one-byte tags and an unknown member of `padding` bytes, up to
    /// `maxBytes`: a tag array is a heap allocation of 32 + 16 × `tagCount` bytes for four payload bytes per tag.
    static func taggedEntries(tagCount: Int, padding: Int, maxBytes: Int) -> Data {
        var text = "["
        let tags = Array(repeating: "\"t\"", count: tagCount).joined(separator: ",")
        let pad = String(repeating: "p", count: padding)
        var index = 0
        while index < 100_000 {
            let entry = "{\"identifier\":\"i\(index)\",\"fileExtension\":\"p\",\"remotePath\":\"r\",\"localPathComponents\":[],"
                + "\"tags\":[\(tags)],\"x\":\"\(pad)\"}"
            guard text.utf8.count + entry.utf8.count + 2 <= maxBytes else {
                break
            }
            text += (index == 0 ? "" : ",") + entry
            index += 1
        }
        return Data((text + "]").utf8)
    }

    /// `count` minimal entries, each with `components` empty path components and `tags` one-byte tags: string
    /// arrays of 32 + 16 × n bytes, which for 31 and 32 elements (528 and 544 bytes) lie just past a size class of
    /// the segregated allocator and are served from 640-byte blocks (fix round 2).
    static func sizeClassEntries(components: Int, tags: Int, count: Int) -> Data {
        let componentList = Array(repeating: "\"\"", count: components).joined(separator: ",")
        let tagList = Array(repeating: "\"t\"", count: tags).joined(separator: ",")
        var text = "["
        for index in 0..<count {
            text += (index == 0 ? "" : ",") + "{\"identifier\":\"\(String(index, radix: 36))\",\"fileExtension\":\"p\",\"remotePath\":\"r\","
                + "\"localPathComponents\":[\(componentList)],\"tags\":[\(tagList)]}"
        }
        return Data((text + "]").utf8)
    }

    /// `payload` followed by just enough whitespace for the decoder's allocation estimate to reach its limit (three
    /// times the payload): as much decoded heap per payload byte as the decoder accepts. Whitespace changes no
    /// estimate and a rejection reports the estimate (`payloadTooLarge(bytes:limit:)`), so one decode finds the
    /// padding; a payload the decoder already accepts is returned as it is.
    static func paddedToEstimateLimit(_ payload: Data) -> Data {
        do throws(ManifestError) {
            _ = try ManifestDecoder.decode(payload)
            return payload
        } catch {
            guard case .payloadTooLarge(let estimated, _) = error else {
                return payload
            }
            let target = Int((estimated + 2) / 3)
            return payload + Data(repeating: UInt8(ascii: " "), count: max(0, target - payload.count))
        }
    }

    /// A bare array of `count` copies of the JSON value `element` (`1`, `null`, `{}`…).
    static func repeatedElements(_ element: String, count: Int) -> Data {
        var data = Data(capacity: count * (element.utf8.count + 1) + 2)
        data.append(UInt8(ascii: "["))
        let bytes = Data(element.utf8)
        for index in 0..<count {
            if index > 0 {
                data.append(UInt8(ascii: ","))
            }
            data.append(bytes)
        }
        data.append(UInt8(ascii: "]"))
        return data
    }

    /// `count` minimal valid entries that all share the identifier `a` (about 81 bytes each).
    static func duplicateEntries(count: Int) -> Data {
        let entry = Data(#"{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":[]}"#.utf8)
        var data = Data(capacity: count * (entry.count + 1) + 2)
        data.append(UInt8(ascii: "["))
        for index in 0..<count {
            if index > 0 {
                data.append(UInt8(ascii: ","))
            }
            data.append(entry)
        }
        data.append(UInt8(ascii: "]"))
        return data
    }

    /// Sixteen lowercase hex digits.
    static func hex16(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    // MARK: - Fuzz inputs

    /// `count` seeded random bytes. Large payloads repeat a 64 KiB random block, which keeps generation cheap and
    /// changes nothing for a decoder that rejects within the first bytes.
    static func randomBytes(count: Int, seed: UInt64, firstByte: UInt8? = nil) -> Data {
        var random = SplitMix64(seed: seed)
        let blockSize = min(count, 64 * 1_024)
        var block = [UInt8]()
        block.reserveCapacity(blockSize)
        while block.count < blockSize {
            block.append(UInt8(truncatingIfNeeded: random.next()))
        }
        if let firstByte, !block.isEmpty {
            block[0] = firstByte
        }
        var data = Data(capacity: count)
        while !block.isEmpty, data.count + block.count <= count {
            data.append(contentsOf: block)
        }
        data.append(contentsOf: block.prefix(count - data.count))
        return data
    }

    /// `payload` with `count` seeded edits: a byte replaced by a random or a JSON-structural byte, inserted,
    /// deleted, or a short slice duplicated.
    static func mutated(_ payload: Data, count: Int, seed: UInt64) -> Data {
        var random = SplitMix64(seed: seed)
        var bytes = [UInt8](payload)
        let structural = Array("[]{}\",:\\0123456789-.eEtfn u".utf8)
        for _ in 0..<count {
            guard !bytes.isEmpty else {
                bytes.append(UInt8(truncatingIfNeeded: random.next()))
                continue
            }
            let position = Int(random.next() % UInt64(bytes.count))
            switch random.next() % 5 {
            case 0:
                bytes[position] = UInt8(truncatingIfNeeded: random.next())
            case 1:
                bytes[position] = structural[Int(random.next() % UInt64(structural.count))]
            case 2:
                bytes.insert(structural[Int(random.next() % UInt64(structural.count))], at: position)
            case 3:
                bytes.remove(at: position)
            default:
                let end = min(bytes.count, position + 1 + Int(random.next() % 16))
                bytes.insert(contentsOf: bytes[position..<end], at: position)
            }
        }
        return Data(bytes)
    }

    /// `depth` nested arrays (`[[[...]]]`), closed or left open.
    static func nestedArrays(depth: Int, closed: Bool) -> Data {
        var data = Data(repeating: UInt8(ascii: "["), count: depth)
        if closed {
            data.append(Data(repeating: UInt8(ascii: "]"), count: depth))
        }
        return data
    }

    /// A one-entry manifest whose member `field` holds a string of `count` copies of `unit` (inside a one-element
    /// array when `inArray`); `field` may be a known member (replacing its normal value) or an unknown one.
    static func hugeString(in field: String, unit: String, count: Int, inArray: Bool = false, terminated: Bool = true) -> Data {
        var members: [(String, String)] = [
            ("identifier", "\"a.b\""), ("fileExtension", "\"png\""), ("remotePath", "\"m/a.png\""),
            ("localPathComponents", "[\"A\"]"),
        ]
        let prefix = "\"\(field)\":"
        var data = Data("[{".utf8)
        members.removeAll { $0.0 == field }
        for (name, value) in members {
            data.append(Data("\"\(name)\":\(value),".utf8))
        }
        data.append(Data(prefix.utf8))
        if inArray {
            data.append(UInt8(ascii: "["))
        }
        data.append(UInt8(ascii: "\""))
        let unitBytes = Data(unit.utf8)
        var body = Data(capacity: unitBytes.count * count)
        var remaining = count
        var chunk = unitBytes
        // Doubling keeps building a 32 MiB string to a few dozen appends.
        while remaining > 0 {
            let copies = chunk.count / unitBytes.count
            if copies <= remaining {
                body.append(chunk)
                remaining -= copies
                chunk.append(chunk)
            } else {
                chunk = unitBytes
            }
        }
        data.append(body)
        if terminated {
            data.append(Data((inArray ? "\"]}]" : "\"}]").utf8))
        }
        return data
    }
}
