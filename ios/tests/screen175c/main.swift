import Foundation

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

let query = CoverCatalog175C.query(title: "A&B", artist: "歌手")!
let queryItems = URLComponents(url: query, resolvingAgainstBaseURL: false)!.queryItems!
check(query.host == "itunes.apple.com", "Apple-only lookup")
check(queryItems.first?.value == "A&B 歌手", "metadata must be encoded as a single value")
check(CoverCatalog175C.query(title: " ", artist: "歌手") == nil, "skip empty metadata")
let accepted = URL(string: "https://is1-ssl.mzstatic.com/art.jpg")!
let rejected = URL(string: "https://a.mzstatic.com.untrusted.example/art.jpg")!
check(CoverCatalog175C.allowedArtwork(accepted), "Apple CDN accepted")
check(!CoverCatalog175C.allowedArtwork(rejected), "lookalike CDN rejected")
check(!CoverCatalog175C.allowedArtwork(URL(string: "http://is1-ssl.mzstatic.com/art.jpg")!), "HTTPS required")
let exact = CoverCatalog175C.Match(trackName: "Café", artistName: "Artist", collectionName: "Album", artworkUrl100: accepted)
let wrongAlbum = CoverCatalog175C.Match(trackName: "Cafe", artistName: "artist", collectionName: "Different", artworkUrl100: accepted)
let wrongArtist = CoverCatalog175C.Match(trackName: "Cafe", artistName: "Cover band", collectionName: "Album", artworkUrl100: accepted)
check(CoverCatalog175C.artwork(in: [wrongArtist, wrongAlbum], title: "CAFE", artist: "Artist", album: "Album") == nil, "discard near matches")
check(CoverCatalog175C.artwork(in: [wrongArtist, exact], title: "CAFE", artist: "artist", album: "Album") == accepted, "allow exact normalized match")
check(CoverCatalog175C.batteryPacket(level: 0.921, charging: true) == "#PB,92,1", "battery wire format")
check(CoverCatalog175C.batteryPacket(level: -1, charging: false) == nil, "unknown battery is not 0%")
check(CoverCatalog175C.batteryPacket(level: .nan, charging: false) == nil, "reject invalid battery")
check(CoverCatalog175C.progressSuffix(duration: 212.8, position: 30.9) == ",212,30", "seconds format")
check(CoverCatalog175C.progressSuffix(duration: 10, position: 15) == ",10,10", "clamped playback position")
check(CoverCatalog175C.progressSuffix(duration: .infinity, position: 0) == ",0,0", "empty progress")
print("1.75C cover catalog, phone battery and music progress checks passed")
