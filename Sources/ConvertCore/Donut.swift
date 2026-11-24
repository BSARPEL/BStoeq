import CoreGraphics
import Foundation

/// What the ring offers besides conversions. Done by the app, not by a converter.
public enum DonutAction: String, CaseIterable, Sendable {
    case zip, sevenZip, extract, openArchive, copyPath, airDrop, openConverter

    public var title: String {
        switch self {
        case .zip: "Tek ZIP’te topla"
        case .sevenZip: "Tek 7Z’de topla"
        case .extract: "Arşivi çıkart"
        case .openArchive: "Arşiv yöneticisinde aç"
        case .copyPath: "Yolu kopyala"
        case .airDrop: "AirDrop ile gönder"
        case .openConverter: "Dönüştürücüde aç"
        }
    }
    public var shortTitle: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7Z"
        case .extract: "Çıkart"
        case .openArchive: "Arşivi aç"
        case .copyPath: "Dosya yolu"
        case .airDrop: "AirDrop"
        case .openConverter: "Tümü"
        }
    }
    /// Every title is a localization key, also the ones that read the same in all languages.
    public var titleIsKey: Bool { true }
    public var symbol: String {
        switch self {
        case .zip, .sevenZip: "doc.zipper"
        case .extract: "arrow.up.bin"
        case .openArchive: "archivebox"
        case .copyPath: "doc.on.clipboard"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .openConverter: "slider.horizontal.3"
        }
    }
}

/// One wedge of the ring, with everything the view needs to draw it and the panel to answer a drop on it.
public struct DonutSlice: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable { case target(ConversionTarget), action(DonutAction), flip }
    /// The target's id, "action." and the action's name, or "flip".
    public let id: String
    public let content: Content
    public let title: String
    public let shortTitle: String
    public let titleIsKey: Bool
    public let symbol: String
    public let enabled: Bool
    /// Files this slice would act on.
    public let fitting: Int
    /// Why it is greyed.
    public let reasonKey: String?
    /// The tool name for "needs".
    public let reasonDetail: String?
    /// A caveat for an enabled slice.
    public let noteKey: String?

    public init(id: String, content: Content, title: String, shortTitle: String, titleIsKey: Bool, symbol: String,
                enabled: Bool = true, fitting: Int = 0, reasonKey: String? = nil, reasonDetail: String? = nil,
                noteKey: String? = nil) {
        self.id = id; self.content = content; self.title = title; self.shortTitle = shortTitle
        self.titleIsKey = titleIsKey; self.symbol = symbol; self.enabled = enabled; self.fitting = fitting
        self.reasonKey = reasonKey; self.reasonDetail = reasonDetail; self.noteKey = noteKey
    }

    /// The slice that turns the ring over.
    public static let flip = DonutSlice(id: "flip", content: .flip, title: "Diğerleri", shortTitle: "Diğerleri",
                                        titleIsKey: true, symbol: "ellipsis")
}

/// The ring has two sides: the usual targets in front, tools and rarer ones behind.
public struct DonutFaces: Equatable, Sendable {
    public let front: [DonutSlice]
    public let back: [DonutSlice]
    public init(front: [DonutSlice], back: [DonutSlice]) { self.front = front; self.back = back }
}

/// Which slices a set of files gets. The layouts are fixed per family, so a direction means a command.
public enum DonutToolbar {
    /// Slices on a face before the one that turns the ring over.
    public static let faceLimit = 7

    private enum Item {
        case target(String)
        case action(DonutAction)
    }

    private static func targets(_ ids: String...) -> [Item] { ids.map { .target($0) } }
    private static func actions(_ actions: DonutAction...) -> [Item] { actions.map { .action($0) } }

