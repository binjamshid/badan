import Foundation
import Compression

/// A deliberately minimal, dependency-free ZIP reader: enough to pull one named entry out of an
/// Apple Health `export.zip` and stream it to disk, and nothing more.
///
/// BADAN ships no third-party packages (see `apps/ios/project.yml`), and iOS exposes no public
/// unzip API, so this reads the ZIP central directory itself and inflates the one entry we need
/// with the system `Compression` framework. `COMPRESSION_ZLIB` in that framework is *raw* DEFLATE
/// (no zlib wrapper), which is exactly what a ZIP stores for method 8 — so no header stripping is
/// needed. Sizes and the local-header offset are read from the central directory (authoritative
/// even when a local header defers them to a data descriptor), and the inflate is streamed in
/// bounded chunks to a destination file so a multi-hundred-MB `export.xml` never has to sit in
/// memory whole — the property the whole importer is built around.
///
/// Scope is honest: STORED (method 0) and DEFLATE (method 8) only, and standard (non-ZIP64)
/// archives. Apple Health exports are ordinary DEFLATE zips well under the 4 GiB ZIP64 threshold;
/// a ZIP64 sentinel throws `.unsupportedZip64` rather than silently reading a wrong offset.
enum ZipArchiveReader {
    enum ReaderError: Error, Equatable {
        case notAZip
        case entryNotFound(String)
        case corruptCentralDirectory
        case unsupportedCompressionMethod(UInt16)
        case unsupportedZip64
        case inflateFailed
        case ioError
    }

    /// One central-directory entry we care about.
    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /// Find the entry whose path is exactly `name` or ends in `/name` (Apple nests `export.xml`
    /// under `apple_health_export/`), inflate it to `destination`, and return the number of bytes
    /// written. Throws rather than returning a partial file on any structural problem.
    @discardableResult
    static func extract(entryNamed name: String, from zipURL: URL, to destination: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        let fileSize = try Self.fileSize(handle)
        let eocd = try readEndOfCentralDirectory(handle, fileSize: fileSize)
        let entry = try findEntry(handle, named: name,
                                  centralDirOffset: eocd.centralDirOffset, entryCount: eocd.entryCount)
        let dataOffset = try localDataOffset(handle, entry: entry)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        switch entry.method {
        case 0:
            return try copyStored(handle, from: dataOffset, length: entry.compressedSize, to: out)
        case 8:
            return try inflate(handle, from: dataOffset, compressedLength: entry.compressedSize, to: out)
        default:
            throw ReaderError.unsupportedCompressionMethod(entry.method)
        }
    }

    // MARK: - Central directory

    private struct EOCD { let centralDirOffset: UInt64; let entryCount: Int }

    /// The End Of Central Directory record lives at the tail; scan the last 64 KiB (its max size
    /// with a comment) backwards for the `PK\u{05}\u{06}` signature.
    private static func readEndOfCentralDirectory(_ handle: FileHandle, fileSize: UInt64) throws -> EOCD {
        let tailLen = Int(min(fileSize, 65_557))
        guard tailLen >= 22 else { throw ReaderError.notAZip }
        try handle.seek(toOffset: fileSize - UInt64(tailLen))
        // Re-wrapped in a fresh `Data` so `startIndex` is 0: the backwards scan below indexes the
        // buffer absolutely, and a sliced `Data` (whose indices are inherited from its parent) would
        // read out of bounds rather than return a wrong answer.
        guard let read = try handle.read(upToCount: tailLen), read.count == tailLen else { throw ReaderError.ioError }
        let tail = Data(read)

        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var idx = tail.count - 22
        while idx >= 0 {
            if Array(tail[idx..<idx + 4]) == sig { break }
            idx -= 1
        }
        guard idx >= 0 else { throw ReaderError.notAZip }

        let entryCount = Int(u16(tail, idx + 10))
        let cdOffset = UInt64(u32(tail, idx + 16))
        if cdOffset == 0xFFFF_FFFF { throw ReaderError.unsupportedZip64 }
        return EOCD(centralDirOffset: cdOffset, entryCount: entryCount)
    }

    /// Walk the central directory entries in order, returning the first whose name matches.
    private static func findEntry(_ handle: FileHandle, named name: String,
                                  centralDirOffset: UInt64, entryCount: Int) throws -> Entry {
        try handle.seek(toOffset: centralDirOffset)
        for _ in 0..<max(entryCount, 0) {
            guard let fixed = try handle.read(upToCount: 46), fixed.count == 46 else {
                throw ReaderError.corruptCentralDirectory
            }
            guard Array(fixed[0..<4]) == [0x50, 0x4b, 0x01, 0x02] else {
                throw ReaderError.corruptCentralDirectory
            }
            let method = u16(fixed, 10)
            let compressedSize = UInt64(u32(fixed, 20))
            let uncompressedSize = UInt64(u32(fixed, 24))
            let nameLen = Int(u16(fixed, 28))
            let extraLen = Int(u16(fixed, 30))
            let commentLen = Int(u16(fixed, 32))
            let localOffset = UInt64(u32(fixed, 42))
            if localOffset == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF {
                throw ReaderError.unsupportedZip64
            }
            let nameData = (nameLen > 0) ? (try handle.read(upToCount: nameLen) ?? Data()) : Data()
            let entryName = String(decoding: nameData, as: UTF8.self)
            // Skip the extra field + file comment to reach the next entry.
            if extraLen + commentLen > 0 { _ = try handle.read(upToCount: extraLen + commentLen) }

            if entryName == name || entryName.hasSuffix("/" + name) {
                return Entry(name: entryName, method: method, compressedSize: compressedSize,
                             uncompressedSize: uncompressedSize, localHeaderOffset: localOffset)
            }
        }
        throw ReaderError.entryNotFound(name)
    }

