import Foundation

let data = Data([0xac, 0, 0xc7, 80, 80, 1, 0x0b, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
let reading = LyTpms175CWire.decode(data)
precondition(reading == LyTpmsReading(kPa: 250, celsius: 25))
precondition(LyTpms175CWire.decode(Data(data.prefix(8))) == nil)
var invalid = data
invalid[2] = 0
precondition(LyTpms175CWire.decode(invalid) == nil)
invalid = data
invalid[8] = 1
precondition(LyTpms175CWire.decode(invalid) == nil)
precondition(LyTpms175CWire.packet(front: reading, rear: nil) == "#TP|250|-1|25|-99")
precondition(LyTpms175CWire.packet(front: nil, rear: reading) == "#TP|-1|250|-99|25")
precondition(LyTpms175CWire.isFresh(100, now: 159.9))
precondition(!LyTpms175CWire.isFresh(100, now: 160))
precondition(!LyTpms175CWire.isFresh(100, now: 99))
print("LyTPMS decode, 1.75C field order and stale readings passed")
