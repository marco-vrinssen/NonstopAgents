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
    while true {
        let now = Date().timeIntervalSince1970
        let snapshot = ProcessTable.snapshot()
        let sightings = Agent.find(in: snapshot, agents: Agent.all)
        let working = tracker.update(table: snapshot, sightings: sightings, now: now)
        print("--", Date().formatted(date: .omitted, time: .standard), "\(working.count) working")
        for s in sightings.sorted(by: { $0.pid < $1.pid }) {
            let state = working.contains(s.pid) ? "working" : "quiet"
            let folder = (ProcessTable.workingDirectory(s.pid) as NSString).lastPathComponent
            print("  \(s.pid) \(s.agent.name) [\(state)\(s.oneShot ? ", one-shot" : "")] \(folder) · \(Agent.host(of: s.pid, in: snapshot))")
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
]
let apps = table([
    proc(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude", start: 0),
    proc(11, 10, "/Users/me/.local/share/claude/versions/2.1.300", start: 0),
    proc(20, 1, "/opt/homebrew/bin/node", start: 0),
    proc(21, 20, "/opt/homebrew/bin/node", start: 0),
    proc(30, 1, "/opt/homebrew/bin/claude", start: 0),
    proc(31, 1, "/opt/homebrew/bin/claude", start: 0),
    proc(40, 1, "/opt/homebrew/bin/codex", start: 0),
    proc(50, 1, "/usr/bin/ssh", start: 0),
])
let found = Dictionary(uniqueKeysWithValues: Agent.find(in: apps, agents: Agent.all) { args[$0] ?? [] }.map { ($0.pid, $0) })
assert(found[10] == nil, "the Claude desktop app itself is not an agent")
assert(found[11]?.agent.id == "claude", "native installer binary named by version")
assert(found[20]?.agent.id == "gemini" && found[21] == nil, "a CLI relaunching itself counts once")
assert(found[30]?.oneShot == true, "claude -p is one-shot")
assert(found[31]?.oneShot == false, "stream-json input keeps a session alive")
assert(found[40]?.oneShot == true, "codex exec is one-shot")
assert(found[50] == nil, "unrelated processes are ignored")

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

// One-shot runs work for as long as they live.
assert(run([(100, [agentAt(100, 0)])], oneShot: true) == [true])

print("Checks passed")