    /// Front and back for a family; nil is the mixed toolbar.
    private static func layout(_ family: FileFamily?) -> (front: [Item], back: [Item]) {
        switch family {
        case .image:
            (targets("jpg", "png", "pdf", "pdf.merge", "half", "compress", "heic"),
             targets("nobg", "ocr", "webp", "avif", "tiff") + actions(.zip))
        case .pdf:
            (targets("jpg", "png", "txt", "pdf.split", "pdf.merge", "compress"),
             targets("ocr", "docx", "tiff") + actions(.zip, .copyPath, .airDrop, .openConverter))
        case .document:
            (targets("pdf", "docx", "rtf", "txt", "html", "odt"), actions(.zip, .copyPath, .airDrop, .openConverter))
        case .data:
            (targets("csv", "xlsx", "json", "tsv", "plist"), actions(.zip, .copyPath, .openConverter))
        case .video:
            (targets("mp4", "mp4.720p", "mov", "gif", "m4a", "mp3"),
             targets("mp4.hevc", "mute", "compress", "webm", "mkv", "wav") + actions(.zip))
        case .audio:
            (targets("mp3", "m4a", "wav", "flac", "aiff"), targets("mp3.128k", "alac", "opus", "m4r") + actions(.zip))
        case .subtitle:
            (targets("srt", "vtt"), actions(.zip, .copyPath))
        case .archive:
            (actions(.extract, .openArchive, .copyPath, .airDrop), [])
        case .folder:
            (actions(.zip, .sevenZip, .copyPath), [])
        case .other:
            (actions(.zip, .copyPath, .airDrop), [])
        case nil:
            (targets("pdf", "pdf.merge", "png", "jpg", "txt") + actions(.zip), actions(.copyPath, .airDrop, .openConverter))
        }
    }

    /// The family all the files share, `other` when none is recognised (or there are no files), nil when they are mixed.
    /// Reads each file's directory flag.
    public static func family(of urls: [URL]) -> FileFamily? {
        let families = Set(urls.map { FormatRegistry.format(of: $0)?.family ?? .other })
        return families.count > 1 ? nil : families.first ?? .other
    }

    /// The slices for these files: the toolbar of their common family, or the mixed one.
    /// `claimed` says whether any converter turns any format of a family into a target on this Mac.
    /// A slice keeps its slot: only an unclaimed target is left out; what does not apply is greyed with a reason.
    public static func faces(for urls: [URL], offers: [TargetOffer], claimed: (ConversionTarget) -> Bool) -> DonutFaces {
        guard !urls.isEmpty else { return DonutFaces(front: [], back: []) }
        let formats = urls.map { FormatRegistry.format(of: $0) }
        let families = Set(formats.map { $0?.family ?? .other })
        let toolbar = layout(families.count > 1 ? nil : families.first)
        let offered = Dictionary(offers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let archives = formats.filter { $0?.family == .archive }.count
        let together = Set(urls.map { $0.deletingLastPathComponent().path }).count == 1

        func slice(_ item: Item) -> DonutSlice? {
            switch item {
            case .target(let id):
                guard let target = TargetCatalog.target(id: id), claimed(target) else { return nil }
                let offer = offered[id]
                var reason: String?, detail: String?
                if let offer, offer.fitting >= max(1, target.minimumInputs) {
                    reason = nil
                } else if let offer, offer.fitting > 0 {
                    reason = "Birleştirmek için en az iki dosya gerekir."
                } else if case .needs(let tool)? = offer?.availability {
                    reason = "Bu dönüştürme için %@ gerekli. Kurulum adımı Ayarlar → Dönüştürücü’de."
                    detail = tool
                } else if target.kind == .convert, formats.allSatisfy({ $0?.id == target.id }) {
                    reason = "Dosya zaten bu biçimde."
                } else {
                    reason = "Bu dosya bu biçime dönüştürülemiyor."
                }
                return DonutSlice(id: target.id, content: .target(target), title: target.title, shortTitle: target.shortTitle,
                                  titleIsKey: target.titleIsKey, symbol: target.symbol, enabled: reason == nil,
                                  fitting: offer?.fitting ?? 0, reasonKey: reason, reasonDetail: detail,
                                  noteKey: reason == nil ? offer?.noteKey : nil)
            case .action(let action):
                let fitting: Int, reason: String?
                switch action {
                case .extract, .openArchive:
                    fitting = archives
                    reason = archives > 0 ? nil : "Bu dosya bu biçime dönüştürülemiyor."
                case .zip, .sevenZip:
                    fitting = together ? urls.count : 0
                    reason = together ? nil : "Dosyalar aynı klasörde olmalı."
                case .copyPath, .airDrop, .openConverter:
                    fitting = urls.count
                    reason = nil
                }
                return DonutSlice(id: "action.\(action.rawValue)", content: .action(action), title: action.title,
                                  shortTitle: action.shortTitle, titleIsKey: action.titleIsKey, symbol: action.symbol,
                                  enabled: reason == nil, fitting: fitting, reasonKey: reason)
            }
        }

        var front = Array(toolbar.front.compactMap(slice).prefix(faceLimit))
        var back = Array(toolbar.back.compactMap(slice).prefix(faceLimit))
        // A face with nothing on it is not worth turning to: what is left is the front.
        if front.isEmpty { swap(&front, &back) }
        guard !back.isEmpty else { return DonutFaces(front: front, back: []) }
        return DonutFaces(front: front + [.flip], back: back + [.flip])
    }
}

/// Where the ring's slices are. Pure numbers, so the panel, the drawing and the tests agree.
public struct DonutGeometry: Equatable, Sendable {
    public var count: Int
    public var outerRadius: CGFloat
    public var innerRadius: CGFloat
    /// A band beyond the ring that still belongs to the panel and refuses drops, so a near miss does nothing.
    public var margin: CGFloat

