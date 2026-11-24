import AppKit
import ArchiveWorkspace

/// macOS sends every Finder service of this app to one provider object. The archive
/// services stay with the archive window; the converter's goes to the converter page.
@MainActor final class ServicesProvider: NSObject {
    private let archives: ArchiveWindowController
    private let convert: ([URL]) -> Void

    init(archives: ArchiveWindowController, convert: @escaping ([URL]) -> Void) {
        self.archives = archives; self.convert = convert
        super.init()
    }

    @objc(bstoeqArchiveService:userData:error:)
    func bstoeqArchiveService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        archives.bstoeqArchiveService(pasteboard, userData: userData, error: error)
    }

    @objc(bstoeqConvertService:userData:error:)
    func bstoeqConvertService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        convert(files)
    }
}
