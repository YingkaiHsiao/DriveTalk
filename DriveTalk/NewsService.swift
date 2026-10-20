import Foundation

enum NewsCategory: String, CaseIterable, Identifiable, Codable {
    case technology = "科技"
    case business = "商業"
    case world = "國際"
    case asia = "亞洲"
    case science = "科學環境"

    var id: String { rawValue }

    /// Public BBC News RSS feeds (headline + short summary + link).
    var feedURL: URL {
        let path: String
        switch self {
        case .technology: path = "technology"
        case .business: path = "business"
        case .world: path = "world"
        case .asia: path = "world/asia"
        case .science: path = "science_and_environment"
        }
        return URL(string: "https://feeds.bbci.co.uk/news/\(path)/rss.xml")!
    }
}

struct NewsItem: Identifiable, Codable, Hashable {
    var id: String { link }
    let title: String
    let summary: String
    let link: String
    let pubDate: Date?
}

/// A learner-level article the AI wrote from a real headline + summary.
struct NewsArticle: Codable, Hashable {
    var title: String
    var paragraphs: [String]
    var vocabulary: [WordInfo]
    var questions: [String]
    var sourceTitle: String = ""
    var link: String = ""
    var level: String = ""

    var fullText: String { ([title] + paragraphs).joined(separator: "\n\n") }

    enum CodingKeys: String, CodingKey { case title, paragraphs, vocabulary, questions, sourceTitle, link, level }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        paragraphs = (try? c.decode([String].self, forKey: .paragraphs)) ?? []
        if paragraphs.isEmpty, let body = try? c.decode(String.self, forKey: .paragraphs) {
            paragraphs = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        vocabulary = (try? c.decode([WordInfo].self, forKey: .vocabulary)) ?? []
        questions = (try? c.decode([String].self, forKey: .questions)) ?? []
        sourceTitle = (try? c.decode(String.self, forKey: .sourceTitle)) ?? ""
        link = (try? c.decode(String.self, forKey: .link)) ?? ""
        level = (try? c.decode(String.self, forKey: .level)) ?? ""
    }
}

// MARK: - RSS

enum RSSFetcher {
    static func fetch(_ category: NewsCategory) async throws -> [NewsItem] {
        var req = URLRequest(url: category.feedURL)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "DriveTalk", code: 2, userInfo: [NSLocalizedDescriptionKey: "新聞來源暫時無法連線"])
        }
        let parser = RSSParser()
        return parser.parse(data)
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsItem] = []
    private var inItem = false
    private var current = ""
    private var title = "", summary = "", link = "", date = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parse(_ data: Data) -> [NewsItem] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            inItem = true
            title = ""; summary = ""; link = ""; date = ""
        }
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        current += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch elementName {
        case "title": title = text
        case "description": summary = text
        case "link": link = text
        case "pubDate": date = text
        case "item":
            inItem = false
            if !title.isEmpty, !link.isEmpty {
                items.append(NewsItem(title: title, summary: summary, link: link,
                                      pubDate: Self.dateFormatter.date(from: date)))
            }
        default: break
        }
        current = ""
    }
}

// MARK: - Store (caches generated articles so each one costs tokens only once)

@MainActor
final class NewsStore: ObservableObject {
    static let shared = NewsStore()

    @Published private(set) var items: [NewsItem] = []
    @Published private(set) var loading = false
    @Published var errorText: String?
    @Published private(set) var loadedCategory: NewsCategory?

    private var cache: [String: NewsArticle] = [:]
    private var cacheOrder: [String] = []

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("news_cache.json")
    }

    private struct CacheFile: Codable { var order: [String]; var articles: [String: NewsArticle] }

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let file = try? JSONDecoder().decode(CacheFile.self, from: data) {
            cache = file.articles
            cacheOrder = file.order
        }
    }

    func refresh(_ category: NewsCategory) async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            items = try await RSSFetcher.fetch(category)
            loadedCategory = category
        } catch {
            errorText = error.localizedDescription
        }
    }

    func cachedArticle(for item: NewsItem, level: EnglishLevel) -> NewsArticle? {
        cache[cacheKey(item, level)]
    }

    func article(for item: NewsItem, settings: SettingsStore) async throws -> NewsArticle {
        let key = cacheKey(item, settings.level)
        if let a = cache[key] { return a }
        var article = try await StudyService(settings: settings).newsArticle(from: item, level: settings.level)
        article.link = item.link
        article.sourceTitle = item.title
        article.level = settings.level.rawValue
        cache[key] = article
        cacheOrder.append(key)
        while cacheOrder.count > 60 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        save()
        return article
    }

    /// Latest item not yet generated at this level (for hands-free "next news").
    func nextItem(after used: Set<String>) -> NewsItem? {
        items.first { !used.contains($0.link) } ?? items.first
    }

    private func cacheKey(_ item: NewsItem, _ level: EnglishLevel) -> String { "\(level.rawValue)|\(item.link)" }

    private func save() {
        if let data = try? JSONEncoder().encode(CacheFile(order: cacheOrder, articles: cache)) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
