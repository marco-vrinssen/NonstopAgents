import Darwin
import Foundation

/// An AI tool Until recognises by how its processes look on macOS.
struct Agent: Hashable, Identifiable {
    let id: String
    let name: String
    /// Executable or script basenames, matched exactly.
    var binaries: Set<String> = []
    /// Substrings of the executable path or arguments, for installs that hide the name.
    var patterns: [String] = []
    /// Arguments that mark a headless run, which exits when its task is done.
    var oneShot: Set<String> = []
    /// Arguments that mark a long-lived host or bridge rather than an agent run.
    var hosts: Set<String> = []
    /// App bundles whose own sleep assertion means their built-in agent is working.
    var apps: [String] = []
    /// Local model runtimes rather than agents.
    var isModel = false
}

extension Agent {
    // Process shapes verified against each tool's docs and source in October 2026.
    static let all: [Agent] = [
        Agent(id: "claude", name: "Claude Code", binaries: ["claude", "claude.exe"],
              patterns: ["/claude/versions/", "@anthropic-ai/claude-code", "claude-agent-acp", "claude-code-acp"],
              oneShot: ["-p", "--print"], hosts: ["daemon", "remote-control", "--chrome-native-host"]),
        Agent(id: "codex", name: "Codex", binaries: ["codex"], patterns: ["@openai/codex", "codex-acp"],
              oneShot: ["exec"], hosts: ["--listen", "mcp-server"]),
        Agent(id: "copilot", name: "Copilot", binaries: ["copilot", "copilot-runtime"], patterns: ["@github/copilot"],
              oneShot: ["-p", "--prompt"]),
        Agent(id: "cursor", name: "Cursor Agent", binaries: ["cursor-agent"], patterns: ["/cursor-agent/"],
              oneShot: ["-p", "--print"], hosts: ["worker"]),
        Agent(id: "gemini", name: "Gemini CLI", binaries: ["gemini"], patterns: ["@google/gemini-cli"],
              oneShot: ["-p", "--prompt"]),
        Agent(id: "antigravity", name: "Antigravity CLI", binaries: ["agy", "antigravity"]),
        Agent(id: "opencode", name: "OpenCode", binaries: ["opencode", "opencode.exe"], patterns: ["opencode-ai"],
              oneShot: ["run"], hosts: ["--register"]),
        Agent(id: "devin", name: "Devin", binaries: ["devin"], hosts: ["worker"]),
        Agent(id: "amp", name: "Amp", binaries: ["amp"], patterns: ["@sourcegraph/amp"],
              oneShot: ["-x", "--execute"], hosts: ["--runner-id"], apps: ["Amp.app"]),
        Agent(id: "droid", name: "Droid", binaries: ["droid"], oneShot: ["exec"], hosts: ["daemon"]),
        Agent(id: "qwen", name: "Qwen Code", binaries: ["qwen"], patterns: ["@qwen-code/qwen-code"],
              oneShot: ["-p", "--prompt"]),
        Agent(id: "grok", name: "Grok Build", binaries: ["grok"]),
        Agent(id: "kiro", name: "Kiro CLI", binaries: ["kiro-cli", "kiro-cli-chat", "qchat"]),
        Agent(id: "junie", name: "Junie", binaries: ["junie"]),
        Agent(id: "warp", name: "Warp Agent", binaries: ["warp-tui-stable", "warp-tui-preview", "warp-tui"]),
        Agent(id: "goose", name: "Goose", binaries: ["goose", "goosed"], oneShot: ["run"]),
        Agent(id: "crush", name: "Crush", binaries: ["crush"], oneShot: ["run"]),
        Agent(id: "cline", name: "Cline", binaries: ["cline", ".cline"]),
        Agent(id: "kilo", name: "Kilo Code", binaries: ["kilo", "kilocode", ".kilo"], patterns: ["@kilocode/cli"],
              hosts: ["--register"]),
        Agent(id: "auggie", name: "Auggie", binaries: ["auggie"], patterns: ["@augmentcode/auggie", "augment.mjs"],
              oneShot: ["-p", "--print"], hosts: ["daemon"]),
        Agent(id: "continue", name: "Continue", binaries: ["cn"], patterns: ["@continuedev/cli"], oneShot: ["-p", "--print"]),
        Agent(id: "aider", name: "Aider", binaries: ["aider"], oneShot: ["-m", "--message", "--message-file"]),
        Agent(id: "openhands", name: "OpenHands", binaries: ["openhands"]),
        Agent(id: "vibe", name: "Mistral Vibe", binaries: ["vibe", "vibe-acp"], patterns: ["mistral-vibe", "Vibe CLI"]),
        Agent(id: "plandex", name: "Plandex", binaries: ["plandex", "pdx"]),

        // Agents built into apps. These apps hold a sleep assertion while their agent runs.
        Agent(id: "cursor-app", name: "Cursor", apps: ["Cursor.app"]),
        Agent(id: "vscode", name: "VS Code agent", apps: ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"]),
        Agent(id: "claude-app", name: "Claude", apps: ["Claude.app"]),
        Agent(id: "chatgpt-app", name: "ChatGPT", apps: ["ChatGPT.app", "Codex.app"]),

        Agent(id: "ollama", name: "Ollama", binaries: ["ollama"], hosts: ["serve"], isModel: true),
        Agent(id: "llamacpp", name: "llama.cpp", binaries: ["llama-server", "llama-cli", "llama"], isModel: true),
        Agent(id: "lmstudio", name: "LM Studio", binaries: ["llmster"], patterns: ["/.lmstudio/"], isModel: true),
        Agent(id: "mlx", name: "MLX", patterns: ["mlx_lm.server", "mlx_lm.generate"], isModel: true),
    ]

    static func custom(_ name: String) -> Agent {
        Agent(id: "custom:" + name, name: name, binaries: [name])
    }
}

extension Agent {
    private static func isInterpreter(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["node", "bun", "deno", "ruby"].contains(n) || n.hasPrefix("python")
    }