    /// The local file header repeats the name/extra lengths (which can differ from the central
    /// directory's), so the entry's real data offset must be computed from the local header, not
    /// assumed.
    private static func localDataOffset(_ handle: FileHandle, entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              Array(header[0..<4]) == [0x50, 0x4b, 0x03, 0x04] else {
            throw ReaderError.corruptCentralDirectory
        }
        let nameLen = Int(u16(header, 26))
        let extraLen = Int(u16(header, 28))
        return entry.localHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)
    }

    // MARK: - Payload

    private static let ioChunk = 256 * 1024

    private static func copyStored(_ handle: FileHandle, from offset: UInt64, length: UInt64,
                                   to out: FileHandle) throws -> Int {
        try handle.seek(toOffset: offset)
        var remaining = Int(length)
        var total = 0
        while remaining > 0 {
            let want = min(ioChunk, remaining)
            // Same truncation rule as `inflate`: the entry is shorter than the central directory
            // said, so this is a damaged archive. Throwing keeps the type doc's "never a partial
            // file" promise true — silently returning a short `export.xml` would surface later as a
            // confusing "malformed XML" instead of the truth.
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { throw ReaderError.ioError }
            try out.write(contentsOf: chunk)
            remaining -= chunk.count
            total += chunk.count
        }
        return total
    }

    /// Streamed raw-DEFLATE inflate: pull `compressedLength` bytes from `handle` in chunks, push
    /// them through one `compression_stream`, and drain its output to `out` — bounded memory
    /// regardless of how large the inflated `export.xml` is.
    ///
    /// The source is read one `ioChunk` at a time into a stable buffer the stream points at until
    /// fully consumed; `COMPRESSION_STREAM_FINALIZE` is set once the last compressed byte is in
    /// hand. Output drains in an inner loop whenever the destination fills.
    private static func inflate(_ handle: FileHandle, from offset: UInt64, compressedLength: UInt64,
                                to out: FileHandle) throws -> Int {
        try handle.seek(toOffset: offset)

        let dstCapacity = ioChunk
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        // The struct needs non-null pointers to be constructed; `dst` is a harmless placeholder
        // until the loop sets the real src/dst before each `process` call.
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ReaderError.inflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        var remaining = Int(compressedLength)
        var totalOut = 0

        while true {
            let want = min(ioChunk, remaining)
            var input = (want > 0) ? (try handle.read(upToCount: want) ?? Data()) : Data()
            // A truncated archive: the central directory promised `compressedLength` bytes and the
            // file ended early. Without this the loop would spin forever — `remaining` never
            // reaches 0, so `isLastBlock` never becomes true, and the inflate is handed an empty
            // source that produces no output and reports OK. Fail instead of hanging the import.
            if want > 0 && input.isEmpty { throw ReaderError.ioError }
            remaining -= input.count
            let isLastBlock = remaining <= 0
            let flags = isLastBlock ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            let ended = try input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
                let srcBase = raw.bindMemory(to: UInt8.self).baseAddress
                stream.src_ptr = UnsafePointer(srcBase ?? dst)
                stream.src_size = raw.count
                while true {
                    stream.dst_ptr = dst
                    stream.dst_size = dstCapacity
                    let status = compression_stream_process(&stream, flags)
                    let produced = dstCapacity - stream.dst_size
                    if produced > 0 {
                        try out.write(contentsOf: Data(bytes: dst, count: produced))
                        totalOut += produced
                    }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        // This block is consumed once the destination stops filling.
                        if stream.dst_size != 0 { return false }
                    case COMPRESSION_STATUS_END:
                        return true
                    default:
                        throw ReaderError.inflateFailed
                    }
                }
            }
            if ended { return totalOut }
            if isLastBlock { return totalOut }   // finalized without an explicit END (defensive)
        }
    }

    // MARK: - Little-endian scalar reads

    private static func fileSize(_ handle: FileHandle) throws -> UInt64 {
        let end = try handle.seekToEnd()
        return end
    }

    private static func u16(_ d: Data, _ offset: Int) -> UInt16 {
        let base = d.startIndex + offset
        return UInt16(d[base]) | (UInt16(d[base + 1]) << 8)
    }

    private static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        let base = d.startIndex + offset
        return UInt32(d[base]) | (UInt32(d[base + 1]) << 8) | (UInt32(d[base + 2]) << 16) | (UInt32(d[base + 3]) << 24)
    }
}
