import Foundation

/// OMP enforces this policy before executing bash; Knarr does not implement another shell.
enum HirdInspectionPolicy {
    static let tools = ["read", "grep", "glob", "bash", "todo", "ask"]
    // Absolute executable paths prevent project-local PATH entries from replacing a reader.
    // Git accepts only these complete commands: no aliases, -c, external diff or output flags.
    static let commands = [
        "/bin/pwd", "/bin/ls", "/bin/ls *", "/bin/ps *", "/usr/bin/stat *", "/usr/bin/grep *",
        "/usr/bin/sw_vers", "/usr/bin/uname -a",
        "/usr/bin/git --no-optional-locks --no-pager status --porcelain",
        "/usr/bin/git --no-optional-locks --no-pager diff --no-ext-diff --no-textconv",
        "/usr/bin/git --no-optional-locks --no-pager log --no-ext-diff --no-textconv --oneline -20"
    ]
    // Capability and approval boundaries are not editable runtime preferences.
    static let securityArguments = ["--no-extensions", "--no-rules"]
    static let safetyInstructions = "Do not read credentials, tokens, .env or authentication stores, print secrets, modify global OMP settings, or bypass tool approval. Work only in the isolated worktree; do not merge, deploy, or modify the original project."
    static var bashSecurity: OMPJSON {
        let deniedPaths = ["*.env*", "*credentials*", "*auth.json*", "*auth.db*", "*agent.db*", "*.ssh/*", "*.aws/*", "*keychain*"]
        let rules = deniedPaths.map { OMPJSON.object(["match": .string($0), "approval": .string("deny")]) }
            + commands.map { OMPJSON.object(["match": .string($0), "approval": .string("allow")]) }
            + [.object(["match": .string("*"), "approval": .string("deny")])]
        return .object(["direnv": .string("off"), "allowCompoundCommands": .bool(false), "patterns": .array(rules)])
    }
}
