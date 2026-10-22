// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Knarr",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KnarrCore", targets: ["KnarrCore"]),
        .library(name: "KnarrUI", targets: ["KnarrUI"]),
        // Shared with the iPhone app: the records Knarr keeps in the person's private CloudKit database.
        .library(name: "KnarrSync", targets: ["KnarrSync", "KnarrText"]),
        .executable(name: "Knarr", targets: ["KnarrApp"]),
        .executable(name: "knarr-snapshot", targets: ["KnarrSnapshot"]),
        .executable(name: "knarr-notification-qa", targets: ["KnarrNotificationQA"]),
        .executable(name: "knarr-mcp", targets: ["knarr-mcp"]),
    ],
    targets: [
        // Models, panel grouping, liveness rules and the KnarrStore contract the UI talks to.
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        // Markdown blocks and code tokens for Stallari's text; Foundation only, shared with the iPhone app.
        .target(name: "KnarrText"),
        .target(name: "KnarrCore", dependencies: ["CSQLite", "KnarrText"], resources: [.copy("Resources/session-api.mjs"), .copy("Resources/install-restart.sh"), .copy("Resources/hird"), .copy("Resources/stallari"), .copy("Resources/instructions"), .copy("Resources/hive")]),
        // SwiftUI screens. Depends only on KnarrCore, never on a concrete runtime.
        .target(name: "KnarrUI", dependencies: ["KnarrCore"], resources: [.copy("Resources/Knarr.png"), .copy("Resources/ChatWeb")]),
        // Records, CloudKit coding and the phone-side model. No KnarrCore so the iPhone app can link it.
        .target(name: "KnarrSync"),
        // Mac side of the phone link: projects the store into records, raises alerts, applies phone requests.
        .target(name: "KnarrMirror", dependencies: ["KnarrCore", "KnarrSync"]),
        // Local MCP adapter: protocol, tool catalog, Unix-socket host and the app-side service.
        .target(name: "KnarrMCP", dependencies: ["KnarrCore"]),
        // stdio MCP server an external client launches; forwards to the running Knarr app.
        .executableTarget(name: "knarr-mcp", dependencies: ["KnarrCore", "KnarrMCP"], path: "Sources/KnarrMCPBridge"),
        .executableTarget(name: "KnarrApp", dependencies: ["KnarrCore", "KnarrUI", "KnarrMirror", "KnarrMCP"]),
        // Renders the home screen with sample data to PNG files for design review.
        .executableTarget(name: "KnarrSnapshot", dependencies: ["KnarrCore", "KnarrUI"]),
        // Isolated synthetic native-notification probe; never opens the live runtime or user database.
        .executableTarget(name: "KnarrNotificationQA", dependencies: ["KnarrCore"]),
        .testTarget(name: "KnarrCoreTests", dependencies: ["KnarrCore", "KnarrUI", "KnarrMCP"]),
        .testTarget(name: "KnarrSyncTests", dependencies: ["KnarrSync"]),
        .testTarget(name: "KnarrMirrorTests", dependencies: ["KnarrMirror", "KnarrCore", "KnarrSync"]),
    ]
)
