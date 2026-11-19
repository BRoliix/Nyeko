import Foundation

extension String {
    /// Nyeko's hook relay in a command or a file Nyeko wrote: today's nyeko-hook, or the nb-hook of the builds before
    /// the rebrand (still recognised, so it is found and replaced, never left behind).
    var mentionsNyekoHook: Bool { contains("nyeko-hook") || contains("nb-hook") }
}

/// True when a parsed ~/.claude/settings.json routes Claude Code SessionStart events to Coucou.
///
/// Kept free of file access so it can be tested on fixtures instead of the real settings file.
/// Both the installed app and earlier builds matched on the command text: a hook written by
/// Coucou runs ~/.claude/coucou/nb-hook, and the App Store build names NotchBuddy instead.
func coucouHooksPresent(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let sessionStart = hooks["SessionStart"] as? [[String: Any]] else { return false }
    return sessionStart.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.mentionsNyekoHook || command.contains("NotchBuddy") || command.contains("coucou")
        } ?? false
    }
}
