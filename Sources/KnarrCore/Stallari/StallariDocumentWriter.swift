import CryptoKit
import Darwin
import Foundation

/// The only project-file mutation exposed to Stallari. All paths below the
/// registered root are walked without symlinks, including otherwise safe aliases.
enum StallariDocumentWriter {
    struct Result: Sendable {
        let path: String
        let byteCount: Int
        let created: Bool
        let hash: String

        var json: OMPJSON {
            .object(["path": .string(path), "byteCount": .number(Double(byteCount)),
                     "created": .bool(created), "hash": .string(hash)])
        }
    }

    // Serialize host sessions too: two expectedHash writers must not both replace
    // the same version. External editors do not participate in this lock.
    private static let lock = NSLock()
    private static let excluded = Set([".git", ".build", "node_modules", "outputs", ".worktrees", ".claude"])
    private static var unsafePath: StallariError { .rejectedEvidence("허용된 프로젝트의 일반 .md 문서 경로만 쓸 수 있어요.") }
    private static var conflict: StallariError { .rejectedEvidence("문서가 바뀌었어요. 다시 읽고 해시를 확인해 주세요.") }
    private static var writeFailure: StallariError { .rejectedEvidence("문서를 저장하지 못했어요. 경로와 쓰기 권한을 확인해 주세요.") }

    static func write(root: URL, path: String, content: String, expectedHash: String? = nil) throws -> Result {
        let components = try validatedComponents(path)
        let expected: String?
        if let expectedHash {
            guard expectedHash.utf8.count == 64,
                  expectedHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw StallariError.rejectedEvidence("expectedHash는 SHA256 해시여야 해요.")
            }
            expected = expectedHash.lowercased()
        } else { expected = nil }

        lock.lock()
        defer { lock.unlock() }
        let rootFD: Int32
        do { rootFD = try HirdSecureFile.openDirectory(root.resolvingSymlinksInPath()) }
        catch { throw unsafePath }
        var parent = rootFD
        defer { _ = Darwin.close(parent) }
        for component in components.dropLast() {
            var next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                if expected != nil { throw conflict }
                guard mkdirat(parent, component, 0o755) == 0 || errno == EEXIST else { throw writeFailure }
                next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw unsafePath }
            _ = Darwin.close(parent)
            parent = next
        }
        let name = components[components.count - 1]
        var before = stat()
        let exists = fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT { throw unsafePath }
        if exists {
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw unsafePath }
        } else if expected != nil { throw conflict }

        let old = exists ? openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) : -1
        defer { if old >= 0 { _ = Darwin.close(old) } }
        if exists {
            var opened = stat()
            guard old >= 0, fstat(old, &opened) == 0, unchanged(before, opened) else { throw conflict }
            if let expected, try hash(file: old) != expected { throw conflict }
        }

        // Never truncate an existing inode. A same-directory temporary file makes
        // the replacement atomic and leaves the old document intact on I/O errors.
        let temporary = ".knarr-document-" + UUID().uuidString
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw writeFailure }
        defer { _ = Darwin.close(output); _ = unlinkat(parent, temporary, 0) }
        var text = content
        var digest = SHA256()
        let byteCount = try text.withUTF8 { bytes in
            digest.update(bufferPointer: UnsafeRawBufferPointer(bytes))
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw writeFailure }
                offset += count
            }
            return bytes.count
        }
        guard fchmod(output, exists ? before.st_mode & 0o777 : 0o644) == 0,
              fsync(output) == 0 else { throw writeFailure }

        var current = stat()
        if exists {
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  unchanged(before, current) else { throw conflict }
            if let expected {
                guard lseek(old, 0, SEEK_SET) == 0, try hash(file: old) == expected else { throw conflict }
            }
            guard renameat(parent, temporary, parent, name) == 0 else { throw writeFailure }
        } else {
            // RENAME_EXCL prevents a new document, symlink or hardlink introduced
            // since the initial check from being silently overwritten.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw conflict }
                throw writeFailure
            }
        }
        return Result(path: path, byteCount: byteCount, created: !exists, hash: hex(digest.finalize()))
    }

    private static func validatedComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw unsafePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts.last.map({ ($0 as NSString).pathExtension.lowercased() }) == "md" else { throw unsafePath }
        let folded = parts.map { $0.lowercased() }
        for (index, component) in folded.enumerated() {
            guard !excluded.contains(component), component != "agents.md", component != "claude.md" else { throw unsafePath }
            if component == "copilot-instructions.md", index > 0, folded[index - 1] == ".github" { throw unsafePath }
        }
        return parts
    }

    private static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == 1 && rhs.st_nlink == 1 && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func hash(file: Int32) throws -> String {
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw writeFailure }
            if count == 0 { return hex(digest.finalize()) }
            buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
