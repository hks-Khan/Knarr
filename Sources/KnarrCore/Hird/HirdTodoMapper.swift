import Foundation

/// OMP 18.7.0 has no task IDs. Each event replaces the full projection for its run.
/// Keys describe phase/content/duplicate occurrence, never an old array position.
public enum HirdTodoMapper {
    public static func steps(_ phases: OMPJSON) -> [HirdStep] {
        var occurrences: [String: Int] = [:]
        return (phases.array ?? []).flatMap { phase in
            (phase["tasks"]?.array ?? []).compactMap { task -> HirdStep? in
                guard let content = task["content"]?.string, let source = task["status"]?.string else { return nil }
                let state: HirdStep.State
                switch source {
                case "pending", "abandoned": state = .pending
                case "in_progress": state = .active
                case "completed": state = .done
                case "blocked": state = .blocked
                default: state = .pending
                }
                let identity = (phase["name"]?.string ?? "") + "\u{1f}" + content
                let occurrence = occurrences[identity, default: 0]; occurrences[identity] = occurrence + 1
                let blocker = task["blocker"]?.string
                let title = content + (source == "abandoned" ? " (중단)" : "") + (blocker.map { " — " + $0 } ?? "")
                return HirdStep(title: title, state: state, sourceStatus: source, blocker: blocker,
                                sourceKey: identity + "\u{1f}\(occurrence)")
            }
        }
    }
}