    private static func contains(_ args: [String], _ tokens: Set<String>) -> Bool {
        args.dropFirst().contains { arg in tokens.contains(arg) || tokens.contains { arg.hasPrefix($0 + "=") } }
    }

    /// Finds agent processes of the current user. Wrappers of the same agent
    /// (npx, version launchers, a CLI relaunching itself) count once, at the outermost process.
    static func find(in table: [pid_t: Proc], agents: [Agent], arguments: (pid_t) -> [String] = ProcessTable.arguments) -> [Sighting] {
        var found: [pid_t: Sighting] = [:]
        for p in table.values where !p.path.isEmpty {
            let name = (p.path as NSString).lastPathComponent
            var args: [String]?
            var keys = [name]
            if isInterpreter(name) {
                args = arguments(p.pid)
                if let script = args?.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                    keys.append((script as NSString).lastPathComponent)
                }
            }
            let haystack = ([p.path] + (args ?? [])).joined(separator: " ")
            guard let agent = agents.first(where: { a in
                keys.contains(where: a.binaries.contains) || a.patterns.contains(where: haystack.contains)
            }) else { continue }

            var oneShot = false
            if !agent.oneShot.isEmpty || !agent.hosts.isEmpty {
                let list = args ?? arguments(p.pid)
                if contains(list, agent.hosts) { continue }
                // The Agent SDK and editor extensions pass prompts over stdin and stay alive.
                let streaming = list.contains { $0.hasPrefix("--input-format") }
                oneShot = !streaming && contains(list, agent.oneShot)
            }
            found[p.pid] = Sighting(pid: p.pid, agent: agent, oneShot: oneShot)
        }

        return found.values.filter { sighting in
            var pid = table[sighting.pid]?.ppid ?? 0
            while pid > 1, let parent = table[pid] {
                if let outer = found[pid], outer.agent.id == sighting.agent.id || (outer.agent.isModel && sighting.agent.isModel) {
                    return false
                }
                pid = parent.ppid
            }
            return true
        }
    }

    /// Apps whose built-in agent is working: the app process itself holds a sleep assertion.
    /// Skipped when an agent process already counted runs inside the app, so one task counts once.
    static func appsWorking(agents: [Agent], asserting: Set<pid_t>, table: [pid_t: Proc], counted: Set<pid_t>) -> [Sighting] {
        let insideApp = { (app: pid_t) in
            counted.contains { pid in
                var current = table[pid]?.ppid ?? 0
                while current > 1, let p = table[current] {
                    if current == app { return true }
                    current = p.ppid
                }
                return false
            }
        }
        return asserting.compactMap { pid in
            guard let path = table[pid]?.path,
                  let agent = agents.first(where: { $0.apps.contains { path.contains("/" + $0 + "/") } }),
                  !insideApp(pid) else { return nil }
            return Sighting(pid: pid, agent: agent, oneShot: true)
        }
    }

    /// The app an agent runs in, such as Terminal, Warp or Visual Studio Code.
    static func host(of pid: pid_t, in table: [pid_t: Proc]) -> String {
        var current = table[pid]?.ppid ?? 0
        var last = ""
        while current > 1, let p = table[current] {
            if let range = p.path.range(of: ".app/") {
                return (String(p.path[..<range.lowerBound]) as NSString).lastPathComponent
            }
            last = p.name
            current = p.ppid
        }
        return ["zsh", "bash", "fish", "sh", "login", "launchd"].contains(last) ? "" : last
    }
}
