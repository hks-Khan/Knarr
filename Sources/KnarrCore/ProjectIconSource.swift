import Foundation

/// Finds artwork inside the registered project, without inspecting build output or worktrees.
public enum ProjectIconSource {
    public static func candidates(in directory: URL) -> [URL] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var candidates: [URL] = []
        func append(_ url: URL) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= 8_000_000,
                  !candidates.contains(resolved) else { return }
            candidates.append(resolved)
        }
        // Explicitly exported project icons take precedence over platform-specific variants.
        for path in ["assets/app-icon.png", "Assets/\(root.lastPathComponent).png", "assets/icon.png", "assets/icon.icns"] {
            append(root.appendingPathComponent(path))
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("app.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let app = (json["expo"] as? [String: Any]) ?? json
            if let icon = app["icon"] as? String { append(root.appendingPathComponent(icon)) }
        }
        let excluded: Set<String> = ["node_modules", "Pods", "Carthage", "vendor", "build", "dist", "outputs", "output", "evidence", "work", "worktrees", "DerivedData", "android", "test", "tests", "fixtures"]
        var queue: [(URL, Int)] = [(root, 0)]
        var catalogs: [URL] = []
        var visited = 0
        while !queue.isEmpty, visited < 2_000 {
            let (directory, depth) = queue.removeFirst()
            visited += 1
            guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.path < $1.path }) {
                let name = child.lastPathComponent
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      !excluded.contains(name), !name.lowercased().contains("watch"),
                      !name.lowercased().contains("widget"), !name.hasSuffix(".app") else { continue }
                if name == "AppIcon.appiconset" { catalogs.append(child) }
                else if depth < 6 { queue.append((child, depth + 1)) }
            }
        }
        for catalog in catalogs.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: catalog.appendingPathComponent("Contents.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else { continue }
            let defaults = images.filter { $0["appearances"] == nil }
                .sorted { ($0["size"] as? String == "1024x1024" ? 0 : 1) < ($1["size"] as? String == "1024x1024" ? 0 : 1) }
            for image in defaults {
                if let filename = image["filename"] as? String { append(catalog.appendingPathComponent(filename)) }
            }
        }
        // Web projects often have no native app target. Never use promotional screenshots.
        for path in ["public/icon.png", "public/favicon.png", "public/favicon.ico", "public/logo.png", "public/logo.svg", "docs/assets/favicon.svg", "assets/icon.svg", "icon.png", "icon.svg"] {
            append(root.appendingPathComponent(path))
        }
        return candidates
    }
}
