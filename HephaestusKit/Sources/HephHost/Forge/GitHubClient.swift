#if os(macOS)
import Foundation
import HephCore
import Synchronization

/// GitHub REST client of docs/forge/pipeline.md ("GitHub API"); also used by UpdateService (docs/forge/update.md).
///
/// Copies of a client share its token and its rate limit: a token read again after a `401` and the time before which
/// no request is sent stay with every copy.
public struct GitHubClient: Sendable {
    /// `owner/name`.
    let repository: String
    private let shared: GitHubClientState

    public init(repository: String, token: String?) {
        self.repository = repository
        shared = GitHubClientState(token: token)
    }

    /// `releases/latest`; nil on 404.
    public func latestRelease() async throws -> GitHubRelease? {
        try await get("releases/latest", as: GitHubRelease.self, notFoundIsNil: true)
    }

    /// `releases/tags/<tag>`; nil on 404.
    public func release(tag: String) async throws -> GitHubRelease? {
        try await get("releases/tags/\(tag)", as: GitHubRelease.self, notFoundIsNil: true)
    }

    /// `actions/runs?head_sha=<sha>`: the `workflow_runs` of the response.
    public func runs(headSHA: String) async throws -> [GitHubRun] {
        let page = try await get("actions/runs?head_sha=\(headSHA)", as: GitHubRunsPage.self)
        return page?.workflowRuns ?? []
    }

    /// `actions/runs/<run id>`.
    public func run(id: Int) async throws -> GitHubRun {
        guard let run = try await get("actions/runs/\(id)", as: GitHubRun.self) else {
            throw GitHubError.http(status: 404, path: "actions/runs/\(id)")
        }
        return run
    }

    /// `actions/runs/<run id>/jobs?filter=latest`: the `jobs` of the response.
    public func jobs(runID: Int) async throws -> [GitHubJob] {
        let page = try await get("actions/runs/\(runID)/jobs?filter=latest", as: GitHubJobsPage.self)
        return page?.jobs ?? []
    }

    /// `actions/jobs/<job id>/logs`: the `302` response's `Location`, fetched without the `Authorization` header; the
    /// body as UTF-8 text.
    public func jobLog(jobID: Int) async throws -> String {
        let path = "actions/jobs/\(jobID)/logs"
        let (data, response) = try await send(path: path, followRedirects: false)
        if (200..<300).contains(response.statusCode) {
            return String(decoding: data, as: UTF8.self)
        }
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location)
        else {
            throw GitHubError.http(status: response.statusCode, path: path)
        }
        var request = Self.request(url, token: nil)
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (logData, logResponse) = try await Self.session.data(for: request)
        guard let http = logResponse as? HTTPURLResponse else {
            throw GitHubError.http(status: 0, path: path)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(status: http.statusCode, path: path)
        }
        return String(decoding: logData, as: UTF8.self)
    }

    /// `gh auth token` (Git operations); nil when unavailable: no `gh`, a non-zero exit, an empty output or the 10 s
    /// timeout.
    public static func readToken() async -> String? {
        let environment = await LoginEnvironment.shared.environment()
        guard let gh = ForgeGit.locate("gh", environment: environment) else { return nil }
        let configuration = ChildProcessConfiguration(executable: gh, arguments: ["auth", "token"],
                                                      workingDirectory: NSHomeDirectory(), environment: environment)
        do {
            let output = try await ChildProcess.capture(configuration, timeout: .seconds(10))
            guard !output.timedOut, output.termination == .exited(0) else { return nil }
            let token = String(decoding: output.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        } catch {
            return nil
        }
    }

    // MARK: - Internal

    /// The time before which no request is sent; nil when not rate limited.
    var rateLimitedUntil: Date? {
        shared.rateLimitedUntil
    }

    // MARK: - Requests

    /// The ephemeral session of the client: no cookies, no cache; requests time out after 30 s.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// `GET https://api.github.com/repos/<repository>/<path>`, decoded as `T`; nil on 404 when `notFoundIsNil`.
    private func get<T: Decodable>(_ path: String, as type: T.Type, notFoundIsNil: Bool = false) async throws -> T? {
        let (data, response) = try await send(path: path, followRedirects: true)
        if response.statusCode == 404, notFoundIsNil {
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.http(status: response.statusCode, path: path)
        }
        return try Self.decode(type, from: data, path: path)
    }

    /// Sends `GET https://api.github.com/repos/<repository>/<path>` with the current token; a `401` is retried once
    /// with the token read again (or without one). Rate limits are recorded and thrown.
    private func send(path: String, followRedirects: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = Self.repositoryURL(repository, path) else {
            throw GitHubError.http(status: 0, path: path)
        }
        if let until = shared.rateLimitedUntil, until > Date() {
            throw GitHubError.rateLimited(until: until)
        }
        var (data, response) = try await Self.perform(Self.request(url, token: shared.token),
                                                      followRedirects: followRedirects, path: path)
        if response.statusCode == 401 {
            let token = await Self.readToken()
            shared.token = token
            (data, response) = try await Self.perform(Self.request(url, token: token),
                                                      followRedirects: followRedirects, path: path)
        }
        if let until = Self.rateLimit(of: response) {
            shared.rateLimitedUntil = until
            throw GitHubError.rateLimited(until: until)
        }
        return (data, response)
    }

    private static func perform(_ request: URLRequest, followRedirects: Bool,
                                path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request,
                                                      delegate: followRedirects ? nil : RedirectBlocker())
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(status: 0, path: path)
        }
        return (data, http)
    }

    /// The headers of every request: Accept, the API version, the User-Agent and the token when one is known.
    private static func request(_ url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// `Hephaestus/<CFBundleShortVersionString> (<CFBundleVersion>)`.
    private static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Hephaestus/\(version) (\(build))"
    }()

    private static func repositoryURL(_ repository: String, _ path: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/\(path)")
    }

    /// `403` or `429` with `x-ratelimit-remaining: 0` or a `retry-after` header: limited until now + `retry-after`
    /// seconds, else until `x-ratelimit-reset` (epoch seconds).
    private static func rateLimit(of response: HTTPURLResponse) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard remaining == "0" || retryAfter != nil else { return nil }
        if let retryAfter {
            return Date().addingTimeInterval(retryAfter)
        }
        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap({ Double($0) }) {
            return Date(timeIntervalSince1970: reset)
        }
        return Date().addingTimeInterval(60)
    }

    /// GitHub's snake_case JSON, ISO 8601 dates without fractional seconds.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// The token and the rate limit shared by the copies of a client, behind a lock.
