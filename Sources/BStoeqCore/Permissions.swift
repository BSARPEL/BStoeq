import Foundation

public enum PermissionState: Equatable, Sendable {
    case granted, denied
    /// macOS offers no answer, or the place that would give one does not exist.
    case unknown
}

/// Reads what macOS lets this process do by trying it. Privacy permissions have no
/// query interface, so the only reliable answer is whether an access succeeds.
public enum PermissionProbe {
    /// Places only a process with Full Disk Access may open. Opening one never makes
    /// macOS ask the user anything. The system-wide privacy database comes first: it
    /// exists on every Mac, while the per-user places may be missing.
    public static func fullDiskAccessProbes(home: String = NSHomeDirectory()) -> [String] {
        ["/Library/Application Support/com.apple.TCC/TCC.db",
         home + "/Library/Application Support/com.apple.TCC/TCC.db",
         home + "/Library/Safari"]
    }

    /// The first probe that exists decides.
    public static func fullDiskAccess(probes: [String] = fullDiskAccessProbes()) -> PermissionState {
        for path in probes {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .denied }
        }
        return .unknown
    }

    /// Whether a folder can be listed. For Desktop, Documents and Downloads macOS asks
    /// the user the first time, and the call waits for the answer.
    public static func folderAccess(_ path: String) -> PermissionState {
        guard let directory = opendir(path) else {
            return errno == EPERM || errno == EACCES ? .denied : .unknown
        }
        closedir(directory)
        return .granted
    }
}
