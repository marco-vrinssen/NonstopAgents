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
    /// Local model runtimes rather than agents.
    var isModel = false
}

extension Agent {
    static let all: [Agent] = [
        Agent(id: "claude", name: "Claude Code", binaries: ["claude"],
              patterns: ["/claude/versions/", "@anthropic-ai/claude-code", "@anthropic-ai/claude-agent-sdk", "claude-code-acp"],
              oneShot: ["-p", "--print"]),
        Agent(id: "codex", name: "Codex", binaries: ["codex"],
              patterns: ["@openai/codex", "codex-acp"], oneShot: ["exec"]),
        Agent(id: "gemini", name: "Gemini CLI", binaries: ["gemini"],
              patterns: ["@google/gemini-cli"], oneShot: ["-p", "--prompt"]),
        Agent(id: "copilot", name: "Copilot", binaries: ["copilot", "copilot-runtime"],
              patterns: ["@github/copilot"], oneShot: ["-p", "--prompt"]),
        Agent(id: "cursor", name: "Cursor Agent", binaries: ["cursor-agent"],
              patterns: ["/cursor-agent/"], oneShot: ["-p", "--print"]),
        Agent(id: "opencode", name: "OpenCode", binaries: ["opencode"],
              patterns: ["opencode-ai"], oneShot: ["run"]),
        Agent(id: "aider", name: "Aider", binaries: ["aider"],
              oneShot: ["-m", "--message", "--message-file"]),
        Agent(id: "amp", name: "Amp", binaries: ["amp"],
              patterns: ["@sourcegraph/amp"], oneShot: ["-x", "--execute"]),
        Agent(id: "goose", name: "Goose", binaries: ["goose", "goosed"], oneShot: ["run"]),
        Agent(id: "qwen", name: "Qwen Code", binaries: ["qwen"],
              patterns: ["@qwen-code/qwen-code"], oneShot: ["-p", "--prompt"]),
        Agent(id: "crush", name: "Crush", binaries: ["crush"], oneShot: ["run"]),
        Agent(id: "droid", name: "Droid", binaries: ["droid"], oneShot: ["exec"]),
        Agent(id: "kiro", name: "Kiro CLI", binaries: ["kiro-cli", "kiro-cli-chat", "qchat"]),
        Agent(id: "cline", name: "Cline", binaries: ["cline", "cline-core"]),
        Agent(id: "kilo", name: "Kilo Code", binaries: ["kilocode", "kilo"], patterns: ["@kilocode/cli"]),
        Agent(id: "continue", name: "Continue", binaries: ["cn"], patterns: ["@continuedev/cli"],
              oneShot: ["-p", "--print"]),
        Agent(id: "auggie", name: "Auggie", binaries: ["auggie"], patterns: ["@augmentcode/auggie"],
              oneShot: ["-p", "--print"]),
        Agent(id: "openhands", name: "OpenHands", binaries: ["openhands"]),
        Agent(id: "vibe", name: "Mistral Vibe", binaries: ["vibe"], patterns: ["mistral-vibe"]),
        Agent(id: "grok", name: "Grok CLI", binaries: ["grok"], patterns: ["@vibe-kit/grok-cli"]),
        Agent(id: "plandex", name: "Plandex", binaries: ["plandex", "pdx"]),
        Agent(id: "ollama", name: "Ollama", binaries: ["ollama"], isModel: true),
        Agent(id: "llamacpp", name: "llama.cpp", binaries: ["llama-server", "llama-cli"], isModel: true),
        Agent(id: "lmstudio", name: "LM Studio", patterns: ["/.lmstudio/"], isModel: true),
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
            if !agent.oneShot.isEmpty {
                let list = args ?? arguments(p.pid)
                // The Agent SDK and editor extensions pass prompts over stdin and stay alive.
                let streaming = list.contains { $0.hasPrefix("--input-format") }
                oneShot = !streaming && list.dropFirst().contains { arg in
                    agent.oneShot.contains(arg) || agent.oneShot.contains { arg.hasPrefix($0 + "=") }
                }
            }
            found[p.pid] = Sighting(pid: p.pid, agent: agent, oneShot: oneShot)
        }

        return found.values.filter { sighting in
            var pid = table[sighting.pid]?.ppid ?? 0
            while pid > 1, let parent = table[pid] {
                if found[pid]?.agent.id == sighting.agent.id { return false }
                pid = parent.ppid
            }
            return true
        }
    }

    /// The app an agent runs in, such as Terminal, Warp or Visual Studio Code.
    static func host(of pid: pid_t, in table: [pid_t: Proc]) -> String {
        var current = table[pid]?.ppid ?? 0
        var last = ""
        while current > 1, let p = table[current] {
            if let range = p.path.range(of: ".app/") {
                let bundle = p.path[..<range.lowerBound]
                return String(bundle[bundle.index(after: bundle.lastIndex(of: "/") ?? bundle.startIndex)...])
            }
            last = p.name
            current = p.ppid
        }
        return ["zsh", "bash", "fish", "sh", "login", "launchd"].contains(last) ? "" : last
    }
}
