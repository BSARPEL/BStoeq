import SwiftUI
import AppKit
import ArchiveCore

struct AppSheetView: View {
    @ObservedObject var model: AppModel
    let kind: AppSheet
    @FocusState private var passwordFocused: Bool
    @FocusState private var nameFocused: Bool
    private func L(_ key: String) -> String { model.L(key) }
    private var title: String {
        switch kind {
        case .create: "Create archive"; case .extract: "Extract files"; case .settings: "Settings"
        case .info: "Archive information"; case .rename: "Rename item"; case .password: "Password required"; case .report: "Operation report"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: kind == .password ? "lock.shield" : "archivebox").font(.system(size: 23)).foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(title)).font(.system(size: 19, weight: .semibold))
                    Text("BStoeq").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch kind {
                    case .create: createContent
                    case .extract: extractContent
                    case .settings: settingsContent
                    case .info: infoContent
                    case .rename:
                        TextField(L("New name"), text: $model.newName).textFieldStyle(.roundedBorder).focused($nameFocused)
                        if model.isArchive { note("The original archive will be kept as a .backup file.") }
                    case .password:
                        Text(model.passwordContext.isEmpty ? L("Encrypted archive") : model.passwordContext).font(.system(size: 12))
                        SecureField(L("Password"), text: $model.passwordInput).textFieldStyle(.roundedBorder).focused($passwordFocused).onSubmit { if !model.passwordInput.isEmpty && !model.busy { model.acceptPassword() } }
                        note("Passwords are kept only for the current archive session.")
                    case .report:
                        Text(model.report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24)
            }.frame(maxHeight: kind == .create ? 520 : kind == .report ? 440 : 430)
            Divider()
            HStack(spacing: 10) {
                if kind == .report { Button(L("Save report…")) { model.exportReport() } }
                Spacer()
                Button(L([.settings, .info, .report].contains(kind) ? "Close" : "Cancel")) {
                    model.sheet = nil; model.createPassword = ""; model.confirmPassword = ""; model.passwordInput = ""
                }.keyboardShortcut(.cancelAction)
                switch kind {
                case .create: Button(L("Create")) { model.create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.busy || model.createFiles.isEmpty || model.createDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.createPassword != model.confirmPassword || (model.createOptions.format == .rar && model.rarURL == nil))
                case .extract: Button(L("Extract")) { model.extract() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || model.extractParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.extractSelected && model.selection.isEmpty))
                case .rename: Button(L("Rename")) { model.rename() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .password: Button(L("Unlock")) { model.acceptPassword() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || model.passwordInput.isEmpty)
                default: EmptyView()
                }
            }.padding(18)
        }.frame(width: kind == .report ? 720 : 620).tint(Theme.teal)
            .onAppear { if kind == .password { passwordFocused = true }; if kind == .rename { nameFocused = true } }
    }
    private var createContent: some View {
        Group {
            section("Files") {
                HStack {
                    Text("\(model.createFiles.count) " + L("items selected")).font(.system(size: 12, weight: .medium))
                    Spacer(); Button(L("Choose…")) { let files = model.chooseInputs(); if !files.isEmpty { model.createFiles = files } }
                }
                Text(model.createFiles.map(\.lastPathComponent).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            section("Archive destination") {
                HStack { TextField(L("File path"), text: $model.createDestination); Button(L("Browse…")) { model.chooseCreateDestination() } }.textFieldStyle(.roundedBorder)
                note("Existing archives are never overwritten.")
            }
            section("Compression") {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Format")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker(L("Format"), selection: $model.createOptions.format) {
                            ForEach(ArchiveFormat.allCases, id: \.self) { format in
                                Text(format == .rar && model.rarURL == nil ? L("RAR — connect an engine") : format.rawValue.uppercased()).tag(format).disabled(format == .rar && model.rarURL == nil)
                            }
                        }.labelsHidden().frame(width: 230)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Compression level")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker(L("Compression level"), selection: $model.createOptions.level) {
                            Text(L("Store (no compression)")).tag(0)
                            Text(L("Fastest")).tag(1); Text(L("Fast")).tag(3); Text(L("Normal")).tag(5)
                            Text(L("Maximum")).tag(7); Text(L("Ultra")).tag(9)
                        }.labelsHidden().frame(width: 240).disabled(model.createOptions.format == .tar)
                    }
                }
                if model.createOptions.format == .sevenZip || model.createOptions.format == .rar { Toggle(L("Solid archive (smaller size)"), isOn: $model.createOptions.solid).font(.system(size: 12)) }
                if model.createOptions.format.supportsVolumes {
                    HStack {
                        Text(L("Split into volumes")).font(.system(size: 12))
                        Spacer()
                        TextField("MB", value: $model.createOptions.volumeMB, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                        Text(L("MB · 0 = one file")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    note("Keep every volume together. Open the first part (.001 or .part1.rar).")
                }
                if model.createOptions.format == .rar {
                    HStack { Text(L("Recovery record (%)")); TextField("0", value: $model.createOptions.recoveryPercent, format: .number).textFieldStyle(.roundedBorder).frame(width: 70) }
                }
            }
            if model.createOptions.format.supportsPassword {
                section("Encryption") {
                    HStack {
                        SecureField(L("Password (optional)"), text: $model.createPassword)
                        SecureField(L("Confirm password"), text: $model.confirmPassword)
                    }.textFieldStyle(.roundedBorder)
                    if !model.confirmPassword.isEmpty && model.createPassword != model.confirmPassword {
                        Text(L("Passwords do not match")).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    if model.createOptions.format != .zip { Toggle(L("Encrypt file names"), isOn: $model.createOptions.encryptNames).font(.system(size: 12)).disabled(model.createPassword.isEmpty) }
                    note(model.createOptions.format == .zip ? "AES-256 ZIP requires a compatible extractor such as BStoeq, 7-Zip or WinRAR." : "AES-256 encryption. Keep your password safe; it cannot be recovered.")
                }
            }
            section("Compression profiles") {
                HStack {
                    Menu(L("Load profile")) { ForEach(model.profiles) { profile in Button(profile.name) { model.createOptions = profile.options } } }.disabled(model.profiles.isEmpty)
                    TextField(L("Profile name"), text: $model.profileName).textFieldStyle(.roundedBorder)
                    Button(L("Save")) { model.saveProfile() }.disabled(model.profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                note("Profiles save compression settings, never passwords.")
            }
        }.onChange(of: model.createOptions.format) { old, new in
            if model.createDestination.lowercased().hasSuffix("." + old.rawValue) {
                model.createDestination = String(model.createDestination.dropLast(old.rawValue.count)) + new.rawValue
            }
            if !new.supportsPassword { model.createPassword = ""; model.confirmPassword = "" }
            if !new.supportsVolumes { model.createOptions.volumeMB = 0 }
        }
    }
    private var extractContent: some View {
        Group {
            Text(model.archive?.lastPathComponent ?? "").font(.system(size: 14, weight: .medium))
            section("Destination folder") {
                HStack { TextField(L("Folder path"), text: $model.extractParent); Button(L("Browse…")) { model.chooseExtractDestination() } }.textFieldStyle(.roundedBorder)
                note("A new folder is created for the archive. Existing files remain unchanged.")
            }
            Picker(L("Contents"), selection: $model.extractSelected) {
                Text(L("All files")).tag(false)
                Text(L("Selected items") + " (\(model.selection.count))").tag(true).disabled(model.selection.isEmpty)
            }.pickerStyle(.radioGroup)
            Toggle(L("Show extracted files in Finder"), isOn: $model.revealAfterExtract)
            HStack {
                Image(systemName: "checkmark.shield").foregroundStyle(Theme.teal)
                Text(L("Files are checked before extraction and published only after success.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var settingsContent: some View {
        Group {
            section("Language") {
                Picker(L("Application language"), selection: Binding(get: { model.language }, set: model.changeAppLanguage)) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                }
            }
            section("RAR engine (optional)") {
                Text(L("RAR extraction is included for free. Creating and repairing RAR archives requires your own licensed RAR command-line engine.")).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Image(systemName: model.rarURL == nil ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(model.rarURL == nil ? .secondary : Theme.teal)
                    Text(model.rarURL?.path ?? L("Not connected")).font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(L("Connect…")) { model.chooseRAR() }
                }
                HStack {
                    Link(L("Official RAR downloads"), destination: URL(string: "https://www.rarlab.com/download.htm")!)
                    Spacer()
                    if model.rarURL != nil { Button(L("Disconnect")) { model.rarPath = "" } }
                }.font(.system(size: 11))
                if model.archive?.pathExtension.lowercased() == "rar" { Button(L("Repair current RAR archive")) { model.sheet = nil; model.repair() }.disabled(model.rarURL == nil) }
            }
            section("Archive tools") {
                HStack { Button(L("Benchmark")) { model.sheet = nil; model.benchmark() }; Button(L("Clear recent archives")) { model.recent = [] } }
                note("Editing ZIP, 7z and TAR keeps a .backup copy beside the original. Encrypted and multipart archives are read-only; use Convert to create an editable copy.")
                note("Archives containing symbolic or hard links are not extracted by this version.")
            }
            section("Finder integration") {
                note("In Finder, right-click files → Services → BStoeq.")
            }
            section("About BStoeq") {
                Text("BStoeq " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " · macOS").font(.system(size: 12, weight: .medium))
                Text(L("Independent archive manager. Not affiliated with WinRAR or RARLAB.")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L("Windows .exe self-extractors and Windows shell extensions are not provided.")).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Text("7-Zip 26.04 · Igor Pavlov").font(.system(size: 11))
                    Spacer()
                    Button(L("Licenses & source")) {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
    private var infoContent: some View {
        Group {
            Text(model.archive?.lastPathComponent ?? "").font(.system(size: 16, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                GridRow { Text(L("Files")); Text("\(model.listing.entries.filter { !$0.isDirectory }.count)") }
                GridRow { Text(L("Uncompressed size")); Text(MainView.bytes(model.listing.totalSize, language: model.language)) }
                ForEach(model.listing.metadata.keys.sorted().filter { $0 != "Path" }, id: \.self) { key in
                    GridRow { Text(L(key)).foregroundStyle(.secondary); Text(model.listing.metadata[key] ?? "").textSelection(.enabled) }
                }
            }.font(.system(size: 12))
            if let row = model.selectedRows.first {
                Divider(); Text(row.name).font(.system(size: 12, weight: .semibold))
                Text("CRC: " + (row.crc.isEmpty ? "—" : row.crc)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(title)).font(.system(size: 12, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
