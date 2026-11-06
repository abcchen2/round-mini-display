"""Run production command keys, state caching and queue replacement without BLE I/O."""
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
ble = (root / 'MotoNav/BleLink.swift').read_text(encoding='utf-8')
settings = (root / 'MotoNav/Settings.swift').read_text(encoding='utf-8')


def method(signature):
    start = ble.index(signature)
    opening = ble.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (ble[end] == '{') - (ble[end] == '}')
        end += 1
    return ble[start:end].replace('private func ', 'func ', 1)


# Execute the real production methods; pump intentionally holds every write to
# model offline operation or a backpressured reconnect before the next BLE burst.
methods = '\n'.join(method(signature) for signature in (
    'private func keyOf(', 'func send(_ msg:', 'private func enqueue('))
replay_start = ble.index('        if let b = lastState["#b"]', ble.index('private func onLinkReady()'))
replay_end = ble.index('        for (slot, img) in lastImg', replay_start)
replay = ble[replay_start:replay_end]
push = '\n'.join(line.strip() for line in settings.splitlines() if line.strip() in (
    'b.send(progressRing ? "#M1" : "#M0")', 'b.send("#L\\(leadMs)")'))
assert len(push.splitlines()) == 2, 'The two production pushAll setting commands must be extracted'

source = '''import Foundation
final class CommandState {
    struct Out { let key: String?; var data: Data }
    var queue: [Out] = []
    var lastState: [String: String] = [:]
    var stateOrder: [String] = []
    var lastImg: [Int: Data] = [:]
    func pump() {}
    func sendClock(_ message: String) { fatalError("Clock I/O is outside this test") }
''' + methods + '''
    func restore() {
        queue.removeAll()
''' + replay + '''
    }
    func pushCurrent(progressRing: Bool, leadMs: Int) {
        let b = self
''' + push + '''
    }
    var messages: [String] { queue.map { String(data: $0.data, encoding: .utf8)! } }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let state = CommandState()
for message in ["#M1", "#M0", "#M1", "#L300", "#L500", "#L300"] { state.send(message) }
check(state.messages == ["#M1", "#L300"], "Offline round trips retain only the current boolean and numeric settings")
check(state.stateOrder == ["#M", "#L"] && state.lastState.count == 2, "Values share one persistent cache key per command")
state.restore()
check(state.messages == ["#M1", "#L300"], "Reconnect replay cannot resurrect the old disabled state or numeric value")
state.pushCurrent(progressRing: true, leadMs: 300)
check(state.messages == ["#M1", "#L300"], "pushAll while reconnect is backpressured leaves no later stale override")
for message in ["#M0", "#M1", "#M0", "#L0", "#L800", "#L0"] { state.send(message) }
check(state.messages == ["#M0", "#L0"], "Reverse boolean and numeric round trips replace already queued writes")
state.restore()
state.pushCurrent(progressRing: false, leadMs: 0)
check(state.messages == ["#M0", "#L0"], "Reconnect also preserves disabled and zero settings")
for value in 0...1000 { state.send("#L\\(value)") }
check(state.queue.count == 2 && state.lastState.count == 2, "Changing numeric values cannot grow the queue or replay cache")
state.restore()
check(state.messages == ["#M0", "#L1000"], "Only the latest numeric value survives reconnect after many changes")
for message in ["#LY,one", "#LY,two", "#ML,1", "#m,1", "#m,0", "L,100", "R,50"] { state.send(message) }
check(state.keyOf("#LY,two") == "#LY" && state.keyOf("#ML,1") == "#ML", "Lyrics commands do not collide with the no-comma settings")
check(state.keyOf("#m,0") == "#m" && state.keyOf("#M0") == "#M", "Map and progress-ring settings remain separate")
check(state.messages.suffix(4) == ["#LY,two", "#ML,1", "#m,0", "R,50"], "Existing comma-delimited and navigation deduplication stays intact")
print("PASS production BLE command caching: offline round trips, bounded queues, reconnect replay and pushAll")
'''

with tempfile.TemporaryDirectory(prefix='motonav-ble-command-state-') as folder:
    folder = Path(folder)
    main = folder / 'main.swift'
    main.write_text(source, encoding='utf-8')
    binary = folder / 'test'
    subprocess.run(['swiftc', '-swift-version', '5', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
