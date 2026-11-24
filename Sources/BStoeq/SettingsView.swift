import SwiftUI
import UniformTypeIdentifiers
import BStoeqCore

enum Palette {
    static let accent = Color(red: 0.43, green: 0.34, blue: 0.84)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.075)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var filter: ItemVisibility?
    @State private var allApps = false
    @FocusState private var searchFocused: Bool
    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                topbar
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let error = model.shortcutError { banner(error.text(using: model.localizer), icon: "keyboard", color: .orange) }
                        if let error = model.engineError { banner(error.text(using: model.localizer), icon: "exclamationmark.triangle", color: .orange) }
                        if let error = model.error {
                            HStack {
                                banner(error.text(using: model.localizer), icon: "exclamationmark.triangle", color: .orange)
                                Button { model.error = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel(L("Kapat"))
                            }
                        }
                        if let notice = model.notice {
                            HStack { banner(notice.text(using: model.localizer), icon: "checkmark.circle", color: .green)
                                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }
                        }
                        switch model.selection {
                        case "behavior": behaviorPage
                        case "shortcuts": shortcutsPage
                        case "downloads": DownloadsView(model: model, downloads: model.downloads)
                        case "converter": ConvertView(model: model, converter: model.converter) {
                            WatchFoldersView(model: model, watch: model.watch, converter: model.converter)
                        }
                        case "disk": DiskView(model: model, disk: model.disk)
                        case "cache": CacheCleanupView(model: model, cache: model.cache)
                        case "duplicates": DuplicatesView(model: model, finder: model.duplicates)
                        case "uninstall": UninstallView(model: model, uninstaller: model.uninstaller)
                        case "permissions": PermissionsView(model: model, permissions: model.permissions)
                        case "general": generalPage
                        default: menuPage
                        }
                    }.padding(30)
                }
                footer
            }.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 980, minHeight: 772)
        .background(Palette.page)
        .tint(Palette.accent)
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .environment(\.locale, Locale(identifier: model.localizer.language.rawValue))
        .preferredColorScheme(model.preferences.appearance == "dark" ? .dark : model.preferences.appearance == "light" ? .light : nil)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                Text("BStoeq").font(.system(size: 26, weight: .semibold, design: .rounded)).tracking(-1)
            }.padding(.top, 30).padding(.bottom, 24).padding(.horizontal, 23)
            Text(L("ÇALIŞMA ALANIN")).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.tertiary).padding(.leading, 25).padding(.bottom, 12)
            nav("menu", L("Menü çubuğu"), "menubar.rectangle")
            nav("behavior", L("Davranış"), "slider.horizontal.3")
            nav("shortcuts", L("Kısayollar"), "command")
            nav("downloads", L("İndirmeler"), "arrow.down.circle")
            nav("converter", L("Dönüştürücü"), "arrow.triangle.2.circlepath")
            nav("disk", L("Disk alanı"), "internaldrive")
            nav("cache", L("Temizlik"), "sparkles")
            nav("duplicates", L("Kopya dosyalar"), "doc.on.doc")
            nav("uninstall", L("Uygulama kaldır"), "xmark.app")
            nav("archives", L("Arşivler"), "archivebox") { model.openArchives?() }
            nav("permissions", L("İzinler"), "lock.shield")
            nav("general", L("Genel"), "gearshape")
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Palette.accent)
                Text(L("Az kalabalık.\nDaha çok odak.")).font(.system(size: 15, weight: .medium)).lineSpacing(4)
                Text(L("Menü çubuğun, senin düzenin.")).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .padding(15)
            HStack(spacing: 6) {
                Circle().fill(model.engine.available ? .green : .orange).frame(width: 5, height: 5)
                Text(model.engine.available ? L("Mac’inde çalışıyor") : L("Motor kullanılamıyor"))
                Spacer(); Text("v\(appVersion)")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 23).padding(.bottom, 19)
        }.frame(width: 207).background(Palette.card.opacity(0.55))
    }

    private func nav(_ id: String, _ title: String, _ symbol: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() }
            else { withAnimation(.easeInOut(duration: 0.15)) { model.selection = id } }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 19)
                Text(title).font(.system(size: 12, weight: model.selection == id ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 4)
                if model.selection == id { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
            }.foregroundStyle(model.selection == id ? Palette.accent : Color.primary.opacity(0.65))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(model.selection == id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 3)
    }

    private var pageTitle: String {
        switch model.selection {
        case "behavior": L("Davranış")
        case "shortcuts": L("Klavye kısayolları")
        case "downloads": L("İndirmeler")
        case "converter": L("Dönüştürücü")
        case "disk": L("Disk alanı")
        case "cache": L("Temizlik")
        case "duplicates": L("Kopya dosyalar")
        case "uninstall": L("Uygulama kaldır")
        case "permissions": L("İzinler")
        case "general": L("Genel")
        default: L("Menü çubuğu")
        }
    }
    private var topbar: some View {
        HStack {
            Text(pageTitle).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.expanded ? Color.orange : Palette.accent).frame(width: 6, height: 6)
                Text(model.revealingAll ? L("Tüm simgeler açık") : model.expanded ? L("Gizli simgeler açık") : L("Odak görünümü"))
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Button { model.toggle() } label: {
                Label(model.expanded ? L("Gizle") : L("Gizlileri göster"), systemImage: model.expanded ? "eye.slash" : "eye")
                    .font(.system(size: 11, weight: .medium))
            }.buttonStyle(.bordered).controlSize(.small).padding(.leading, 12)
        }.padding(.horizontal, 30).frame(height: 60)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
            Text(L("Değişiklikler otomatik kaydedilir"))
            Spacer()
            Text(L("Tümünü göster")).foregroundStyle(.tertiary)
            Text("⌥ ⌘ 0").font(.system(size: 10, design: .monospaced))
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 30).frame(height: 37).background(Palette.card.opacity(0.4))
    }

    private var menuPage: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading(L("Her şey yerli yerinde."), L("Gerekenler göz önünde. Diğerleri bir kısayol uzağında."))
            MenuBarEditorView(model: model, layout: model.menuLayout)
            SystemMenuSettingsView(model: model)
            if model.conflict {
                banner(L("Başka bir menü çubuğu yöneticisi açık. Tutarlı bir düzen için birini kullanmanı öneririz."), icon: "info.circle", color: .orange)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cursorarrow.and.square.on.square.dashed").foregroundStyle(Palette.accent).padding(.top, 2)
                Text(L("Uygulamaları aşağıdaki gruplara sürükleyerek görünürlüklerini seç. Sıralama için yukarıdaki düzenleyiciyi kullan."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            HStack(alignment: .top, spacing: 11) {
                ForEach(ItemVisibility.allCases, id: \.self) { visibility in groupCard(visibility) }
            }
            if !model.trusted {
                HStack(spacing: 13) {
                    Image(systemName: "hand.raised.fingers.spread").font(.system(size: 22)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Sadece menü çubuğu uygulamalarını gör")).font(.system(size: 12, weight: .medium))
                        Text(L("İsteğe bağlı Erişilebilirlik izni, simgesi olan uygulamaları otomatik bulur."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("İzin ver")) { model.requestAccessibility() }.controlSize(.small)
                }.padding(16).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            }
            appSection
        }
    }

    private func groupCard(_ visibility: ItemVisibility) -> some View {
        let items = model.availableApps.filter { !$0.protected && model.visibility($0.id) == visibility }
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Image(systemName: visibility.symbol).foregroundStyle(Palette.accent)
                Text(L(visibility.title)).fontWeight(.medium).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(items.count)").foregroundStyle(.tertiary)
            }.font(.system(size: 10))
            if items.isEmpty {
                Text(L("Buraya sürükle")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: 30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 36), spacing: 6)],
                          alignment: .leading, spacing: 8) {
                    ForEach(items) { app in
                        appIcon(app, size: 23).frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .help(app.running ? app.name : "\(app.name) · \(L("Çalışmıyor · tercih kaydedildi"))")
                            .accessibilityIdentifier("group-\(visibility.rawValue)-\(app.id)")
                            .contextMenu {
                                ForEach(ItemVisibility.allCases, id: \.self) { option in
                                    Button { model.assign(app.id, to: option) } label: {
                                        Label(L(option.title), systemImage: model.visibility(app.id) == option ? "checkmark" : option.symbol)
                                    }
                                }
                            }
                            .onDrag { NSItemProvider(object: app.id as NSString) }
                    }
                }
            }
            Text(visibility == .visible ? L("Daima elinin altında") : visibility == .hidden ? L("Tıklayınca ya da kısayolla") : L("Yalnızca tümünü gösterince"))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                guard let first = providers.first else { return false }
                _ = first.loadObject(ofClass: NSString.self) { object, _ in
                    guard let id = object as? String else { return }
                    DispatchQueue.main.async { model.assign(id, to: visibility) }
                }
                return true
            }
    }

    private var filteredApps: [BarApp] {
        (allApps ? model.apps : model.availableApps).filter {
            (filter == nil || model.visibility($0.id) == filter) &&
            (model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) || $0.id.localizedCaseInsensitiveContains(model.search))
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(model.owners == nil || allApps ? L("Uygulamalar") : L("Menü çubuğu uygulamaları")).font(.system(size: 14, weight: .semibold))
                Text("\(filteredApps.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.line, in: Capsule())
                Spacer()
                Button { model.refreshApps(); model.scanOwners() } label: {
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(model.scanning ? 180 : 0))
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("Uygulamaları yenile"))
            }
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(L("Uygulama ara…"), text: $model.search).textFieldStyle(.plain)
                        .accessibilityIdentifier("app-search")
                        .focused($searchFocused)
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary) }
                }.font(.system(size: 11)).padding(9).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                Picker(L("Filtre"), selection: $filter) {
                    Text(L("Tümü")).tag(nil as ItemVisibility?)
                    Text(L("Görünür")).tag(ItemVisibility.visible as ItemVisibility?)
                    Text(L("Gizli")).tag(ItemVisibility.hidden as ItemVisibility?)
                    Text(L("Daima gizli")).tag(ItemVisibility.alwaysHidden as ItemVisibility?)
                }.labelsHidden().frame(width: 130).controlSize(.small)
            }
            if model.owners == nil {
                Text(L("Çalışan uygulamalar listeleniyor; hepsinin menü çubuğu simgesi olmayabilir."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Toggle(L("Tüm çalışan uygulamaları göster"), isOn: $allApps).toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                if filteredApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text(L("Bu görünümde uygulama yok")).font(.system(size: 12, weight: .medium))
                        Text(L("Aramanı veya filtreyi değiştirebilirsin.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(30)
                }
                ForEach(filteredApps) { app in
                    appRow(app)
                    if app.id != filteredApps.last?.id { Divider().padding(.leading, 52).opacity(0.5) }
                }
            }.background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line))
        }
    }

    private func appRow(_ app: BarApp) -> some View {
        HStack(spacing: 11) {
            appIcon(app, size: 27)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 11, weight: .medium))
                Text(!app.running ? L("Çalışmıyor · tercih kaydedildi") : app.protected ? L("Sistem uygulaması") : app.id)
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if app.protected {
                Label(L("Sistem yönetir"), systemImage: "lock").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Picker(L("%@ görünürlüğü", app.name), selection: Binding(get: { model.visibility(app.id) }, set: { model.assign(app.id, to: $0) })) {
                    ForEach(ItemVisibility.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                }.labelsHidden().frame(width: 175).controlSize(.small)
            }
        }.padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: app.id as NSString) }
    }

    private var behaviorPage: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading(L("Senin ritmine uysun."), L("Simgelerin ne zaman görünüp ne zaman gizleneceğini seç."))
            settingsCard(L("Açılma biçimi")) {
                VStack(alignment: .leading, spacing: 15) {
                    Text(L("BStoeq’e tıkladığında gizli uygulamalar nasıl açılsın?"))
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach(RevealMode.allCases, id: \.self) { mode in
                            Button { model.update { $0.revealMode = mode } } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: mode.symbol).font(.system(size: 24))
                                    Text(L(mode.title)).font(.system(size: 11, weight: .medium))
                                    Image(systemName: model.preferences.revealMode == mode ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .foregroundStyle(model.preferences.revealMode == mode ? Palette.accent : .secondary)
                                    .background(Palette.accent.opacity(model.preferences.revealMode == mode ? 0.10 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.preferences.revealMode == mode ? Palette.accent.opacity(0.5) : Palette.line))
                            }.buttonStyle(.plain).accessibilityLabel(L(mode.title))
                                .accessibilityValue(model.preferences.revealMode == mode ? L("Seçili") : "")
                                .accessibilityIdentifier("reveal-mode-\(mode.rawValue)")
                        }
                    }
                    Text(L("Alt çubuk ve liste, Gizli grubundaki uygulamaları gösterir. Daima gizli grubu yalnızca Tümünü göster ile açılır."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("Seçili biçimi dene")) { model.hide(); model.toggle() }
                            .controlSize(.small).accessibilityIdentifier("preview-reveal-mode")
                        Spacer()
                        Text(L("Aynı seçim simgeye tıklarken ve kısayolu kullanırken geçerlidir."))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }.padding(17)
            }
            settingsCard(L("GÖSTER VE GİZLE")) {
                settingToggle(L("Otomatik gizle"), L("Açılan simgeleri belirlediğin süre sonunda yeniden gizle."), symbol: "timer", key: \.autoHide)
                Divider().padding(.leading, 52)
                HStack {
                    Text(L("Bekleme süresi")).font(.system(size: 12)); Spacer()
                    Picker(L("Bekleme süresi"), selection: binding(\.autoHideDelay)) {
                        ForEach(Array(Set([2.0, 3, 5, 10, 15, 30, 60, model.preferences.autoHideDelay])).sorted(), id: \.self) { Text(model.localizer.seconds(Int($0))).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }.padding(17).disabled(!model.preferences.autoHide)
                Divider().padding(.leading, 52)
                settingToggle(L("Dışarı tıklayınca gizle"), L("Menü çubuğundan ayrıldığında sade görünüme dön."), symbol: "cursorarrow.click", key: \.hideOnOutsideClick)
                Divider().padding(.leading, 52)
                settingToggle(L("Üzerine gelince göster"), L("İmleci BStoeq simgesinin üzerinde kısa bir süre tut. Erişilebilirlik izni gerektirir."), symbol: "cursorarrow.rays", key: \.revealOnHover)
            }
            if model.preferences.revealOnHover && !model.trusted {
                HStack {
                    banner(L("Üzerine gelince göstermek için Erişilebilirlik izni ver."), icon: "hand.raised", color: Palette.accent)
                    Button(L("İzin ver")) { model.requestAccessibility() }.controlSize(.small)
                }
            }
            settingsCard(L("AKILLI GÖRÜNÜRLÜK")) {
                settingToggle(L("Etkin uygulamayı göster"), L("Gizli bir uygulamaya geçtiğinde onun simgesini göster. Daima gizli grubunu etkilemez."), symbol: "app.badge", key: \.showWhenActive)
            }
            banner(L("İmlecin menü çubuğundayken veya fare düğmesine basılı tutarken otomatik gizleme bekler."), icon: "info.circle", color: Palette.accent)
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading(L("Bir hareket kadar yakın."), L("Fareye uzanmadan menü çubuğunun kontrolünü eline al."))
            settingsCard(L("KLAVYE KISAYOLLARI")) {
                shortcutRow(L("Gizlileri göster / gizle"), L("Görünür ve sade görünüm arasında geçiş yap."), symbol: "eye", key: \.toggleShortcut)
                Divider().padding(.leading, 52)
                shortcutRow(L("BStoeq’i aç ve ara"), L("Uygulama listesini aç; aramaya hemen başla."), symbol: "magnifyingglass", key: \.settingsShortcut)
                Divider().padding(.leading, 52)
                HStack(spacing: 14) {
                    settingIcon("arrow.uturn.backward")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Tüm simgeleri geri getir")).font(.system(size: 12, weight: .medium))
                        Text(L("Daima gizli grubu dahil. Sen gizleyene kadar açık kalır.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("⌥ ⌘ 0").font(.system(size: 13, design: .monospaced)).padding(9).background(Palette.line, in: RoundedRectangle(cornerRadius: 7))
                }.padding(17)
            }
            banner(L("Değiştirmek istediğin kısayola tıkla ve yeni tuşlara bas. Vazgeçmek için Esc kullan. ⌥ ⌘ 0 kurtarma için ayrılmıştır."), icon: "keyboard", color: Palette.accent)
            Button(L("Varsayılan kısayolları geri yükle")) { model.update { $0.toggleShortcut = .toggle; $0.settingsShortcut = .settings } }.controlSize(.small)
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading(L("Küçük ayrıntılar, senin seçimin."), L("BStoeq’i Mac’inin doğal bir parçası haline getir."))
            settingsCard(L("Dil")) {
                HStack(spacing: 16) {
                    settingIcon("globe")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Uygulama dili")).font(.system(size: 12, weight: .medium))
                        Text(L("Değişiklik hemen uygulanır; yeniden başlatma gerekmez.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(L("Uygulama dili"), selection: binding(\.language)) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language == .system ? L(language.nativeName) : language.nativeName).tag(language)
                        }
                    }.labelsHidden().frame(width: 195).accessibilityIdentifier("app-language")
                }.padding(17)
            }
            settingsCard(L("BAŞLANGIÇ VE GÖRÜNÜM")) {
                HStack(spacing: 14) {
                    settingIcon("power")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Oturum açıldığında başlat")).font(.system(size: 12, weight: .medium))
                        Text(L("Mac’in hazır olduğunda BStoeq de hazır olsun.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(L("Oturum açıldığında başlat"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.padding(17)
                Divider().padding(.leading, 52)
                HStack {
                    Text(L("Görünüm")).font(.system(size: 12)); Spacer()
                    Picker(L("Görünüm"), selection: binding(\.appearance)) {
                        Text(L("Sistem")).tag("system"); Text(L("Açık")).tag("light"); Text(L("Koyu")).tag("dark")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 230)
                }.padding(17)
                Divider().padding(.leading, 52)
                HStack {
                    Text(L("Menü çubuğu simgesi")).font(.system(size: 12)); Spacer()
                    ForEach(Preferences.icons, id: \.self) { icon in
                        Button { model.update { $0.icon = icon } } label: {
                            Image(systemName: icon).font(.system(size: 16)).frame(width: 32, height: 30)
                                .foregroundStyle(model.preferences.icon == icon ? Palette.accent : .secondary)
                                .background(model.preferences.icon == icon ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel(L(Preferences.iconNames[icon] ?? icon))
                    }
                }.padding(17)
            }
            settingsCard(L("AYARLARINI YANINDA TAŞI")) {
                HStack(spacing: 10) {
                    settingIcon("square.and.arrow.up")
                    Text(L("Gruplarını ve tercihlerini yedekle.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("İçe aktar…")) { model.importSettings() }
                    Button(L("Dışa aktar…")) { model.exportSettings() }
                }.controlSize(.small).padding(17)
            }
            HStack(alignment: .top, spacing: 16) {
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text("BStoeq \(appVersion)").font(.system(size: 14, weight: .semibold))
                    Text(L("Mac’inde, sana özel. Hesap yok, analitik yok; ağ yalnızca başlattığın indirmelerde kullanılır."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(L("macOS 27 ve Apple Silicon için. Gizleme sistemi macOS’un özel MenuBarClientCore arayüzünü kullanır; sistem güncellemeleri uyumluluğu etkileyebilir."))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3)
                    Button(L("Açık kaynak lisansı")) {
                        if let url = Bundle.main.url(forResource: "Stash-LICENSE", withExtension: "txt") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.link).font(.system(size: 10))
                }
            }.padding(.top, 7)
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func appIcon(_ app: BarApp, size: CGFloat) -> some View {
        Group {
            if let icon = app.icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).opacity(app.running ? 1 : 0.45)
    }
    private func banner(_ message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            Spacer(minLength: 0)
        }.padding(12).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }
    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Some titles are shared with menus and stored in normal case; a section
            // heading is always capitals, by the rules of the chosen language (i → İ).
            Text(title).textCase(.uppercase).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
    private func binding<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func settingIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.accent)
            .frame(width: 27, height: 27)
    }
    private func settingToggle(_ title: String, _ subtitle: String, symbol: String, key: WritableKeyPath<Preferences, Bool>) -> some View {
        HStack(spacing: 14) {
            settingIcon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: binding(key)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(17)
    }
    private func shortcutRow(_ title: String, _ subtitle: String, symbol: String, key: WritableKeyPath<Preferences, Shortcut>) -> some View {
        HStack(spacing: 14) {
            settingIcon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutRecorder(shortcut: model.preferences[keyPath: key], language: model.preferences.language) { value in
                let other = key == \.toggleShortcut ? model.preferences.settingsShortcut : model.preferences.toggleShortcut
                guard value.keyCode != other.keyCode || value.modifiers != other.modifiers else {
                    model.error = UserMessage("Bu kombinasyon diğer BStoeq kısayoluna atanmış."); return false
                }
                model.update { $0[keyPath: key] = value }; return true
            }.frame(width: 170, height: 30)
        }.padding(17)
    }
}

struct BrandMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(LinearGradient(colors: [Color(red: 0.58, green: 0.47, blue: 0.95), Palette.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: size * 0.08) {
                Capsule().fill(.white).frame(width: size * 0.105, height: size * 0.32)
                Capsule().fill(.white).frame(width: size * 0.105, height: size * 0.51)
                Capsule().fill(.white.opacity(0.6)).frame(width: size * 0.105, height: size * 0.24)
            }
        }.frame(width: size, height: size)
    }
}
