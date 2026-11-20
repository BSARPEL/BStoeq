import AppKit
import SwiftUI
import BStoeqCore

struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var downloads: MediaDownloadManager
    @State private var problem: UserMessage?
    @State private var copied = false

    static let installCommand = "brew install yt-dlp ffmpeg"
    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private var preferences: Preferences { model.preferences }
    private var destination: URL { MediaDownloadManager.destination(for: preferences.downloadFolder) }
    private var ready: Bool { downloads.tools.ytDlp != nil }
    private var hasFFmpeg: Bool { downloads.tools.ffmpeg != nil }
    private var target: MediaLinkTarget? { MediaLink.target(from: downloads.draftURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("İstediğin an, çevrimdışı.")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("YouTube bağlantısını yapıştır; videoyu veya yalnızca sesini Mac’ine indir."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !ready { toolsCard(missingDownloader: true) }
            else if !hasFFmpeg { toolsCard(missingDownloader: false) }
            card(L("YENİ İNDİRME")) {
                linkRow
                if let target, target.playlist != nil {
                    Divider().padding(.leading, 52)
                    playlistRow(choice: target.video != nil)
                }
                Divider().padding(.leading, 52)
                formatRow
                Divider().padding(.leading, 52)
                folderRow
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    if let problem {
                        Label(problem.text(using: model.localizer), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("download-problem")
                    } else if let notice = downloads.notice {
                        Label(notice.text(using: model.localizer), systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("download-notice")
                    }
                    Spacer(minLength: 0)
                    Button { submit() } label: {
                        Label(L("İndir"), systemImage: "arrow.down.circle.fill").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.borderedProminent)
                        .disabled(!ready || downloads.draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("download-start")
                }.padding(17)
            }
            queue
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").foregroundStyle(Palette.accent)
                Text(L("Yalnızca indirme hakkına sahip olduğun içerikleri indir. BStoeq ağı yalnızca senin başlattığın indirmeler için kullanır."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                Spacer(minLength: 0)
            }.padding(12).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
        }
        .onAppear { downloads.refreshTools() }
    }

    private var linkRow: some View {
        HStack(spacing: 14) {
            rowIcon("link")
            // A verbatim prompt: a literal would be turned into a clickable Markdown link.
            TextField(text: $downloads.draftURL, prompt: Text(verbatim: "https://www.youtube.com/watch?v=…")) { Text(L("YouTube bağlantısı")) }
                .textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel(L("YouTube bağlantısı"))
                .accessibilityIdentifier("download-url")
                .onSubmit { submit() }
                .onChange(of: downloads.draftURL) { _, _ in problem = nil }
            if !downloads.draftURL.isEmpty {
                Button { downloads.draftURL = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(L("Kapat"))
            }
            Button(L("Yapıştır")) {
                // Read the clipboard only on this explicit request.
                if let text = NSPasteboard.general.string(forType: .string) {
                    downloads.draftURL = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                }
            }.controlSize(.small)
        }.padding(17)
    }

    /// A watch link opened from a playlist names both; let the user say which they meant.
    private func playlistRow(choice: Bool) -> some View {
        HStack(spacing: 14) {
            rowIcon("list.bullet")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Oynatma listesi")).font(.system(size: 12, weight: .medium))
                Text(L("Listedeki her video, liste adını taşıyan klasöre sırasıyla indirilir."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if choice {
                Picker(L("Oynatma listesi"), selection: binding(\.downloadWholePlaylist)) {
                    Text(L("Tüm liste")).tag(true)
                    Text(L("Yalnızca bu video")).tag(false)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    .accessibilityIdentifier("download-playlist-mode")
            }
        }.padding(17)
    }

    private var formatRow: some View {
        HStack(spacing: 14) {
            rowIcon(preferences.downloadKind.symbol)
            Picker(L("Tür"), selection: binding(\.downloadKind)) {
                ForEach(MediaKind.allCases, id: \.self) { Text(L($0.title)).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                .accessibilityIdentifier("download-kind")
            Spacer()
            if preferences.downloadKind == .video {
                Text(L("Kalite")).font(.system(size: 12))
                Picker(L("Kalite"), selection: binding(\.videoQuality)) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                }.labelsHidden().frame(width: 150)
            } else {
                Text(L("Biçim")).font(.system(size: 12))
                // Converting to MP3 needs ffmpeg; without it the original M4A is kept.
                Picker(L("Biçim"), selection: hasFFmpeg ? binding(\.audioFormat) : .constant(AudioFormat.m4a)) {
                    ForEach(AudioFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 150).disabled(!hasFFmpeg)
            }
        }.padding(17)
    }

    private var folderRow: some View {
        HStack(spacing: 14) {
            rowIcon("folder")
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Kayıt klasörü")).font(.system(size: 12, weight: .medium))
                Text((destination.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L("Değiştir…")) { chooseFolder() }.controlSize(.small)
        }.padding(17)
    }

    @ViewBuilder private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("İNDİRMELER")).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if downloads.items.count > 1 {
                    Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("download-summary")
                }
                Spacer()
                HStack(spacing: 14) {
                    if downloads.failedCount > 0 && downloads.items.count > 1 {
                        Button(L("Başarısızları yeniden dene")) { downloads.retryFailed() }
                    }
                    if downloads.activeCount > 1 {
                        Button(L("Tümünü iptal et")) { downloads.cancelAll() }
                    }
                    if downloads.hasClearableItems {
                        Button(L("Bitenleri temizle")) { downloads.clearFinished() }
                    }
                }.buttonStyle(.link).font(.system(size: 10))
            }
            LazyVStack(spacing: 0) {
                if downloads.items.isEmpty && downloads.lookups.isEmpty {
                    Text(L("Henüz indirme yok.")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(22)
                }
                ForEach(downloads.lookups) { lookup in
                    lookupRow(lookup)
                    if lookup.id != downloads.lookups.last?.id || !downloads.items.isEmpty {
                        Divider().padding(.leading, 52).opacity(0.5)
                    }
                }
                ForEach(downloads.items) { item in
                    itemRow(item)
                    if item.id != downloads.items.last?.id { Divider().padding(.leading, 52).opacity(0.5) }
                }
            }.background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }

    private var summary: String {
        var parts = [L("%d / %d tamamlandı", downloads.finishedCount, downloads.items.count)]
        if downloads.failedCount > 0 { parts.append(L("%d başarısız", downloads.failedCount)) }
        return parts.joined(separator: " · ")
    }

    private func lookupRow(_ lookup: PlaylistLookup) -> some View {
        HStack(spacing: 14) {
            rowIcon("list.bullet")
            VStack(alignment: .leading, spacing: 5) {
                Text(lookup.url.absoluteString).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if lookup.failure == nil { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                Text(lookup.failure?.text(using: model.localizer) ?? L("Oynatma listesi okunuyor…"))
                    .font(.system(size: 10)).lineLimit(3)
                    .foregroundStyle(lookup.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if lookup.failure == nil {
                iconButton("xmark.circle", L("İptal et")) { downloads.cancel(lookup.id) }
            } else {
                iconButton("minus.circle", L("Listeden kaldır")) { downloads.remove(lookup.id) }
            }
        }.padding(.horizontal, 17).padding(.vertical, 13)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("download-playlist-lookup")
    }

    private func rowTitle(_ item: DownloadItem) -> String {
        let title = item.title ?? item.request.url.absoluteString
        guard let position = item.request.position else { return title }
        return "\(position.label) · \(title)"
    }

    private func itemRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 14) {
            rowIcon(item.request.kind.symbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(rowTitle(item))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let playlistTitle = item.playlistTitle {
                    Label(playlistTitle, systemImage: "list.bullet").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if item.isRunning {
                    if item.state == .processing || item.fraction <= 0 {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    } else {
                        ProgressView(value: item.fraction).controlSize(.small)
                    }
                }
                Text(status(item)).font(.system(size: 10)).lineLimit(3)
                    .foregroundStyle(isFailed(item) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if item.isActive {
                iconButton("xmark.circle", L("İptal et")) { downloads.cancel(item.id) }
            } else {
                if item.state == .finished {
                    iconButton("magnifyingglass.circle", L("Finder’da göster")) { reveal(item) }
                } else {
                    iconButton("arrow.clockwise.circle", L("Yeniden dene")) { downloads.retry(item.id) }
                }
                iconButton("minus.circle", L("Listeden kaldır")) { downloads.remove(item.id) }
            }
        }.padding(.horizontal, 17).padding(.vertical, 13)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("download-item")
    }

    private func isFailed(_ item: DownloadItem) -> Bool {
        if case .failed = item.state { return true }
        return false
    }

    private func status(_ item: DownloadItem) -> String {
        switch item.state {
        case .queued: return L("Sırada")
        case .processing: return L("Dönüştürülüyor…")
        case .finished: return L(item.alreadyPresent ? "Zaten indirilmişti" : "Tamamlandı")
        case .cancelled: return L("İptal edildi")
        case .failed(let message): return message.text(using: model.localizer)
        case .running:
            guard item.fraction > 0 else { return L("Hazırlanıyor…") }
            var parts = ["\(Int((item.fraction * 100).rounded(.down)))%"]
            if let speed = item.speed, speed > 0 {
                parts.append(L("%@/sn", ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)))
            }
            if let eta = item.eta, eta > 0 { parts.append(L("Kalan süre %@", Self.clock(eta))) }
            return parts.joined(separator: " · ")
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(min(seconds, 359_999).rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private func toolsCard(missingDownloader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: missingDownloader ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(missingDownloader ? Color.orange : Palette.accent)
                Text(L(missingDownloader
                       ? "İndirme için yt-dlp gerekli. Terminal’de aşağıdaki komutu çalıştır, ardından Yeniden denetle’ye bas."
                       : "ffmpeg bulunamadı. Videolar tek dosyalı daha düşük kalitede, müzik M4A olarak iner. Tam kalite ve MP3 için ffmpeg kur."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text(missingDownloader ? Self.installCommand : "brew install ffmpeg")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.line, in: RoundedRectangle(cornerRadius: 7))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(missingDownloader ? Self.installCommand : "brew install ffmpeg", forType: .string)
                    copied = true
                } label: {
                    Label(L("Komutu kopyala"), systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }.controlSize(.small)
                Button(L("Yeniden denetle")) { downloads.refreshTools(); copied = false; problem = nil }
                    .controlSize(.small).accessibilityIdentifier("download-tools-recheck")
            }.padding(.leading, 24)
        }.padding(14)
            .background((missingDownloader ? Color.orange : Palette.accent).opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
    }

    private func submit() {
        // Return in the field must not do what the disabled button would not.
        guard ready, !downloads.draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        problem = downloads.enqueue(downloads.draftURL, kind: preferences.downloadKind, quality: preferences.videoQuality,
                                    audioFormat: preferences.audioFormat, destination: destination,
                                    wholePlaylist: preferences.downloadWholePlaylist)
        if problem == nil { downloads.draftURL = "" }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.title = L("İndirme klasörünü seç"); panel.prompt = L("Seç")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.downloadFolder = url.path }
    }

    private func reveal(_ item: DownloadItem) {
        if let file = item.file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(item.request.destination)
        }
    }

    private func binding<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.accent).frame(width: 27, height: 27)
    }
    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}
