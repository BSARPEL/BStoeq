import CoreGraphics
import Foundation
import Vision

/// Where converters put work that blocks.
public enum ConversionWork {
    private static let queue = DispatchQueue(label: "local.barlet.convert.work", qos: .userInitiated, attributes: .concurrent)

    /// Runs blocking work (ImageIO, PDFKit, text layout, Vision) on a private concurrent queue, off the
    /// Swift concurrency pool, and resumes when it returns or throws. Cancelling the awaiting task does not
    /// end it early: the work stops itself by calling `ConversionContext.checkCancelled()`.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// The same queue for work that cannot fail: the engine's own file work.
    static func detached<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// Reading text out of a picture, for the OCR tool and for scans without a text layer.
public enum TextRecognition {
    /// Vision stalls the Swift concurrency pool, and several recognitions at once only wait for one
    /// another inside it.
    private static let queue = DispatchQueue(label: "local.barlet.convert.vision", qos: .userInitiated)

    /// Vision, accurate level; languages: the user's preferred ones that Vision supports, then en-US;
    /// lines top to bottom, joined by line feeds. Empty when the image holds no text. Blocking: call it
    /// inside `ConversionWork.run`. Throws `CancellationError` once `isCancelled` answers true.
    public static func text(in image: CGImage, isCancelled: @escaping @Sendable () -> Bool) throws -> String {
        try queue.sync {
            if isCancelled() { throw CancellationError() }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages(supported: (try? request.supportedRecognitionLanguages()) ?? [])
            request.progressHandler = { request, _, _ in if isCancelled() { request.cancel() } }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch {
                if isCancelled() { throw CancellationError() }
                throw error
            }
            if isCancelled() { throw CancellationError() }
            return lines(request.results ?? []).joined(separator: "\n")
        }
    }

    /// The preferred languages Vision knows, in the user's order, by exact name or by language alone
    /// ("tr" finds "tr-TR"), with en-US last as the common fallback.
    static func languages(supported: [String], preferred: [String] = Locale.preferredLanguages) -> [String] {
        var chosen: [String] = []
        for identifier in preferred {
            let wanted = identifier.replacingOccurrences(of: "_", with: "-")
            let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
            guard let match = supported.first(where: { $0 == wanted })
                    ?? supported.first(where: { $0.split(separator: "-").first.map(String.init) == language }),
                  !chosen.contains(match) else { continue }
            chosen.append(match)
        }
        if !chosen.contains("en-US") { chosen.append("en-US") }
        return chosen
    }

    /// Vision's boxes have their origin at the bottom left. A box whose centre is level with the
    /// highest box of a row belongs to that row; a row is read left to right.
    private static func lines(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let highest = rows.last?.first, observation.boundingBox.midY > highest.boundingBox.minY {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.flatMap { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first?.string }
        }
    }
}

/// Text files do not say how they are encoded; this guesses the way a Turkish Mac user's files need.
public enum TextEncoding {
    /// BOM, strict UTF-8, UTF-16, then Windows-1254, then Windows-1252. A byte order mark is not part
    /// of the result. Nil for data that is no text in any of them (it holds NUL bytes, for one).
    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]), data.count % 4 == 0,
           let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) { return text }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]), data.count % 4 == 0,
           let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian) { return text }
        if bytes.starts(with: [0xFF, 0xFE]) { return utf16(data.dropFirst(2), bigEndian: false) }
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16(data.dropFirst(2), bigEndian: true) }
        // NUL is valid UTF-8, yet no text file holds one: with them the data is UTF-16 without a mark, or not text.
        guard data.contains(0) else {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1254)
                ?? String(data: data, encoding: .windowsCP1252)
        }
        // Some Windows tools pad a file with NULs at its end: valid UTF-8 before them is that text, not UTF-16.
        if let end = data.lastIndex(where: { $0 != 0 }), !data[..<end].contains(0),
           let text = String(data: data[...end], encoding: .utf8) { return text }
        guard data.count % 2 == 0 else { return nil }
        // Mostly Latin text has its zero bytes on one side of the pairs: that side tells the byte order.
        var even = 0, odd = 0
        for (offset, byte) in data.enumerated() where byte == 0 { if offset % 2 == 0 { even += 1 } else { odd += 1 } }
        let text = String(data: data, encoding: odd >= even ? .utf16LittleEndian : .utf16BigEndian)
        return text?.unicodeScalars.contains("\0") == false ? text : nil
    }

    /// Unpaired surrogates are replaced rather than failing a file that announced itself as UTF-16.
    private static func utf16(_ data: Data, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var high: UInt8?
        for byte in data {
            guard let first = high else { high = byte; continue }
            units.append(bigEndian ? UInt16(first) << 8 | UInt16(byte) : UInt16(byte) << 8 | UInt16(first))
            high = nil
        }
        return String(decoding: units, as: UTF16.self)
    }
}