private final class GitHubClientState: Sendable {
    private struct Values {
        var token: String?
        var rateLimitedUntil: Date?
    }

    private let values: Mutex<Values>

    init(token: String?) {
        values = Mutex(Values(token: token))
    }

    var token: String? {
        get { values.withLock { $0.token } }
        set { values.withLock { $0.token = newValue } }
    }

    var rateLimitedUntil: Date? {
        get { values.withLock { $0.rateLimitedUntil } }
        set { values.withLock { $0.rateLimitedUntil = newValue } }
    }
}

/// Refuses redirects, so that the `Location` of a `302` can be fetched without the `Authorization` header.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public struct GitHubRelease: Sendable, Decodable {
    public var tagName: String
    public var htmlURL: String
    public var publishedAt: Date
    public var assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        htmlURL = try container.decode(String.self, forKey: .htmlURL)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        assets = try container.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }
}

public struct GitHubAsset: Sendable, Decodable {
    public var name: String
    public var browserDownloadURL: String
    public var size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

public struct GitHubRun: Sendable, Decodable {
    public var id: Int
    public var runNumber: Int
    public var status: String
    public var conclusion: String?
    public var htmlURL: String
    public var headSHA: String
    /// `head_branch`, the branch of the push (the run lookup keeps the runs of the configured branch).
    public var headBranch: String?
    public var event: String
    public var path: String

    enum CodingKeys: String, CodingKey {
        case id
        case runNumber = "run_number"
        case status
        case conclusion
        case htmlURL = "html_url"
        case headSHA = "head_sha"
        case headBranch = "head_branch"
        case event
        case path
    }
}

public struct GitHubJob: Sendable, Decodable {
    public var id: Int
    public var name: String
    public var conclusion: String?
    public var htmlURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case conclusion
        case htmlURL = "html_url"
    }
}

public enum GitHubError: Error, Sendable {
    case rateLimited(until: Date)
    case http(status: Int, path: String)
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rateLimited(let until):
            return "GitHub API rate limit reached; next request at \(Self.timeFormatter.string(from: until))."
        case .http(let status, let path):
            return "GitHub API \(path): HTTP \(status)."
        }
    }

    /// `HH:mm`, local time.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// `{"workflow_runs": [...]}`.
private struct GitHubRunsPage: Decodable {
    var workflowRuns: [GitHubRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// `{"jobs": [...]}`.
private struct GitHubJobsPage: Decodable {
    var jobs: [GitHubJob]
}
#endif
