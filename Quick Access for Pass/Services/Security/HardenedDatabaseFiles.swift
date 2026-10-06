import Darwin
import Foundation

/// Applies ownership, permission, and backup-exclusion checks to the host database files.
nonisolated enum HardenedDatabaseFiles {
    enum Error: Swift.Error, Equatable {
        case unsafePath
        case posixFailure(Int32)
    }

    private static let databaseFileMode: mode_t = 0o600
    private static let directoryMode: mode_t = 0o700
    private static let sidecarSuffixes = ["", "-wal", "-shm"]

    static func ownerIsValid(actual: uid_t, expected: uid_t) -> Bool {
        actual == expected
    }

    /// Creates or validates only the app-owned database directory.
    static func prepareDatabaseDirectory(for databaseURL: URL) throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        let path = directoryURL.path
        if mkdir(path, directoryMode) != 0 && errno != EEXIST {
            throw Error.posixFailure(errno)
        }
        let identity = try validateAndSetMode(
            at: directoryURL,
            flags: O_RDONLY | O_DIRECTORY,
            fileType: S_IFDIR,
            mode: directoryMode
        )
        try applyBackupExclusion(to: directoryURL, expectedIdentity: identity, fileType: S_IFDIR)
    }

    /// Validates known files without following symlinks and applies private permissions.
    static func protectDatabaseFiles(at databaseURL: URL) throws {
        try prepareDatabaseDirectory(for: databaseURL)
        for suffix in sidecarSuffixes {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileExistsWithoutFollowingSymlink(at: url) else { continue }
            let identity = try validateAndSetMode(
                at: url,
                flags: O_RDONLY,
                fileType: S_IFREG,
                mode: databaseFileMode
            )
            try applyBackupExclusion(to: url, expectedIdentity: identity, fileType: S_IFREG)
        }
    }

    private static func fileExistsWithoutFollowingSymlink(at url: URL) -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            return true
        }
        return errno != ENOENT
    }

    private static func validateAndSetMode(
        at url: URL,
        flags: Int32,
        fileType: mode_t,
        mode: mode_t
    ) throws -> FileIdentity {
        let descriptor = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.unsafePath }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw Error.posixFailure(errno) }
        guard information.st_mode & S_IFMT == fileType,
              ownerIsValid(actual: information.st_uid, expected: getuid()) else {
            throw Error.unsafePath
        }
        guard fchmod(descriptor, mode) == 0 else { throw Error.posixFailure(errno) }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func applyBackupExclusion(
        to url: URL,
        expectedIdentity: FileIdentity,
        fileType: mode_t
    ) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
        let actualIdentity = try validatedIdentity(at: url, fileType: fileType)
        guard actualIdentity == expectedIdentity else { throw Error.unsafePath }
    }

    private static func validatedIdentity(at url: URL, fileType: mode_t) throws -> FileIdentity {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.unsafePath }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw Error.posixFailure(errno) }
        guard information.st_mode & S_IFMT == fileType,
              ownerIsValid(actual: information.st_uid, expected: getuid()) else {
            throw Error.unsafePath
        }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
}
