import Foundation

public enum CacheSource: String, CaseIterable, Sendable {
    case userCaches, containerCaches, groupContainerCaches, browserCaches, logs, xcode, developerCaches, installers

    public var titleKey: String {
        switch self {
        case .userCaches: "Kullanıcı önbelleği"
        case .containerCaches: "Uygulama kapsayıcıları"
        case .groupContainerCaches: "Paylaşılan kapsayıcılar"
        case .browserCaches: "Tarayıcı ve Electron önbellekleri"
        case .logs: "Eski günlükler"
        case .xcode: "Xcode önbellekleri"
        case .developerCaches: "Geliştirici araçları"
        case .installers: "Disk görüntüleri ve yükleyiciler"
        }
    }
}

/// Each descriptor is created from a known location or one immediate directory
/// name returned by the filesystem. No paths from preferences or user input.
enum CacheRoot: Sendable {
    case user, container(String), groupContainer(String), logs, installers
    case chromium(app: String, area: String)
    case xcodeShared(String), xcodeProject(name: String, area: String)
    case npmTemporary, pipWheels, gradleBuildCache

    static let containers = "Library/Containers"
    static let groupContainers = "Library/Group Containers"
    static let derivedData = "Library/Developer/Xcode/DerivedData"
    static let applicationSupport = "Library/Application Support"

    var source: CacheSource {
        switch self {
        case .user: .userCaches
        case .container: .containerCaches
        case .groupContainer: .groupContainerCaches
        case .chromium: .browserCaches
        case .logs: .logs
        case .xcodeShared, .xcodeProject: .xcode
        case .npmTemporary, .pipWheels, .gradleBuildCache: .developerCaches
        case .installers: .installers
        }
    }

    var relativePath: String {
        switch self {
        case .user: "Library/Caches"
        case .container(let name): Self.containers + "/" + name + "/Data/Library/Caches"
        case .groupContainer(let name): Self.groupContainers + "/" + name + "/Library/Caches"
        case .chromium(let app, let area): Self.applicationSupport + "/" + app + "/" + area
        case .logs: "Library/Logs"
        case .installers: "Downloads"
        case .xcodeShared(let area): Self.derivedData + "/" + area
        case .xcodeProject(let name, let area): Self.derivedData + "/" + name + "/" + area
        case .npmTemporary: ".npm/_cacache/tmp"
        case .pipWheels: ".cache/pip/wheels"
        case .gradleBuildCache: ".gradle/caches/build-cache-1"
        }
    }

    func groupName(for relativeFile: Substring) -> String {
        switch self {
        case .user, .logs:
            return relativeFile.firstIndex(of: "/").map { String(relativeFile[..<$0]) } ?? ""
        case .installers: return String(relativeFile)
        case .container(let name), .groupContainer(let name): return name
        case .chromium(let app, let area): return app + "/" + area
        case .xcodeProject(let name, let area): return name + "/" + area
        case .xcodeShared(let area): return area
        case .npmTemporary: return "npm"
        case .pipWheels: return "pip"
        case .gradleBuildCache: return "Gradle"
        }
    }

    func groupID(name: String) -> String {
        switch self {
        case .user: return name  // Keep existing selection identifiers.
        case .logs, .installers: return "/" + relativePath + "/" + name
        default: return "/" + relativePath
        }
    }

    func accepts(relativeFile: Substring, path: String, status: stat, cutoff: TimeInterval) -> Bool {
        let file = (path as NSString).lastPathComponent.lowercased()
        switch self {
        case .chromium(_, let area):
            guard !relativeFile.contains("/") else { return false }
            // Simple Cache entry streams and sparse streams. Blockfile caches put
            // external payloads in f_XXXXXX; data_N and index files are shared.
            if area == "GPUCache", file.hasPrefix("f_"), file.utf8.count == 8 {
                return file.dropFirst(2).allSatisfy(\.isHexDigit)
            }
            return file.utf8.count == 18 && ["_0", "_1", "_s"].contains(String(file.suffix(2)))
                && file.dropLast(2).allSatisfy(\.isHexDigit)
        case .logs:
            if relativeFile.hasPrefix("DiagnosticReports/"),
               [".ips", ".crash", ".spin", ".hang"].contains(where: file.hasSuffix) { return true }
            return Self.isRotatedLog(file)
        case .installers:
            guard !relativeFile.contains("/"), [".dmg", ".pkg", ".mpkg", ".xip"].contains(where: file.hasSuffix),
                  CacheCleanup.isOld(status.st_birthtimespec, cutoff: cutoff),
                  CacheCleanup.isOld(status.st_ctimespec, cutoff: cutoff) else { return false }
            // A newly downloaded or moved copy can retain the dates of the original.
            // On filesystems without a date-added attribute, creation and inode-change
            // times still guard against a recent arrival.
            let url = URL(fileURLWithPath: path, isDirectory: false)
            if let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate {
                return added.timeIntervalSince1970 <= cutoff
            }
            return true
        case .pipWheels: return file.hasSuffix(".whl")
        case .gradleBuildCache: return [32, 64].contains(file.utf8.count) && file.allSatisfy(\.isHexDigit)
        default: return true
        }
    }

    private static func isRotatedLog(_ file: String) -> Bool {
        var name = file
        if let suffix = [".gz", ".bz2", ".xz"].first(where: file.hasSuffix) {
            name.removeLast(suffix.count)
            if name.hasSuffix(".log") { return true }
        }
        guard let marker = name.range(of: ".log.", options: .backwards) else { return false }
        let suffix = name[marker.upperBound...]
        if suffix == "old" || suffix == "bak" { return true }
        return suffix.first?.isNumber == true && suffix.last?.isNumber == true
            && suffix.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
    }
}
