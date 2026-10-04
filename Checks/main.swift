import Foundation

// Self-check for agent matching and the working/quiet decision.
// Run with ./build.sh check. Pass --live to watch this Mac's agents instead.

func proc(_ pid: pid_t, _ ppid: pid_t, _ path: String, start: TimeInterval, cpuMs: Double = 0) -> Proc {
    var p = Proc(pid: pid, ppid: ppid, uid: getuid(), start: start, comm: (path as NSString).lastPathComponent)
    p.path = path
    p.cpu = UInt64(cpuMs * 1e6)
    return p
}

func table(_ procs: [Proc]) -> [pid_t: Proc] {
    Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
}

if CommandLine.arguments.contains("--live") {
    let tracker = Tracker()
    ClaudeSessions.folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    while true {
        let now = Date().timeIntervalSince1970
        let snapshot = ProcessTable.snapshot()
        var sightings = Agent.find(in: snapshot, agents: Agent.all)
        for i in sightings.indices where sightings[i].agent.id == "claude" {
            sightings[i].status = ClaudeSessions.status(pid: sightings[i].pid, started: snapshot[sightings[i].pid]?.start ?? 0)
        }
        let holders = Assertions.holders()
        var working = tracker.update(table: snapshot, sightings: sightings, asserting: Set(holders.keys), now: now)
        let apps = Agent.appsWorking(agents: Agent.all, holders: holders, table: snapshot, counted: working)
        working.formUnion(apps.map(\.pid))
        sightings += apps
        print("--", Date().formatted(date: .omitted, time: .standard), "\(working.count) working")
        for s in sightings.sorted(by: { $0.pid < $1.pid }) {
            let state = working.contains(s.pid) ? "working" : "quiet"
            let folder = (ProcessTable.workingDirectory(s.pid) as NSString).lastPathComponent
            let source = s.status.map { $0 ? ", reports busy" : ", reports idle" } ?? (s.oneShot ? ", one-shot" : "")
            print("  \(s.pid) \(s.agent.name) [\(state)\(source)] \(folder) · \(Agent.host(of: s.pid, in: snapshot))")
        }
        Thread.sleep(forTimeInterval: 5)
    }
}

