import Foundation
import os

actor InnerTubeAPI {
    private let session: URLSession
    private let baseURL: URL
    // swiftlint:disable:previous force_unwrapping
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let userDefaults: UserDefaults

    var locale: YouTubeLocale
    /// Anonymous YouTube Music session token. Initialized with a known-good default
    /// (same approach as InnerTune) so the very first request always has a valid
    /// token. Hydrated from `UserDefaults` on init; refreshed lazily via
    /// `ensureFreshVisitorData()` from `music.youtube.com/sw.js_data`.
    var visitorData: String = InnerTubeAPI.defaultVisitorData
    private(set) var cookie: String?
    private var authenticationGeneration: UInt64 = 0
    private var playerSessionGeneration: UInt64 = 0

    private var sessionCookies: [HTTPCookie] = []
    private var hasInitializedSession = false
    private var sessionInitTime: Date?
    private var playerVisitorSource: PlaybackDiagnostics.VisitorSource = .generated

    // Visitor data TTL tracking for browse/search freshness
    private var visitorDataTimestamp: Date?
    private let visitorDataTTL: TimeInterval = 3600  // 1 hour in-memory refresh interval

    // Persistence (polish-B2)
    private static let visitorDataPersistenceKey = "innerTube.visitorData.lastGood"
    private static let visitorDataPersistenceAtKey = "innerTube.visitorData.lastGoodAt"
    private static let visitorDataPersistenceTTL: TimeInterval = 24 * 3600  // 24 hours

    /// Generates a fresh anonymous visitorData token. Ensures first requests
    /// always have a valid token, and degraded-state fallback uses fresh timestamps
    /// rather than a stale hardcoded value.
    private static var defaultVisitorData: String { VisitorDataGenerator.generate() }

    // Bounded retry / degraded-state tracking (polish-B2)
    private var refreshFailureCount: Int = 0
    private(set) var degradedVisitorState: Bool = false

    // In-flight deduplication for visitorData refresh (prevents actor-reentrancy races)
    private var visitorDataRefreshTask: Task<Void, Error>?

    // ND-2: In-flight request deduplication
    private var inFlightBrowse: [String: Task<Data, Error>] = [:]
    private var inFlightSearch: [String: Task<Data, Error>] = [:]

    /// Anonymous WEB_REMIX credentials supplied by YouTube Music's public
    /// homepage. This is a non-secret web client bootstrap, not the user's
    /// YouTube Data API key. Keep it only in actor memory for at most 30 min.
    private var publicWebBootstrap: (value: PublicMusicWebBootstrap, fetchedAt: Date)?


    func setLocale(_ newLocale: YouTubeLocale) {
        self.locale = newLocale
        applyLocaleCookies(newLocale)
    }

    /// Sets PREF cookie on `.youtube.com` so YouTube Music respects our region/language.
    /// YouTube prioritizes: PREF cookie > body gl/hl > Accept-Language > IP geolocation.
    private nonisolated func applyLocaleCookies(_ locale: YouTubeLocale) {
        let prefValue = "hl=\(locale.hl)&gl=\(locale.gl)&tz=Asia/Ho_Chi_Minh"
        for domain in [".youtube.com", ".music.youtube.com"] {
            if let cookie = HTTPCookie(properties: [
                .name: "PREF", .value: prefValue,
                .domain: domain, .path: "/",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    func setCookie(_ cookieString: String?) {
        guard cookie != cookieString else { return }
        self.cookie = cookieString
        authenticationGeneration &+= 1
        visitorDataRefreshTask?.cancel()
        visitorDataRefreshTask = nil
        visitorData = Self.defaultVisitorData
        visitorDataTimestamp = nil
        playerVisitorSource = .generated
        refreshFailureCount = 0
        setDegraded(false)
        userDefaults.removeObject(forKey: Self.visitorDataPersistenceKey)
        userDefaults.removeObject(forKey: Self.visitorDataPersistenceAtKey)
        PlaybackDiagnostics.shared.record(.init(phase: .authChanged, hasAuth: cookieString?.isEmpty == false))
        resetSession()
        for stored in HTTPCookieStorage.shared.cookies ?? []
        where YouTubeAuthManager.isYouTubeDomain(stored.domain)
            && YouTubeAuthManager.authCookieNames.contains(stored.name) {
            HTTPCookieStorage.shared.deleteCookie(stored)
        }
    }

    func playerSessionContext() -> PlayerSessionContext {
        // DI supplies only unexpired YouTube cookies from the Keychain. A
        // Drive OAuth account or a visitor-only cookie is not a YouTube login.
        let names = Set((cookie ?? "").split(separator: ";").compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespaces)
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return String(pair[0])
        })
        return PlayerSessionContext(
            isAuthenticated: names.isSuperset(of: ["SAPISID", "SID"]),
            generation: authenticationGeneration
        )
    }

    init(locale: YouTubeLocale = .default, session: URLSession? = nil,
         userDefaults: UserDefaults = .standard, cookie: String? = nil) {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/") else {
            fatalError("Invalid hardcoded base URL")
        }
        self.baseURL = url
        self.locale = locale
        self.userDefaults = userDefaults
        self.cookie = cookie

        // Set PREF cookie immediately so the very first request uses correct region.
        // YouTube prioritizes: PREF cookie > body gl/hl > Accept-Language > IP.
        // Inline rather than calling applyLocaleCookies() because self isn't fully
        // initialized yet (actor stored properties requirement).
        let prefValue = "hl=\(locale.hl)&gl=\(locale.gl)&tz=Asia/Ho_Chi_Minh"
        for domain in [".youtube.com", ".music.youtube.com"] {
            if let cookie = HTTPCookie(properties: [
                .name: "PREF", .value: prefValue,
                .domain: domain, .path: "/",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(365 * 24 * 3600),
            ]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
            config.httpCookieAcceptPolicy = .always
            config.httpCookieStorage = .shared
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.urlCache = URLCache(memoryCapacity: 10_485_760, diskCapacity: 52_428_800)
            self.session = URLSession(configuration: config)
        }

        self.decoder = JSONDecoder()

        self.encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        // Hydrate last-good visitorData from UserDefaults (polish-B2). The 1-hour
        // in-memory `visitorDataTimestamp` is intentionally left nil so the first
        // request still triggers a refresh attempt — persistence is the cold-start
        // safety net, not the freshness mechanism. Only network-fetched tokens are
        // persisted; the hardcoded default is never written to UserDefaults.
        if let stored = userDefaults.string(forKey: Self.visitorDataPersistenceKey),
            !stored.isEmpty
        {
            let storedAt = userDefaults.double(forKey: Self.visitorDataPersistenceAtKey)
            if storedAt > 0 {
                let age = Date().timeIntervalSince1970 - storedAt
                if age >= 0 && age < Self.visitorDataPersistenceTTL {
                    self.visitorData = stored
                    self.playerVisitorSource = .persisted
                }
            }
        }
    }

    private func buildRequest(
        endpoint: String,
        client: YouTubeClient,
        body: some Encodable,
        setLogin: Bool = false,
        customURL: URL? = nil
    ) throws -> URLRequest {
        guard !client.apiKey.isEmpty else { throw InnerTubeError.sourceNotConfigured }
        let url = customURL ?? baseURL.appendingPathComponent(endpoint)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw InnerTubeError.invalidURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: client.apiKey))
        queryItems.append(URLQueryItem(name: "prettyPrint", value: "false"))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw InnerTubeError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        // polish-B3: bypass URLCache for InnerTube POSTs. Browse/search/next/etc.
        // returned identical bytes across launches when the URLCache satisfied a
        // request without hitting the network, masking real backend updates.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "x-origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        // polish-B2: omit header entirely when we have no fresh/persisted token or
        // are in degraded state. Sending the previous URL-encoded literal here
        // produced a malformed token that the server silently downgraded.
        let visitorForHeader = effectiveVisitorData()
        if !visitorForHeader.isEmpty {
            request.setValue(visitorForHeader, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.setValue("\(locale.hl),en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        if let referer = client.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        if setLogin, let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let authorization = YouTubeAuthManager.sessionAuthorizationHeader(
                cookieHeader: cookie, origin: "https://music.youtube.com") {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
        }

        request.httpBody = try encoder.encode(body)
        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return try decoder.decode(T.self, from: data)
    }


    // MARK: - Anonymous YouTube Music web search/browse

    private func resolvedPublicWebClient(
        for requestedClient: YouTubeClient
    ) async throws -> YouTubeClient {
        guard requestedClient.clientName == "WEB_REMIX",
              requestedClient.apiKey.isEmpty else {
            return requestedClient
        }

        let bootstrap: PublicMusicWebBootstrap
        if let cached = publicWebBootstrap,
           Date().timeIntervalSince(cached.fetchedAt) < 30 * 60 {
            bootstrap = cached.value
        } else {
            guard let url = URL(string: "https://music.youtube.com/") else {
                throw InnerTubeError.searchBootstrapUnavailable
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue("\(locale.hl),en;q=0.8", forHTTPHeaderField: "Accept-Language")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw InnerTubeError.searchBootstrapUnavailable
            }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.url?.scheme == "https",
                  response.url?.host == "music.youtube.com",
                  data.count > 0, data.count <= 4 * 1024 * 1024,
                  let html = String(data: data, encoding: .utf8),
                  let parsed = PublicMusicWebBootstrap.parse(html)
            else {
                throw InnerTubeError.searchBootstrapUnavailable
            }
            bootstrap = parsed
            publicWebBootstrap = (value: parsed, fetchedAt: Date())
        }

        // Do not leak the temporary web-client key to UI logs, persisted
        // storage, crash reports, or the app's own YouTube Data API setting.
        return YouTubeClient(
            clientName: "WEB_REMIX",
            clientId: "67",
            clientVersion: bootstrap.clientVersion,
            apiKey: bootstrap.apiKey,
            userAgent: YouTubeClient.userAgentWeb,
            referer: YouTubeClient.refererYouTubeMusic,
            platform: "DESKTOP"
        )
    }

    // MARK: - API Methods

    func search(
        client: YouTubeClient = .webRemix,
        query: String? = nil,
        params: String? = nil,
        continuation: String? = nil
    ) async throws -> Data {
        // Continuation requests have unique tokens — no dedup needed
        guard continuation == nil else {
            return try await executeSearch(
                client: client, query: query, params: params, continuation: continuation)
        }
        let key = "\(query ?? "")|\(params ?? "")"
        if let existing = inFlightSearch[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            defer { inFlightSearch.removeValue(forKey: key) }
            return try await executeSearch(
                client: client, query: query, params: params, continuation: nil)
        }
        inFlightSearch[key] = task
        return try await task.value
    }

    private func executeSearch(
        client: YouTubeClient,
        query: String?,
        params: String?,
        continuation: String?
    ) async throws -> Data {
        // Use YouTube Music's own public web-client configuration for anonymous
        // search when this installation has no embedded InnerTube key.
        // The configuration is fetched over HTTPS at runtime, not shipped in
        // the app or persisted as a user credential.
        await ensureFreshVisitorData()
        let activeClient = try await resolvedPublicWebClient(for: client)

        let body = SearchBody(
            context: activeClient.toContext(locale: locale, visitorData: effectiveVisitorData()),
            query: query,
            params: params,
            continuation: continuation
        )
        var request = try buildRequest(endpoint: "search", client: activeClient, body: body)

        if let continuation, let requestURL = request.url,
            var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "continuation", value: continuation))
            items.append(URLQueryItem(name: "ctoken", value: continuation))
            components.queryItems = items
            request.url = components.url
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    func player(
        client: YouTubeClient = .ios,
        videoId: String,
        playlistId: String? = nil
    ) async throws -> Data {
        let sessionContext = playerSessionContext()
        let diagnosticClient: PlaybackDiagnostics.Client = client.clientName == "IOS" ? .ios
            : client.clientName == "WEB_REMIX" ? .webRemix : .other
        let request: URLRequest
        do {
            // The public web-client bootstrap is already used for anonymous
            // search. Apply the same runtime configuration to the fallback
            // player; a missing embedded key must not prevent an attempt to
            // play public tracks when YouTube cookies are absent.
            let activeClient: YouTubeClient
            if client.clientName == "WEB_REMIX" {
                await ensureFreshVisitorData()
                guard !Task.isCancelled, sessionContext == playerSessionContext() else {
                    throw CancellationError()
                }
                activeClient = try await resolvedPublicWebClient(for: client)
            } else {
                activeClient = client
            }
            guard !Task.isCancelled, sessionContext == playerSessionContext() else {
                throw CancellationError()
            }
            let body = PlayerBody(
                context: activeClient.toContext(locale: locale, visitorData: effectiveVisitorData()),
                videoId: videoId,
                playlistId: playlistId
            )
            var playerRequest = try buildRequest(
                endpoint: "player", client: activeClient, body: body,
                setLogin: sessionContext.isAuthenticated
            )
            if !sessionContext.isAuthenticated { playerRequest.httpShouldHandleCookies = false }
            request = playerRequest
        } catch {
            let reason: PlaybackDiagnostics.Reason
            if error is CancellationError { reason = .cancelled }
            else if case InnerTubeError.sourceNotConfigured = error { reason = .sourceNotConfigured }
            else { reason = .other }
            PlaybackDiagnostics.shared.record(.init(phase: .playerResponse, client: diagnosticClient,
                videoID: videoId, reason: reason, hasAuth: sessionContext.isAuthenticated))
            throw error
        }
        return try await executePlayerRequest(request, videoID: videoId, client: diagnosticClient,
            hasAuth: sessionContext.isAuthenticated, visitorSource: effectiveVisitorSource)
    }

    /// Observe the same response used by playback without retaining request or response secrets.
    private func executePlayerRequest(_ request: URLRequest, videoID: String,
        client: PlaybackDiagnostics.Client, hasAuth: Bool,
        visitorSource: PlaybackDiagnostics.VisitorSource?) async throws -> Data {
        let age = sessionInitTime.map { Int(max(0, Date().timeIntervalSince($0))) }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            PlaybackDiagnostics.shared.record(.init(phase: .playerResponse, client: client,
                videoID: videoID,
                reason: error is CancellationError || (error as NSError).code == NSURLErrorCancelled ? .cancelled : .network,
                hasAuth: hasAuth, sessionAgeSeconds: age,
                visitorSource: visitorSource, transportErrorCode: (error as NSError).code))
            throw error
        }
        let (data, response) = result
        let code = (response as? HTTPURLResponse)?.statusCode
        PlaybackDiagnostics.shared.recordPlayerResponse(data, httpStatus: code, client: client,
            videoID: videoID, hasAuth: hasAuth, sessionAgeSeconds: age, visitorSource: visitorSource)
        guard let code, (200...299).contains(code) else {
            throw InnerTubeError.httpError(statusCode: code ?? -1)
        }
        return data
    }

    func browse(
        client: YouTubeClient = .webRemix,
        browseId: String? = nil,
        params: String? = nil,
        continuation: String? = nil
    ) async throws -> Data {
        // Continuation requests have unique tokens — no dedup needed
        guard continuation == nil else {
            return try await executeBrowse(
                client: client, browseId: browseId, params: params, continuation: continuation)
        }
        let key = "\(browseId ?? "")|\(params ?? "")"
        if let existing = inFlightBrowse[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            defer { inFlightBrowse.removeValue(forKey: key) }
            return try await executeBrowse(
                client: client, browseId: browseId, params: params, continuation: nil)
        }
        inFlightBrowse[key] = task
        return try await task.value
    }

    private func executeBrowse(
        client: YouTubeClient,
        browseId: String?,
        params: String?,
        continuation: String?
    ) async throws -> Data {
        await ensureFreshVisitorData()
        let activeClient = try await resolvedPublicWebClient(for: client)
        let body = BrowseBody(
            context: activeClient.toContext(locale: locale, visitorData: effectiveVisitorData()),
            browseId: browseId,
            params: params,
            continuation: continuation
        )
        var request = try buildRequest(endpoint: "browse", client: activeClient, body: body)

        if let continuation, let requestURL = request.url,
            var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "continuation", value: continuation))
            items.append(URLQueryItem(name: "ctoken", value: continuation))
            items.append(URLQueryItem(name: "type", value: "next"))
            components.queryItems = items
            request.url = components.url
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    func next(
        client: YouTubeClient = .webRemix,
        videoId: String?,
        playlistId: String?,
        playlistSetVideoId: String? = nil,
        index: Int? = nil,
        params: String? = nil,
        continuation: String? = nil
    ) async throws -> Data {
        // polish-B2: gate every InnerTube call on visitorData freshness, not just
        // browse/search. Pre-fix, `next` could send the stale literal until a
        // browse warmed it.
        await ensureFreshVisitorData()
        let body = NextBody(
            context: client.toContext(locale: locale, visitorData: effectiveVisitorData()),
            videoId: videoId,
            playlistId: playlistId,
            playlistSetVideoId: playlistSetVideoId,
            index: index,
            params: params,
            continuation: continuation
        )
        let request = try buildRequest(endpoint: "next", client: client, body: body, setLogin: true)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    func getSearchSuggestions(
        client: YouTubeClient = .webRemix,
        input: String
    ) async throws -> Data {
        await ensureFreshVisitorData()
        let activeClient = try await resolvedPublicWebClient(for: client)
        let body = GetSearchSuggestionsBody(
            context: activeClient.toContext(locale: locale, visitorData: effectiveVisitorData()),
            input: input
        )
        let request = try buildRequest(
            endpoint: "music/get_search_suggestions", client: activeClient, body: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    func getQueue(
        client: YouTubeClient = .webRemix,
        videoIds: [String]? = nil,
        playlistId: String? = nil
    ) async throws -> Data {
        await ensureFreshVisitorData()
        let body = GetQueueBody(
            context: client.toContext(locale: locale, visitorData: effectiveVisitorData()),
            videoIds: videoIds,
            playlistId: playlistId
        )
        let request = try buildRequest(endpoint: "music/get_queue", client: client, body: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InnerTubeError.httpError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    // MARK: - Visitor Data Refresh for Browse/Search

    /// Fetches a fresh visitorData token from YouTube Music's service worker data
    /// endpoint (`sw.js_data`), the same approach used by InnerTune. Falls back to
    /// visitor_id API, then HTML scraping, then local protobuf generation.
    private func refreshVisitorData() async {
        Log.innerTube.info("Refreshing visitorData from music.youtube.com/sw.js_data")
        let generation = authenticationGeneration

        // Primary: fetch from sw.js_data (same as InnerTune)
        let swToken = try? await fetchVisitorDataFromSwJsData()
        guard !Task.isCancelled, generation == authenticationGeneration else { return }
        if let token = swToken {
            applyVisitorData(token)
            return
        }

        // Secondary: YouTube visitor_id API endpoint (NewPipe approach)
        Log.innerTube.info("sw.js_data failed, trying visitor_id API")
        let apiToken = await fetchVisitorDataFromVisitorIdAPI()
        guard !Task.isCancelled, generation == authenticationGeneration else { return }
        if let token = apiToken {
            applyVisitorData(token)
            return
        }

        // Tertiary: scrape music.youtube.com HTML
        Log.innerTube.info("visitor_id API failed, falling back to HTML scrape")
        let htmlToken = try? await fetchVisitorDataFromMusicHTML()
        guard !Task.isCancelled, generation == authenticationGeneration else { return }
        if let token = htmlToken {
            applyVisitorData(token)
            return
        }

        // Ultimate fallback: locally generated protobuf token (always fresh timestamp)
        Log.innerTube.warning("All network sources failed, using locally generated visitorData")
        let generated = VisitorDataGenerator.generate()
        self.visitorData = generated
        self.playerVisitorSource = .generated
        refreshFailureCount += 1
        if refreshFailureCount >= 2 {
            setDegraded(true)
        }
    }

    /// Applies a newly fetched visitorData token: updates in-memory state,
    /// timestamps, and persists to UserDefaults.
    private func applyVisitorData(_ token: String) {
        self.visitorData = token
        self.playerVisitorSource = .musicRefresh
        self.visitorDataTimestamp = Date()
        persistVisitorData(token)
        refreshFailureCount = 0
        setDegraded(false)
        Log.innerTube.debug(
            "Refreshed visitorData: \(token.prefix(30), privacy: .public)...")
    }

    /// Validates that a candidate string looks like a real visitorData token.
    /// The protobuf's first visitor-ID byte changes the Base64 prefix: a digit
    /// or "-" produces Cgs, while an ASCII letter or "_" produces Cgt.
    private static func isValidVisitorData(_ str: String) -> Bool {
        (str.hasPrefix("Cgs") || str.hasPrefix("Cgt")) && str.count > 20
            && str.range(
                of: #"^[A-Za-z0-9_\-+/=%]+$"#,
                options: .regularExpression) != nil
    }

    /// Fetches visitorData from `music.youtube.com/sw.js_data`. The response
    /// starts with a Google XSSI prefix (`)]}'`), followed by a JSON array.
    /// The visitorData token is nested at `[0][2][first valid visitor token]`.
    private func fetchVisitorDataFromSwJsData() async throws -> String? {
        guard let url = URL(string: "https://music.youtube.com/sw.js_data") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            return nil
        }

        guard let text = String(data: data, encoding: .utf8), text.count > 5 else {
            return nil
        }

        // Verify and strip XSSI protection prefix ")]}'"
        guard text.hasPrefix(")]}'") else {
            Log.innerTube.warning("sw.js_data missing expected XSSI prefix")
            return nil
        }
        let jsonText = String(text.dropFirst(5))

        guard let jsonData = jsonText.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any]
        else {
            return nil
        }

        // InnerTune path: json[0][2][first "Cgt..." element]
        if let firstArray = json.first as? [Any],
            firstArray.count > 2,
            let thirdArray = firstArray[2] as? [Any]
        {
            for element in thirdArray {
                if let str = element as? String, Self.isValidVisitorData(str) {
                    return str
                }
            }
        }

        // Recursive fallback: scan all nested arrays for a valid token
        if let token = Self.findVisitorDataRecursively(in: json) {
            return token
        }

        Log.innerTube.warning("Could not find visitorData in sw.js_data JSON")
        return nil
    }

    /// Recursively scans a JSON structure for the first valid visitorData token.
    private static func findVisitorDataRecursively(in value: Any) -> String? {
        if let str = value as? String, isValidVisitorData(str) {
            return str
        }
        if let array = value as? [Any] {
            for element in array {
                if let found = findVisitorDataRecursively(in: element) {
                    return found
                }
            }
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict {
                if let found = findVisitorDataRecursively(in: v) {
                    return found
                }
            }
        }
        return nil
    }

    /// Scrapes `music.youtube.com` HTML for a visitorData token as fallback.
    private func fetchVisitorDataFromMusicHTML() async throws -> String? {
        guard let url = URL(string: "https://music.youtube.com") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("\(locale.hl),en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            return nil
        }

        let searchData = data.prefix(131_072)
        if let html = String(data: searchData, encoding: .utf8),
            let range = html.range(of: "\"visitorData\":\"")
        {
            let start = range.upperBound
            if let endRange = html[start...].range(of: "\"") {
                let extracted = String(html[start..<endRange.lowerBound])
                if Self.isValidVisitorData(extracted) {
                    return extracted
                }
            }
        }

        return nil
    }

    /// Fetches a fresh visitorData token from YouTube's visitor_id API endpoint.
    /// Uses the same approach as NewPipe — minimal WEB context, no auth required.
    private func fetchVisitorDataFromVisitorIdAPI() async -> String? {
        let apiKey = SecretsProvider.innerTubeKeyWeb
        guard !apiKey.isEmpty,
              let url = URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?key=\(apiKey)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Dynamic version keeps the visitor_id API request looking current.
        // WEB client uses format `2.YYYYMMDD.00.00`.
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let webVersion = "2.\(formatter.string(from: Date())).00.00"

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": webVersion
                ]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else { return nil }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let responseContext = json["responseContext"] as? [String: Any],
                let token = responseContext["visitorData"] as? String,
                Self.isValidVisitorData(token)
            {
                return token
            }
        } catch {
            // Silently fall through to next source
        }
        return nil
    }

    /// A failed refresh already stores a newly generated token. Reuse that token
    /// for the request body and header so a degraded request has one identity.
    private func effectiveVisitorData() -> String {
        return visitorData
    }

    private var effectiveVisitorSource: PlaybackDiagnostics.VisitorSource {
        degradedVisitorState ? .generated : playerVisitorSource
    }

    /// Writes the last-good visitorData and timestamp to UserDefaults so the next
    /// cold launch can hydrate without an immediate network round-trip.
    private func persistVisitorData(_ value: String) {
        guard !value.isEmpty else { return }
        userDefaults.set(value, forKey: Self.visitorDataPersistenceKey)
        userDefaults.set(Date().timeIntervalSince1970, forKey: Self.visitorDataPersistenceAtKey)
    }

    /// Ensures visitorData is fresh before InnerTube requests. Uses in-flight
    /// deduplication to prevent actor-reentrancy races: if multiple callers hit
    /// this concurrently, they all await the same refresh task.
    private func ensureFreshVisitorData() async {
        if let timestamp = visitorDataTimestamp,
            Date().timeIntervalSince(timestamp) < visitorDataTTL
        {
            return  // still valid
        }

        // In-flight dedup: reuse an existing refresh task if one is already running
        if let existingTask = visitorDataRefreshTask {
            try? await existingTask.value
            return
        }

        let generation = authenticationGeneration
        let task = Task<Void, Error> {
            await refreshVisitorData()
        }

        visitorDataRefreshTask = task
        try? await task.value
        if generation == authenticationGeneration { visitorDataRefreshTask = nil }
    }

    /// Updates `degradedVisitorState` and posts a notification on transition so
    /// observers (e.g. `HomeViewModel`) can surface a soft banner. Posting only
    /// on transition keeps notification volume bounded.
    private func setDegraded(_ newValue: Bool) {
        guard newValue != degradedVisitorState else { return }
        degradedVisitorState = newValue
        let payload = newValue
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .innerTubeDegradedStateChanged,
                object: nil,
                userInfo: ["degraded": payload]
            )
        }
    }

    // MARK: - IOS Player with Session Cookies

    /// Resets the session so the next playerWithSession call re-fetches cookies.
    func resetSession() {
        playerSessionGeneration &+= 1
        hasInitializedSession = false
        sessionCookies = []
        sessionInitTime = nil
    }

    /// Visits the YouTube watch page to obtain cookies and extract visitorData.
    /// Anonymous VisionOS fallback only borrows the visitor token; it must not
    /// mark an authenticated IOS session as initialized or send saved cookies.
    @discardableResult
    private func initializePlayerSession(
        for videoId: String, useSavedSession: Bool = true
    ) async throws -> String {
        Log.innerTube.info("Initializing player session for \(videoId, privacy: .public)")
        let generation = playerSessionGeneration

        // Pre-populate required cookies in the shared cookie storage
        guard let youtubeURL = URL(string: "https://www.youtube.com") else {
            throw InnerTubeError.invalidURL
        }
        let baseCookies: [(String, String)] = [
            ("PREF", "hl=\(locale.hl)&gl=\(locale.gl)&tz=Asia/Ho_Chi_Minh"),
            ("SOCS", "CAI"),
        ]
        for (name, value) in baseCookies {
            if let cookie = HTTPCookie(properties: [
                .name: name, .value: value,
                .domain: ".youtube.com", .path: "/",
                .secure: "TRUE",
            ]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }

        guard var watchComponents = URLComponents(string: "https://www.youtube.com/watch") else {
            throw InnerTubeError.invalidURL
        }
        watchComponents.queryItems = [
            URLQueryItem(name: "v", value: videoId),
        ]
        guard let watchURL = watchComponents.url else {
            throw InnerTubeError.invalidURL
        }

        var watchRequest = URLRequest(url: watchURL)
        watchRequest.cachePolicy = .reloadIgnoringLocalCacheData
        watchRequest.httpShouldHandleCookies = useSavedSession
        watchRequest.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        watchRequest.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        watchRequest.setValue("\(locale.hl),en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        watchRequest.setValue(cookieHeaderString(includeAuthentication: useSavedSession),
                              forHTTPHeaderField: "Cookie")
        let watchHasAuth = useSavedSession && playerSessionContext().isAuthenticated

        let result: (Data, URLResponse)
        do { result = try await session.data(for: watchRequest) }
        catch {
            PlaybackDiagnostics.shared.record(.init(phase: .watchSession, client: .iosSession,
                videoID: videoId,
                reason: error is CancellationError || (error as NSError).code == NSURLErrorCancelled ? .cancelled : .network,
                hasAuth: watchHasAuth, transportErrorCode: (error as NSError).code))
            throw error
        }
        let (data, response) = result
        guard !Task.isCancelled, generation == playerSessionGeneration else {
            throw CancellationError()
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200...299).contains(status) else {
            PlaybackDiagnostics.shared.record(.init(phase: .watchSession, client: .iosSession,
                videoID: videoId, httpStatus: status, reason: .other, hasAuth: watchHasAuth))
            throw InnerTubeError.httpError(statusCode: status ?? -1)
        }
        guard response.url?.scheme == "https", response.url?.host == "www.youtube.com",
              let token = Self.playerVisitorData(from: data) else {
            PlaybackDiagnostics.shared.record(.init(phase: .watchSession, client: .iosSession,
                videoID: videoId, httpStatus: status, reason: .other, hasAuth: watchHasAuth))
            throw InnerTubeError.noStreamAvailable
        }

        if useSavedSession {
            // URLSession with httpCookieStorage = .shared automatically stores Set-Cookie headers.
            // Read them back so we can include them in the manual Cookie header.
            if let cookies = HTTPCookieStorage.shared.cookies(for: youtubeURL) {
                sessionCookies = cookies
            }
            self.visitorData = token
            self.playerVisitorSource = .watchPage
            self.visitorDataTimestamp = Date()
            persistVisitorData(token)
            refreshFailureCount = 0
            setDegraded(false)
            hasInitializedSession = true
            sessionInitTime = Date()
        }
        PlaybackDiagnostics.shared.record(.init(phase: .watchSession, client: .iosSession,
            videoID: videoId, httpStatus: status, hasAuth: watchHasAuth, visitorSource: .watchPage))
        return token
    }

    private static func playerVisitorData(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8),
              let range = html.range(of: "\"visitorData\":\""),
              let end = html[range.upperBound...].range(of: "\"") else { return nil }
        let token = String(html[range.upperBound..<end.lowerBound])
        return isValidVisitorData(token) ? token : nil
    }

    /// Builds a Cookie header string merging session cookies + auth cookies (SAPISID, SID…).
    private func cookieHeaderString(includeAuthentication: Bool = true) -> String {
        guard let youtubeURL = URL(string: "https://www.youtube.com") else { return "" }
        var values = ["PREF": "hl=\(locale.hl)&gl=\(locale.gl)&tz=Asia/Ho_Chi_Minh", "SOCS": "CAI"]
        for stored in (HTTPCookieStorage.shared.cookies(for: youtubeURL) ?? sessionCookies)
        where stored.name == "VISITOR_INFO1_LIVE"
            || !YouTubeAuthManager.authCookieNames.contains(stored.name) {
            values[stored.name] = stored.value
        }
        // The validated Keychain session overrides stale cookies by name.
        if includeAuthentication, let authCookieStr = self.cookie, !authCookieStr.isEmpty {
            for part in authCookieStr.split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
            }
        }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    /// Fetches player data with the current session; source restrictions remain authoritative.
    func playerWithSession(videoId: String, playlistId: String? = nil) async throws -> Data {
        let context = playerSessionContext()
        // Auto-refresh session if expired (> 4 hours) or cookies missing
        let sessionAge = sessionInitTime.map { Date().timeIntervalSince($0) } ?? .infinity
        if sessionAge > 14400 || sessionCookies.isEmpty {
            hasInitializedSession = false
        }

        if !hasInitializedSession {
            try await initializePlayerSession(for: videoId)
        }
        guard !Task.isCancelled, context == playerSessionContext() else {
            throw CancellationError()
        }

        let client = YouTubeClient.ios

        guard var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        else {
            throw InnerTubeError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let playerURL = components.url else {
            throw InnerTubeError.invalidURL
        }
        var request = URLRequest(url: playerURL)
        request.httpMethod = "POST"
        // polish-B3: bypass URLCache on the player POST as well.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.clientId, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let visitorForHeader = effectiveVisitorData()
        if !visitorForHeader.isEmpty {
            request.setValue(visitorForHeader, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.setValue(cookieHeaderString(), forHTTPHeaderField: "Cookie")
        // Use only credentials from the user's current, saved session.
        if let authorization = YouTubeAuthManager.sessionAuthorizationHeader(
            cookieHeader: cookie, origin: "https://www.youtube.com") {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let body = IOSPlayerBody(
            context: .init(
                client: .init(
                    clientName: "IOS",
                    clientVersion: "21.03.2",
                    deviceMake: "Apple",
                    deviceModel: "iPhone16,2",
                    osName: "iPhone",
                    osVersion: "18.3.2.22D82",
                    hl: locale.hl,
                    gl: locale.gl,
                    visitorData: visitorForHeader.isEmpty ? nil : visitorForHeader
                )),
            videoId: videoId,
            playlistId: playlistId
        )

        request.httpBody = try encoder.encode(body)

        Log.innerTube.info("Player request for \(videoId, privacy: .public) with IOS")
        return try await executePlayerRequest(request, videoID: videoId, client: .iosSession,
            hasAuth: context.isAuthenticated, visitorSource: effectiveVisitorSource)
    }

    /// Fetches player data using VISIONOS client — returns hlsManifestUrl + direct URLs
    /// with no byte-range restriction. visitorData is fetched from youtube.com/tv first.
    func playerWithVisionOS(videoId: String) async throws -> Data {
        let client = YouTubeClient.visionOS
        let context = playerSessionContext()

        // Get visitorData from youtube.com/tv (VISIONOS requires TV visitorData)
        let visitorForHeader: String
        let visitorSource: PlaybackDiagnostics.VisitorSource
        if let tvVisitorData = try await fetchTVVisitorData() {
            visitorForHeader = tvVisitorData
            visitorSource = .tvPage
        } else {
            // A guest can reach VisionOS before IOS has visited /watch. Keep
            // this fallback anonymous even when a saved session exists.
            let watchVisitor: String?
            do {
                watchVisitor = try await initializePlayerSession(for: videoId, useSavedSession: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                watchVisitor = nil
            }
            visitorForHeader = watchVisitor ?? effectiveVisitorData()
            visitorSource = watchVisitor == nil ? effectiveVisitorSource : .watchPage
        }
        guard !Task.isCancelled, context == playerSessionContext() else {
            throw CancellationError()
        }

        guard var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")
        else { throw InnerTubeError.invalidURL }
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        guard let playerURL = components.url else { throw InnerTubeError.invalidURL }

        var request = URLRequest(url: playerURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.clientId, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if !visitorForHeader.isEmpty {
            request.setValue(visitorForHeader, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // Include SOCS=CAI consent cookie for region compliance
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")

        let body = IOSPlayerBody(
            context: .init(
                client: .init(
                    clientName: "VISIONOS",
                    clientVersion: "1.02",
                    deviceMake: "Apple",
                    deviceModel: "RealityDevice17,1",
                    osName: "visionOS",
                    osVersion: "26.5",
                    hl: locale.hl,
                    gl: locale.gl,
                    visitorData: visitorForHeader.isEmpty ? nil : visitorForHeader
                )),
            videoId: videoId,
            playlistId: nil
        )
        request.httpBody = try encoder.encode(body)
        Log.innerTube.info("Player request for \(videoId, privacy: .public) with VISIONOS")
        return try await executePlayerRequest(request, videoID: videoId, client: .visionOS,
            hasAuth: false, visitorSource: visitorSource)
    }

    /// Fetch visitorData from https://www.youtube.com/tv — required for VISIONOS client.
    private func fetchTVVisitorData() async throws -> String? {
        guard let url = URL(string: "https://www.youtube.com/tv") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpShouldHandleCookies = false
        req.setValue(YouTubeClient.userAgentVisionOS, forHTTPHeaderField: "User-Agent")
        req.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 10
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            PlaybackDiagnostics.shared.record(.init(phase: .visitor, client: .visionOS,
                reason: .network, hasAuth: false, visitorSource: .appFallback))
            return nil
        }
        try Task.checkCancellation()
        let (data, response) = result
        // Extract visitorData from ytInitialData or yt.setConfig
        if let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
           response.url?.scheme == "https", response.url?.host == "www.youtube.com",
           let token = Self.playerVisitorData(from: data) {
            PlaybackDiagnostics.shared.record(.init(phase: .visitor, client: .visionOS,
                httpStatus: (response as? HTTPURLResponse)?.statusCode,
                hasAuth: false, visitorSource: .tvPage))
            return token
        }
        PlaybackDiagnostics.shared.record(.init(phase: .visitor, client: .visionOS,
            httpStatus: (response as? HTTPURLResponse)?.statusCode,
            hasAuth: false, visitorSource: .appFallback))
        return nil
    }
}

// MARK: - IOS Player Request Body

private struct IOSPlayerBody: Encodable {
    let context: IOSContext
    let videoId: String
    let playlistId: String?

    struct IOSContext: Encodable {
        let client: IOSClient
    }

    struct IOSClient: Encodable {
        let clientName: String
        let clientVersion: String
        let deviceMake: String
        let deviceModel: String
        let osName: String
        let osVersion: String
        let hl: String
        let gl: String
        let visitorData: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(clientName, forKey: .clientName)
            try c.encode(clientVersion, forKey: .clientVersion)
            try c.encode(deviceMake, forKey: .deviceMake)
            try c.encode(deviceModel, forKey: .deviceModel)
            try c.encode(osName, forKey: .osName)
            try c.encode(osVersion, forKey: .osVersion)
            try c.encode(hl, forKey: .hl)
            try c.encode(gl, forKey: .gl)
            try c.encodeIfPresent(visitorData, forKey: .visitorData)
        }

        enum CodingKeys: String, CodingKey {
            case clientName, clientVersion, deviceMake, deviceModel
            case osName, osVersion, hl, gl, visitorData
        }
    }
}

/// The public WEB_REMIX settings shipped inside YouTube Music's own HTML.
/// No static keys, OAuth tokens or user credentials are required or stored.
/// This is an unofficial web endpoint and can change without notice.
struct PublicMusicWebBootstrap: Equatable, Sendable {
    let apiKey: String
    let clientVersion: String

    static func parse(_ html: String) -> Self? {
        guard let key = capture(
            #""INNERTUBE_API_KEY"\s*:\s*"(AIza[A-Za-z0-9_-]{35})""#,
            from: html
        ),
        let version = capture(
            #""INNERTUBE_CONTEXT_CLIENT_VERSION"\s*:\s*"(1\.[A-Za-z0-9._-]{6,48})""#,
            from: html
        ) ?? capture(
            #""INNERTUBE_CLIENT_VERSION"\s*:\s*"(1\.[A-Za-z0-9._-]{6,48})""#,
            from: html
        )
        else { return nil }

        return Self(apiKey: key, clientVersion: version)
    }

    private static func capture(_ pattern: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }
}

enum InnerTubeError: Error, LocalizedError {
    case sourceNotConfigured
    case searchBootstrapUnavailable
    case httpError(statusCode: Int)
    case decodingError(Error)
    case invalidURL
    case noStreamAvailable
    /// Video is permanently unavailable (region-blocked, removed, private, etc.).
    /// Distinguished from `noStreamAvailable` so callers can skip wasteful retries.
    case videoUnavailable(reason: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .sourceNotConfigured: return LocalizationManager.text("Online source is not configured")
        case .searchBootstrapUnavailable:
            return "無法取得 YouTube Music 搜尋設定，請稍後再試。也可於搜尋設定使用自己的 Data API 金鑰。"
        case .httpError(let code): return LocalizationManager.text("HTTP error: \(code)")
        case .decodingError(let err): return LocalizationManager.text("Decoding error: \(err.localizedDescription)")
        case .invalidURL: return LocalizationManager.text("Invalid URL")
        case .noStreamAvailable: return LocalizationManager.text("No audio stream available")
        case .videoUnavailable(let reason): return LocalizationManager.text("Video unavailable: \(reason)")
        case .timeout: return LocalizationManager.text("Request timed out")
        }
    }

    /// Permanent failures should not be retried — the result will not change on retry.
    var isPermanent: Bool {
        switch self {
        case .videoUnavailable, .noStreamAvailable: return true
        default: return false
        }
    }
}
