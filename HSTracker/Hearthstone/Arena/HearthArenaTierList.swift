import Foundation
import Kanna

/// Public, class-specific base ratings, not deck-adjusted draft recommendations.
struct HearthArenaTierList: Codable, Equatable {
    static let sourceURL = URL(string: "https://www.heartharena.com/zh-cn/tierlist")!
    static let classKeys: Set<String> = ["death-knight", "demon-hunter", "druid", "hunter", "mage",
                                         "paladin", "priest", "rogue", "shaman", "warlock", "warrior"]
    let fetchedAt: Date
    let ratings: [String: [String: Double]]

    func score(cardID: String, heroClass: CardClass) -> Double? {
        guard let key = Self.classKey(heroClass) else { return nil }
        // Never substitute another class's rating, including the neutral table.
        return ratings[key]?[cardID]
    }

    static func classKey(_ heroClass: CardClass) -> String? {
        switch heroClass {
        case .deathknight: return "death-knight"
        case .demonhunter: return "demon-hunter"
        default: return classKeys.contains(heroClass.rawValue) ? heroClass.rawValue : nil
        }
    }

    var isValid: Bool {
        Set(ratings.keys) == Self.classKeys && ratings.values.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { id, score in
                Self.validCardID(id) && score.isFinite && (-100...1000).contains(score)
            }
        }
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Self {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8) else { throw HearthArenaError.invalidPage }
        // No scripts, image requests or external entity/network resolution.
        let document = try Kanna.HTML(html: html, encoding: .utf8,
            option: .htmlParseUseLibxml([.RECOVER, .NOERROR, .NOWARNING, .NONET]))
        var ratings: [String: [String: Double]] = [:]
        for section in document.css("section.tierlist") {
            guard let key = section["id"], classKeys.contains(key) else { continue }
            guard ratings[key] == nil else { throw HearthArenaError.invalidPage }
            var cards: [String: Double] = [:]
            for row in section.css("dl.card") {
                guard let path = row.at_css("dt[data-card-image]")?["data-card-image"],
                      let url = URL(string: path),
                      let text = row.at_css("dd.score")?.text else { throw HearthArenaError.invalidPage }
                let id = url.deletingPathExtension().lastPathComponent
                let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "↑↓"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard validCardID(id), let score = Double(number), score.isFinite,
                      (-100...1000).contains(score), cards[id] == nil || cards[id] == score else {
                    throw HearthArenaError.invalidPage
                }
                cards[id] = score
            }
            ratings[key] = cards
        }
        let list = Self(fetchedAt: fetchedAt, ratings: ratings)
        guard list.isValid else { throw HearthArenaError.invalidPage }
        return list
    }

    private static func validCardID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
    }
}

enum HearthArenaError: Error { case invalidPage, invalidResponse, retryLater }

struct HearthArenaRatingsResult {
    let list: HearthArenaTierList
    let isStale: Bool
}

/// One public request for all classes, shared across picks; no account or deck is sent.
actor HearthArenaRatingsService {
    static let shared = HearthArenaRatingsService()
    static let freshLifetime: TimeInterval = 24 * 60 * 60
    static let staleLifetime: TimeInterval = 7 * 24 * 60 * 60
    typealias Fetch = () async throws -> Data

    private let fetch: Fetch
    private let cacheURL: URL?
    private let now: () -> Date
    private var cache: HearthArenaTierList?
    private var pending: Task<HearthArenaTierList, Error>?
    private var lastAttempt: Date?

    init(cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HSTracker/heartharena-tierlist-v1.json"),
         now: @escaping () -> Date = Date.init, fetch: @escaping Fetch = HearthArenaRatingsService.download) {
        self.cacheURL = cacheURL
        self.now = now
        self.fetch = fetch
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 4 * 1024 * 1024,
           let list = try? JSONDecoder().decode(HearthArenaTierList.self, from: data), list.isValid {
            cache = list
        }
    }

    func ratings() async throws -> HearthArenaRatingsResult {
        if let cache, isUsable(cache, lifetime: Self.freshLifetime) {
            return HearthArenaRatingsResult(list: cache, isStale: false)
        }
        if pending == nil {
            if let lastAttempt, now().timeIntervalSince(lastAttempt) < 60 {
                return try staleResult(or: HearthArenaError.retryLater)
            }
            lastAttempt = now()
            let fetch = self.fetch
            let fetchedAt = now()
            pending = Task { try HearthArenaTierList.parse(await fetch(), fetchedAt: fetchedAt) }
        }
        guard let request = pending else { throw HearthArenaError.retryLater }
        do {
            let list = try await request.value
            pending = nil
            cache = list
            if let cacheURL, let data = try? JSONEncoder().encode(list) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            return HearthArenaRatingsResult(list: list, isStale: false)
        } catch {
            pending = nil
            return try staleResult(or: error)
        }
    }

    private func isUsable(_ list: HearthArenaTierList, lifetime: TimeInterval) -> Bool {
        let age = now().timeIntervalSince(list.fetchedAt)
        return age >= 0 && age < lifetime
    }

    private func staleResult(or error: Error) throws -> HearthArenaRatingsResult {
        guard let cache, isUsable(cache, lifetime: Self.staleLifetime) else { throw error }
        return HearthArenaRatingsResult(list: cache, isStale: true)
    }

    static func download() async throws -> Data {
        var request = URLRequest(url: HearthArenaTierList.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            session.dataTask(with: request) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error { continuation.resume(throwing: error); return }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https",
                      ["www.heartharena.com", "heartharena.com"].contains(response.url?.host ?? ""),
                      response.mimeType == "text/html", let data, data.count <= 4 * 1024 * 1024 else {
                    continuation.resume(throwing: HearthArenaError.invalidResponse); return
                }
                continuation.resume(returning: data)
            }.resume()
        }
    }
}
