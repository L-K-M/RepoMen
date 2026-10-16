import Foundation
import Darwin

/// The owning tool declares that the entire directory is regenerable using the
/// cache directory tagging specification: https://bford.info/cachedir/.
/// Checking just the filename would turn an unrelated file into permission to delete.
enum CacheDirectoryTag {
    static let fileName = "CACHEDIR.TAG"
    static let signature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
    private static let metadataNames: Set<String> = [".git", ".svn", ".hg", ".trash"]

    static func isValid(in directory: URL) -> Bool {
        guard !directory.pathComponents.contains(where: { metadataNames.contains($0.lowercased()) }),
              (try? directory.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true else {
            return false
        }
        // A tag copied into a checkout must not make that checkout reclaimable.
        // lstat also catches broken symlinks and linked-worktree .git files.
        var metadata = stat()
        for name in [".git", ".svn", ".hg"] {
            if lstat(directory.appendingPathComponent(name).path, &metadata) == 0 {
                return false
            }
        }

        let descriptor = open(directory.appendingPathComponent(fileName).path,
                              O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        // Refuse directories, symlinks, FIFOs and devices without reading them.
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return false }
        return (try? file.read(upToCount: signature.count)) == signature
    }
}
