import Foundation

/// Writes the Sidekick shell-integration scripts to disk and manages their
/// installation into the user's shell rc file.
///
/// The scripts emit:
///  - OSC 7  — the current working directory on every prompt and `cd`,
///             which replaces CWD polling entirely.
///  - OSC 133 — prompt marks: A (prompt drawn), C (command started),
///             D;<exit> (command finished), used for prompt navigation and
///             per-command exit/duration reporting.
enum ShellIntegration {
    static let termProgram = "Sidekick"

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sidekick/shell-integration")
    }

    static var zshScriptURL: URL { directoryURL.appendingPathComponent("sidekick.zsh") }
    static var bashScriptURL: URL { directoryURL.appendingPathComponent("sidekick.bash") }

    private static let zshrcMarker = "# Sidekick shell integration"
    private static var zshrcSourceLine: String {
        "[[ \"$TERM_PROGRAM\" == \"\(termProgram)\" ]] && source \"$HOME/.config/sidekick/shell-integration/sidekick.zsh\""
    }

    /// Writes (or refreshes) the script files. Called at app launch so the
    /// on-disk scripts always match the running app.
    static func installScripts() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try zshScript.write(to: zshScriptURL, atomically: true, encoding: .utf8)
            try bashScript.write(to: bashScriptURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("ShellIntegration: failed to write scripts: \(error)", category: "terminal")
        }
    }

    static var zshrcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    static func isInstalledInZshrc() -> Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return contents.contains("shell-integration/sidekick.zsh")
    }

    /// Appends the source line to ~/.zshrc. Returns false if it was already present.
    @discardableResult
    static func installInZshrc() throws -> Bool {
        guard !isInstalledInZshrc() else { return false }

        var contents = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        if !contents.isEmpty && !contents.hasSuffix("\n") {
            contents += "\n"
        }
        contents += "\n\(zshrcMarker)\n\(zshrcSourceLine)\n"
        try contents.write(to: zshrcURL, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Script contents

    private static let zshScript = #"""
# Sidekick shell integration (zsh)
# Emits OSC 7 (working directory) and OSC 133 (prompt/command marks).
# Safe to source from any terminal; it only activates inside Sidekick.

[[ "$TERM_PROGRAM" != "Sidekick" ]] && return
[[ -n "$SIDEKICK_SHELL_INTEGRATION_ACTIVE" ]] && return
typeset -g SIDEKICK_SHELL_INTEGRATION_ACTIVE=1

__sidekick_report_cwd() {
    printf '\e]7;file://%s%s\e\\' "${HOST:-localhost}" "$PWD"
}

__sidekick_preexec() {
    typeset -g __SIDEKICK_COMMAND_RAN=1
    # Carry the command line, base64-encoded, in the C mark so Sidekick can
    # report it in command records without re-scraping the prompt. tr -d '\n'
    # guards against any line wrapping from base64.
    printf '\e]133;C;%s\e\\' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

__sidekick_precmd() {
    local exit_code=$?
    if [[ -n "$__SIDEKICK_COMMAND_RAN" ]]; then
        unset __SIDEKICK_COMMAND_RAN
        printf '\e]133;D;%s\e\\' "$exit_code"
    fi
    __sidekick_report_cwd
    printf '\e]133;A\e\\'
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __sidekick_precmd
add-zsh-hook preexec __sidekick_preexec
add-zsh-hook chpwd __sidekick_report_cwd

# Apply Sidekick's auto-approve preference only to claude sessions started in a
# Sidekick pane (scoped via this env var; never touches claude run elsewhere).
# A caller's own --permission-mode wins.
if [[ -n "$SIDEKICK_CLAUDE_PERMISSION_MODE" ]]; then
    claude() {
        local arg
        for arg in "$@"; do
            case "$arg" in
                --permission-mode|--permission-mode=*) command claude "$@"; return ;;
            esac
        done
        command claude --permission-mode "$SIDEKICK_CLAUDE_PERMISSION_MODE" "$@"
    }
fi
"""#

    private static let bashScript = #"""
# Sidekick shell integration (bash)
# Emits OSC 7 (working directory) and OSC 133 (prompt/command marks).
# Safe to source from any terminal; it only activates inside Sidekick.

[[ "$TERM_PROGRAM" != "Sidekick" ]] && return
[[ -n "$SIDEKICK_SHELL_INTEGRATION_ACTIVE" ]] && return
SIDEKICK_SHELL_INTEGRATION_ACTIVE=1

__sidekick_report_cwd() {
    printf '\e]7;file://%s%s\e\\' "${HOSTNAME:-localhost}" "$PWD"
}

__sidekick_preexec() {
    # The DEBUG trap fires for every simple command, including our own
    # PROMPT_COMMAND; only emit C for the first command after a prompt.
    [[ -n "$__SIDEKICK_AT_PROMPT" ]] || return 0
    unset __SIDEKICK_AT_PROMPT
    __SIDEKICK_COMMAND_RAN=1
    # Carry the command line, base64-encoded, in the C mark (see zsh note above).
    printf '\e]133;C;%s\e\\' "$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
}

__sidekick_precmd() {
    local exit_code=$?
    if [[ -n "$__SIDEKICK_COMMAND_RAN" ]]; then
        unset __SIDEKICK_COMMAND_RAN
        printf '\e]133;D;%s\e\\' "$exit_code"
    fi
    __sidekick_report_cwd
    printf '\e]133;A\e\\'
    __SIDEKICK_AT_PROMPT=1
}

trap '__sidekick_preexec' DEBUG
PROMPT_COMMAND="__sidekick_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# Apply Sidekick's auto-approve preference only to claude sessions started in a
# Sidekick pane (scoped via this env var; never touches claude run elsewhere).
# A caller's own --permission-mode wins.
if [[ -n "$SIDEKICK_CLAUDE_PERMISSION_MODE" ]]; then
    claude() {
        local arg
        for arg in "$@"; do
            case "$arg" in
                --permission-mode|--permission-mode=*) command claude "$@"; return ;;
            esac
        done
        command claude --permission-mode "$SIDEKICK_CLAUDE_PERMISSION_MODE" "$@"
    }
fi
"""#
}
