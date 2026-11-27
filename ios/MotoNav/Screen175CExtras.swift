import Foundation

enum CoverCatalog175C {
    struct Match: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: URL?
    }
    struct Search: Decodable { let results: [Match] }

    static func query(title: String, artist: String) -> URL? {
        guard !normalize(title).isEmpty, !normalize(artist).isEmpty else { return nil }
        var url = URLComponents()
        url.scheme = "https"; url.host = "itunes.apple.com"; url.path = "/search"
        url.queryItems = [URLQueryItem(name: "term", value: "\(title.prefix(120)) \(artist.prefix(120))"),
                          URLQueryItem(name: "media", value: "music"),
                          URLQueryItem(name: "entity", value: "song"),
                          URLQueryItem(name: "limit", value: "15")]
        return url.url
    }

    static func artwork(in hits: [Match], title: String, artist: String, album: String) -> URL? {
        let titleKey = normalize(title), artistKey = normalize(artist), albumKey = normalize(album)
        guard !titleKey.isEmpty, !artistKey.isEmpty else { return nil }
        return hits.lazy.filter {
            normalize($0.trackName ?? "") == titleKey && normalize($0.artistName ?? "") == artistKey &&
            (albumKey.isEmpty || normalize($0.collectionName ?? "") == albumKey)
        }.compactMap(\.artworkUrl100).first(where: allowedArtwork)
    }

    static func allowedArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil else { return false }
        return host.hasSuffix(".mzstatic.com")
    }

    static func batteryPacket(level: Float, charging: Bool) -> String? {
        guard level.isFinite, (0...1).contains(level) else { return nil }
        return "#PB,\(Int((level * 100).rounded())),\(charging ? 1 : 0)"
    }

    static func progressSuffix(duration: Double, position: Double) -> String {
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0 else { return ",0,0" }
        let seconds = Int(min(duration, 86_400))
        return ",\(seconds),\(Int(min(position, Double(seconds))))"
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

#if os(iOS)
import UIKit
import MediaPlayer
import ImageIO

/// Optional extras for the bonded device. Media changes run on the existing main BLE queue.
final class Screen175CExtras {
    static let shared = Screen175CExtras()
    private struct Track: Equatable {
        let generation: UInt32?
        let title: String
        let artist: String
        let album: String
    }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()
    private var current: Track?
    private var sourceTask: URLSessionDataTask?
    private var debounce: DispatchWorkItem?
    private var generation = UUID()
    private var localID: UInt64?
    private var displayedArtwork = false
    private var lastBattery: String?
    private var ownsBatteryMonitoring = false

    private lazy var placeholder = CoverEncoder.encode(
        rgba: [UInt8](repeating: 0, count: 180 * 180 * 4), width: 180, height: 180)?.data

    func reset() {
        cancel()
        lastBattery = nil
        displayedArtwork = false
        if ownsBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false }
        ownsBatteryMonitoring = false
        BleLink.shared.cover175CStatus = ""
    }

    func setOptions() {
        let link = BleLink.shared
        if !link.extras175CEnabled || !link.verified {
            if displayedArtwork && link.isReady && link.verified, let data = placeholder {
                link.queue175CCover(data)
            } else {
                link.cancel175CCover()
            }
            if lastBattery != nil, link.isReady && link.verified { link.sendOnce("#PB,-1,0") }
            reset()
            return
        }
        tick()
        MusicBridge.shared.refresh(force: true)
    }

    func tick() {
        let link = BleLink.shared
        guard link.extras175CEnabled, link.isReady, link.verified else { return }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
            ownsBatteryMonitoring = true
        }
        let charging = device.batteryState == .charging || device.batteryState == .full
        if let packet = CoverCatalog175C.batteryPacket(level: device.batteryLevel, charging: charging), packet != lastBattery {
            lastBattery = packet
            link.sendOnce(packet)
        }
    }

    func applyLocal(_ item: MPMediaItem?) {
        let link = BleLink.shared
        guard link.extras175CEnabled, link.isReady, link.verified else { return }
        if current != nil { cancel(); showPlaceholder() }
        guard let item else { if localID != nil { localID = nil; showPlaceholder() }; return }
        guard localID != item.persistentID else { return }
        cancel()
        localID = item.persistentID
        showPlaceholder()
        let side = CGFloat(CoverEncoder.targetSize)
        guard let image = item.artwork?.image(at: CGSize(width: side, height: side)),
              let data = CoverEncoder.encode(image: image)?.data else {
            link.cover175CStatus = "这首歌没有可用封面"
            return
        }
        deliver(data)
    }

    func applyHID(_ metadata: AMSMetadata) {
        let link = BleLink.shared
        guard link.extras175CEnabled, link.isReady, link.verified else { return }
        if localID != nil || current.map({ $0.generation != metadata.generation }) == true {
            cancel(); showPlaceholder()
        }
        guard link.cover175COnline else {
            if current != nil { cancel(); showPlaceholder() }
            link.cover175CStatus = "系统媒体模式下，开启联网匹配才会显示封面"
            return
        }
        guard metadata.ready, !metadata.values[0].partial, !metadata.values[1].partial,
              let url = CoverCatalog175C.query(title: metadata.title, artist: metadata.artist) else { return }
        let album = metadata.values[2].partial ? "" : metadata.album
        let track = Track(generation: metadata.generation, title: metadata.title, artist: metadata.artist, album: album)
        guard track != current else { return }
        cancel()
        showPlaceholder()
        current = track
        link.cover175CStatus = "正在匹配封面…"
        let ticket = generation
        let work = DispatchWorkItem { [weak self] in self?.search(url, track: track, ticket: ticket) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func search(_ url: URL, track: Track, ticket: UUID) {
        guard valid(ticket) else { return }
        sourceTask = session.dataTask(with: url) { [weak self] data, response, _ in
            let results = Self.accept(data, response: response, max: 512_000)
                .flatMap { try? JSONDecoder().decode(CoverCatalog175C.Search.self, from: $0) }
            let cover = results.flatMap {
                CoverCatalog175C.artwork(in: $0.results, title: track.title, artist: track.artist, album: track.album)
            }
            DispatchQueue.main.async {
                guard let self = self, self.valid(ticket) else { return }
                if let cover { self.download(cover, ticket: ticket) }
                else { BleLink.shared.cover175CStatus = "没有找到匹配的封面" }
            }
        }
        sourceTask?.resume()
    }

    private func download(_ url: URL, ticket: UUID) {
        sourceTask = session.dataTask(with: url) { [weak self] payload, response, _ in
            var encoded: Data?
            if let finalURL = response?.url, CoverCatalog175C.allowedArtwork(finalURL),
               let data = Self.accept(payload, response: response, max: 2_000_000),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceCreateThumbnailWithTransform: true,
                     kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary) {
                encoded = CoverEncoder.encode(image: UIImage(cgImage: image))?.data
            }
            let result = encoded
            DispatchQueue.main.async {
                guard let self = self, self.valid(ticket) else { return }
                if let result { self.deliver(result) }
                else { BleLink.shared.cover175CStatus = "封面下载失败" }
            }
        }
        sourceTask?.resume()
    }

    private static func accept(_ data: Data?, response: URLResponse?, max: Int) -> Data? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data, data.count <= max else { return nil }
        return data
    }

    private func valid(_ ticket: UUID) -> Bool {
        let link = BleLink.shared
        return ticket == generation && link.extras175CEnabled && link.cover175COnline &&
            link.isReady && link.verified && Settings.shared.musicHID
    }

    private func deliver(_ data: Data) {
        displayedArtwork = true
        BleLink.shared.cover175CStatus = "封面已准备，空闲时发送圆屏"
        BleLink.shared.queue175CCover(data)
    }

    private func cancel() {
        generation = UUID()
        current = nil; localID = nil
        sourceTask?.cancel(); sourceTask = nil
        debounce?.cancel(); debounce = nil
    }

    private func showPlaceholder() {
        guard displayedArtwork, let data = placeholder else { return }
        displayedArtwork = false
        BleLink.shared.queue175CCover(data)
    }
}
#endif