    public init(count: Int, outerRadius: CGFloat = 140, innerRadius: CGFloat = 58, margin: CGFloat = 28) {
        self.count = count; self.outerRadius = outerRadius; self.innerRadius = innerRadius; self.margin = margin
    }

    public enum Hit: Equatable, Sendable { case slice(Int), hub, rim, outside }

    /// The angle one slice covers, in radians.
    public var sweep: CGFloat { count > 0 ? 2 * .pi / CGFloat(count) : 2 * .pi }

    /// `point` relative to the centre, y up. Slice 0 is centred at 12 o'clock; slices run clockwise.
    public func hit(_ point: CGPoint) -> Hit {
        let distance = hypot(point.x, point.y)
        guard distance.isFinite, distance <= outerRadius + margin else { return .outside }
        if distance < innerRadius { return .hub }
        guard distance <= outerRadius, count > 0 else { return .rim }
        // Measured from straight up, growing clockwise.
        var angle = atan2(point.x, point.y)
        if angle < 0 { angle += 2 * .pi }
        return .slice(Int(((angle + sweep / 2) / sweep).rounded(.down)) % count)
    }

    /// Radians, 0 = up, clockwise.
    public func midAngle(of index: Int) -> CGFloat { CGFloat(index) * sweep }

    /// Centre of the slice's band, relative to the ring's centre, y up.
    public func labelPoint(of index: Int) -> CGPoint {
        let radius = (innerRadius + outerRadius) / 2, angle = midAngle(of: index)
        return CGPoint(x: radius * sin(angle), y: radius * cos(angle))
    }

    /// The side of the square the ring and its band need.
    public var extent: CGFloat { (outerRadius + margin) * 2 }

    /// Where to centre the ring so its whole extent stays inside `visibleFrame` (Cocoa coordinates).
    /// A frame smaller than the ring gets it centred.
    public static func centre(near pointer: CGPoint, extent: CGFloat, in visibleFrame: CGRect) -> CGPoint {
        let half = extent / 2
        func fit(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low + half <= high - half ? min(max(value, low + half), high - half) : (low + high) / 2
        }
        return CGPoint(x: fit(pointer.x, visibleFrame.minX, visibleFrame.maxX),
                       y: fit(pointer.y, visibleFrame.minY, visibleFrame.maxY))
    }
}
