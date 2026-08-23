import CryptoKit
import Darwin
import Foundation

enum ExportSupport {
    static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSON.encode(value)
    }

    static func writeCanonicalJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        fileWriter: any ExportWriting
    ) throws {
        let data = try canonicalJSONData(value)
        try writeNonDestructive(data, to: url, fileWriter: fileWriter)
    }

    static func writeNonDestructive(
        _ data: Data,
        to url: URL,
        fileWriter: any ExportWriting
    ) throws {
        if fileWriter.fileExists(at: url) {
            let existing = try fileWriter.contents(at: url)
            guard existing == data else {
                throw ExportError.collision(path: url.path)
            }
            return
        }
        try fileWriter.write(data, to: url)
    }

    static func safeFilename(for asset: PhotoAsset) -> String {
        if let publicFilename = asset.publicFilename {
            let normalized = normalizedFilename(publicFilename)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let extensionName = asset.mediaKind == .video ? "mov" : "jpg"
        return "\(asset.id).\(extensionName)"
    }

    static func validateRoot(_ url: URL) throws {
        try rejectSymlinkIfPresent(at: url)
        let standardized = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().path
        guard standardized == resolved else {
            throw ExportError.symlinkPath(url.path)
        }
    }

    static func validatedChildURL(root: URL, childName: String) throws -> URL {
        guard !childName.isEmpty else {
            throw ExportError.unsafePath(childName)
        }
        guard childName == URL(fileURLWithPath: childName).lastPathComponent else {
            throw ExportError.unsafePath(childName)
        }
        let candidate = root.appendingPathComponent(childName, isDirectory: false)
        try rejectSymlinkIfPresent(at: candidate)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedCandidate.hasPrefix(resolvedRoot + "/") || resolvedCandidate == resolvedRoot else {
            throw ExportError.unsafePath(candidate.path)
        }
        return candidate
    }

    static func rejectSymlinkIfPresent(at url: URL) throws {
        var fileInfo = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &fileInfo)
        }
        if result == 0 {
            guard fileInfo.st_mode & S_IFMT != S_IFLNK else {
                throw ExportError.symlinkPath(url.path)
            }
            return
        }
        guard errno == ENOENT else {
            throw ExportError.unsafePath(url.path)
        }
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(ofFile url: URL, fileWriter: any ExportWriting) throws -> String {
        let data = try fileWriter.contents(at: url)
        return sha256Hex(of: data)
    }

    static func byteCount(of url: URL, fileWriter: any ExportWriting) throws -> Int64 {
        let attributes = try fileWriter.attributesOfItem(at: url)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func normalizedFilename(_ filename: String) -> String {
        let stripped = URL(fileURLWithPath: filename).lastPathComponent
        let sanitized = stripped
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }
}