// Matching: native binary, version launcher, npm script, wrappers counted once.
let args: [pid_t: [String]] = [
    20: ["node", "/opt/homebrew/bin/gemini"],
    21: ["node", "--max-old-space-size=8192", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"],
    30: ["claude", "-p", "fix the tests"],
    31: ["claude", "--output-format", "stream-json", "--input-format", "stream-json", "-p"],
    40: ["codex", "exec", "add a readme"],
    41: ["codex", "app-server", "--listen", "unix:///tmp/codex.sock"],
    60: ["ollama", "serve"],
]
let apps = table([
    proc(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude", start: 0),
    proc(11, 10, "/Users/me/.local/share/claude/versions/2.1.300", start: 0),
    proc(20, 1, "/opt/homebrew/bin/node", start: 0),
    proc(21, 20, "/opt/homebrew/bin/node", start: 0),
    proc(30, 1, "/opt/homebrew/bin/claude", start: 0),
    proc(31, 1, "/opt/homebrew/bin/claude", start: 0),
    proc(40, 1, "/opt/homebrew/bin/codex", start: 0),
    proc(41, 1, "/opt/homebrew/bin/codex", start: 0),
    proc(42, 1, "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", start: 0),
    proc(50, 1, "/usr/bin/ssh", start: 0),
    proc(60, 1, "/Applications/Ollama.app/Contents/Resources/ollama", start: 0),
    proc(61, 60, "/Applications/Ollama.app/Contents/Resources/llama-server", start: 0),
    proc(70, 1, "/Applications/Cursor.app/Contents/MacOS/Cursor", start: 0),
])
let found = Dictionary(uniqueKeysWithValues: Agent.find(in: apps, agents: Agent.all) { args[$0] ?? [] }.map { ($0.pid, $0) })
assert(found[10] == nil, "the Claude desktop app itself is not an agent")
assert(found[11]?.agent.id == "claude", "native installer binary named by version")
assert(found[20]?.agent.id == "gemini" && found[21] == nil, "a CLI relaunching itself counts once")
assert(found[30]?.oneShot == true, "claude -p is one-shot")
assert(found[31]?.oneShot == false, "stream-json input keeps a session alive")
assert(found[40]?.oneShot == true, "codex exec is one-shot")
assert(found[50] == nil, "unrelated processes are ignored")
assert(found[41] == nil, "the detached Codex daemon is a host, its terminal session counts")
assert(found[42]?.agent.id == "claude", "npm installs run claude.exe")
assert(found[60] == nil && found[61]?.agent.id == "llamacpp", "ollama serve hosts runners, which count by CPU")
assert(found[70] == nil, "apps count only through their sleep assertion")

// Apps: an assertion counts the app, unless an agent already counted runs inside it.
assert(Agent.appsWorking(agents: Agent.all, holders: [70: ["Electron"]], table: apps, counted: []).map(\.agent.id) == ["cursor-app"])
let insideClaude = table([proc(80, 1, "/Applications/Claude.app/Contents/MacOS/Claude", start: 0),
                          proc(81, 80, "/Users/me/Library/Application Support/Claude/claude-code/2.1.300/claude.app/Contents/MacOS/claude", start: 0)])
assert(Agent.appsWorking(agents: Agent.all, holders: [80: ["bridge_turn:1"]], table: insideClaude, counted: [81]).isEmpty)
assert(Agent.appsWorking(agents: Agent.all, holders: [80: ["Electron"]], table: insideClaude, counted: []).isEmpty,
       "Claude's general keep-awake setting is not agent work")
assert(Agent.appsWorking(agents: Agent.all, holders: [80: ["bridge_turn:1"]], table: insideClaude, counted: []).count == 1)

// Activity: CPU per process tree, fresh tools, startup services, quiet timeout.
let claude = Agent.all[0]
func run(_ steps: [(TimeInterval, [Proc])], oneShot: Bool = false) -> [Bool] {
    let tracker = Tracker()
    return steps.map { now, procs in
        !tracker.update(table: table(procs), sightings: [Sighting(pid: 100, agent: claude, oneShot: oneShot)], now: now).isEmpty
    }
}
let agentAt = { (t: TimeInterval, cpuMs: Double) in proc(100, 1, "/x/claude", start: 0, cpuMs: cpuMs) }

// Idle at the prompt: 2 ms of CPU per second.
assert(run([(100, [agentAt(100, 200)]), (105, [agentAt(105, 210)]), (110, [agentAt(110, 220)])]) == [false, false, false])

// Streaming: 100 ms per second, then silent until the quiet timeout passes.
assert(run([(100, [agentAt(100, 0)]), (105, [agentAt(105, 500)]), (150, [agentAt(150, 501)]), (170, [agentAt(170, 502)])])
       == [false, true, true, false])

// A silent tool (sleep) started mid-turn keeps it working; an MCP server started with the agent does not.
let mcp = proc(101, 100, "/usr/local/bin/node", start: 2)
let sleep = proc(102, 100, "/bin/sleep", start: 300)
assert(run([(300, [agentAt(300, 0), mcp]), (305, [agentAt(305, 1), mcp])]) == [false, false])
assert(run([(305, [agentAt(305, 0), mcp, sleep]), (310, [agentAt(310, 1), mcp, sleep])]) == [true, true])
assert(run([(1000, [agentAt(1000, 0), mcp, sleep]), (1005, [agentAt(1005, 1), mcp, sleep])]) == [false, false],
       "a silent tool stops counting after the tool window")

// A long, busy build counts at any age.
let build = { (cpuMs: Double) in proc(103, 100, "/usr/bin/swift-frontend", start: 50, cpuMs: cpuMs) }
assert(run([(2000, [agentAt(2000, 0), build(0)]), (2005, [agentAt(2005, 0), build(2500)])]) == [false, true])

// A freshly started agent busy loading is not working yet.
let fresh = { (cpuMs: Double) in proc(100, 1, "/x/claude", start: 3000, cpuMs: cpuMs) }
assert(run([(3002, [fresh(0)]), (3007, [fresh(900)]), (3012, [fresh(1500)])]) == [false, false, false])

// An agent's own status wins over its CPU, but a heavy background build still counts.
func runStatus(_ status: Bool, _ steps: [(TimeInterval, [Proc])]) -> [Bool] {
    let tracker = Tracker()
    return steps.map { now, procs in
        !tracker.update(table: table(procs), sightings: [Sighting(pid: 100, agent: claude, oneShot: false, status: status)], now: now).isEmpty
    }
}
assert(runStatus(true, [(100, [agentAt(100, 0)]), (105, [agentAt(105, 0)])]) == [true, true], "busy while silent")
assert(runStatus(false, [(100, [agentAt(100, 0)]), (105, [agentAt(105, 900)])]) == [false, false], "idle despite CPU blips")
assert(runStatus(false, [(2000, [agentAt(2000, 0), build(0)]), (2005, [agentAt(2005, 0), build(2500)])]) == [false, true])

// A caffeinate child or the agent's own assertion means it is mid-turn.
let caffeinate = proc(104, 100, "/usr/bin/caffeinate", start: 50)
let tracker = Tracker()
assert(!tracker.update(table: table([agentAt(2000, 0), caffeinate]), sightings: [Sighting(pid: 100, agent: claude, oneShot: false)],
                       asserting: [104], now: 2000).isEmpty)

// Loaded model runners count only while they compute.
let ollama = Agent.all.first { $0.id == "llamacpp" }!
let runner = { (cpuMs: Double) in proc(110, 1, "/x/llama-server", start: 0, cpuMs: cpuMs) }
let child = proc(111, 110, "/x/helper", start: 900)
let modelTracker = Tracker()
let modelRun = [(TimeInterval(1000), [runner(0), child]), (1005, [runner(1), child]), (1010, [runner(800), child])].map { now, procs in
    !modelTracker.update(table: table(procs), sightings: [Sighting(pid: 110, agent: ollama, oneShot: false)], now: now).isEmpty
}
assert(modelRun == [false, false, true])

// One-shot runs work for as long as they live.
assert(run([(100, [agentAt(100, 0)])], oneShot: true) == [true])

print("Checks passed")
