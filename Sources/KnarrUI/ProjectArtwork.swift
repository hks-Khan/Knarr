import AppKit
import SwiftUI
import KnarrCore

@MainActor enum AppArtwork {
    static let logo = bundle.url(forResource: "Knarr", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("Knarr_KnarrUI.bundle")) {
            return packaged
        }
        return .module
    }()
}

/// Disk discovery and decoding stay out of SwiftUI's rendering path.
private actor ProjectArtworkCache {
    static let shared = ProjectArtworkCache()
    private var images: [String: Data] = [:]

    func imageData(for path: String) -> Data? {
        if let image = images[path] { return image }
        for url in ProjectIconSource.candidates(in: URL(fileURLWithPath: path, isDirectory: true)) {
            guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { continue }
            images[path] = data
            return data
        }
        return nil
    }
}

struct ProjectIcon: View {
    let project: ProjectSummary
    var size: CGFloat = 30
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size >= 40 ? K.rCard : K.rSmall)
                    .fill(K.projectColor(project.settings.color))
                    .overlay(Text(String(project.name.prefix(1))).font(size >= 40 ? K.title : K.secondary.weight(.semibold)).foregroundStyle(K.onColor))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size >= 40 ? K.rCard : K.rSmall))
        .opacity(project.archived ? 0.55 : 1)
        .accessibilityHidden(true)
        .task(id: project.path) {
            image = nil
            let data = await ProjectArtworkCache.shared.imageData(for: project.path)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
