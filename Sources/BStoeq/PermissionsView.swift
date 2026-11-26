import AppKit
import SwiftUI
import BStoeqCore
import ServiceManagement

struct PermissionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsManager

    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }
    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Hangi izin ne durumda?")).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text(L("BStoeq’in kullandığı macOS izinleri ve her birinin şu anki durumu."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            card(L("BAŞLANGIÇ")) {
                row("power", L("Oturum açıldığında başlat"),
                    L("Mac’ini açıp oturum açtığında BStoeq menü çubuğunda hazır olsun diye. Sistem Ayarları → Genel → Giriş Öğeleri’nde de görünür."),
                    state: model.loginEnabled ? .granted : model.loginNeedsApproval ? .unknown : .denied,
                    unknown: L("Onay bekliyor"), granted: L("Etkin"), denied: L("Kapalı"), identifier: "login-item") {
                    if model.loginNeedsApproval { Button(L("Sistem Ayarlarını aç")) { SMAppService.openSystemSettingsLoginItems() } }
                    else if model.loginEnabled { Button(L("Devre dışı bırak")) { model.setLogin(false) } }
                    else { Button(L("Etkinleştir")) { model.setLogin(true) } }
                }
            }
            card(L("MENÜ ÇUBUĞU")) {
                row("accessibility", L("Erişilebilirlik"),
                    L("Simgeleri sürükleyerek sıralamak, gizli uygulamaların menülerini açmak ve üzerine gelince göstermek için."),
                    state: model.trusted ? .granted : .denied, identifier: "accessibility") {
                    if !model.trusted { Button(L("İzin ver")) { model.requestAccessibility() } }
                    else { Button(L("Sistem Ayarlarını aç")) { Self.openPrivacy("Privacy_Accessibility") } }
                }
            }
            card(L("DOSYALAR VE UYGULAMALAR")) {
                row("externaldrive.badge.checkmark", L("Tam Disk Erişimi"),
                    L("Disk, temizlik ve kopya taramalarında korumalı klasörleri okumak ve kaldırılan uygulamaların korumalı verilerini taşımak için."),
                    state: permissions.fullDisk, unknown: L("Belirlenemedi"), identifier: "full-disk") {
                    Button(L("Sistem Ayarlarını aç")) { Self.openPrivacy("Privacy_AllFiles") }
                }
                ForEach(PermissionsManager.Folder.allCases, id: \.self) { folder in
                    Divider().padding(.leading, 58)
                    let state = permissions.state(of: folder)
                    row("folder", L(folder.titleKey), L("Bu klasördeki dosyaları taramak ve seçtiğin dosyalarla çalışmak için."),
                        state: state, unknown: L("Denetlenmedi"), identifier: folder.rawValue) {
                        if permissions.checking.contains(folder) { ProgressView().controlSize(.small) }
                        else if state == .unknown {
                            Button(L("Denetle")) { permissions.check(folder) }
                                .help(L("macOS bu klasörü daha önce sormadıysa izin penceresini gösterir."))
                        } else if state == .denied {
                            Button(L("Sistem Ayarlarını aç")) { Self.openPrivacy("Privacy_FilesAndFolders") }
                        }
                    }
                }
                Divider().padding(.leading, 58)
                row("app.badge.checkmark", L("Uygulama Yönetimi"),
                    L("Uygulama kaldırırken ve eski uygulamaları temizlerken başka uygulamaları Çöp Sepeti’ne taşımak için."),
                    state: .unknown, unknown: L("macOS bildirmiyor"), identifier: "app-management") {
                    Button(L("Sistem Ayarlarını aç")) { Self.openPrivacy("Privacy_AppBundles") }
                }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(L("İzinlerin hepsi isteğe bağlıdır; simgeleri gizlemek için hiçbiri gerekmez. Tam Disk Erişimi verildiğinde klasör izinleri de verilmiş sayılır. Sistem Ayarları’nda yaptığın bir değişiklik, BStoeq’i kapatıp yeniden açtığında geçerli olabilir."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(12).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
        }
        .onAppear { permissions.refresh(); model.refreshLoginState() }
        // Coming back from System Settings is when an answer may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(); model.refreshLoginState()
        }
    }

    private func row<Actions: View>(_ symbol: String, _ title: String, _ subtitle: String, state: PermissionState,
                                    unknown: String = "", granted: String? = nil, denied: String? = nil, identifier: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            badge(state, unknown: unknown, granted: granted, denied: denied).accessibilityIdentifier("permission-\(identifier)")
            actions().controlSize(.small)
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }

    private func badge(_ state: PermissionState, unknown: String, granted: String? = nil, denied: String? = nil) -> some View {
        let color: Color = state == .granted ? .green : state == .denied ? .orange : .secondary
        let text = state == .granted ? granted ?? L("Verildi") : state == .denied ? denied ?? L("Verilmedi") : unknown
        return HStack(spacing: 5) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : state == .denied ? "xmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 10)).accessibilityHidden(true)
            Text(text).font(.system(size: 10, weight: .medium))
        }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule()).fixedSize()
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}
