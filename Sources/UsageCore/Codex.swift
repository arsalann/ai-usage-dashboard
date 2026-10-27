import Foundation

/// Credentials borrowed (read-only) from the Codex CLI's `~/.codex/auth.json`.
///
/// Only ChatGPT-plan logins carry usage limits; API-key logins have no 5-hour /
/// weekly windows, so they parse to nil. The app never refreshes this token: Codex
/// rotates its refresh token on use, so refreshing here would log the CLI out.
public struct CodexCredentials: Equatable {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
    }

    public static func parse(from data: Data) -> CodexCredentials? {
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = file.tokens?.accessToken, !token.isEmpty else { return nil }
        return CodexCredentials(accessToken: token, accountID: file.tokens?.accountID)
    }

    /// `$CODEX_HOME/auth.json`, defaulting to `~/.codex/auth.json` like the CLI.
    public static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    private struct AuthFile: Decodable {
        let tokens: Tokens?
    }

    private struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

extension UsageSnapshot {
    /// Parses GET https://chatgpt.com/backend-api/wham/usage: `primary_window` is the
    /// 5-hour session, `secondary_window` the weekly limit.
    public static func parseCodex(from data: Data) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(CodexResponse.self, from: data)
        return UsageSnapshot(
            session: response.rateLimit?.primaryWindow.map { $0.asWindow() },
            weekly: response.rateLimit?.secondaryWindow.map { $0.asWindow() }
        )
    }
}

private struct CodexResponse: Decodable {
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double?
    /// Unix seconds.
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    func asWindow() -> UsageWindow {
        UsageWindow(utilization: usedPercent ?? 0,
                    resetsAt: resetAt.map { Date(timeIntervalSince1970: $0) })
    }
}

/// Networking-only client for ChatGPT's Codex usage endpoint (the same one the
/// Codex CLI's `/status` uses).
public final class CodexUsageClient {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    public func fetchUsage(credentials: CodexCredentials) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.badResponse }
        switch http.statusCode {
        case 200:
            return try UsageSnapshot.parseCodex(from: data)
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageClientError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageClientError.httpError(http.statusCode)
        }
    }
}
