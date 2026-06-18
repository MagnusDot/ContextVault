import Foundation

// Generates a realistic 25-file Swift codebase on disk.
// Files are large enough that reading them all costs thousands of tokens,
// making ContextVault's BM25 search measurably cheaper.
enum FakeCodebase {

    static func create(in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent("MyApp")
        let fm = FileManager.default

        let dirs = [
            "Sources/Auth",
            "Sources/Network",
            "Sources/Models",
            "Sources/Sync",
            "Sources/Database",
            "Sources/Services",
            "Sources/Utils",
            "Sources/Config",
            "Tests",
        ]
        for d in dirs {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        for (relativePath, content) in files {
            try content.write(
                to: root.appendingPathComponent(relativePath),
                atomically: true, encoding: .utf8
            )
        }
        return root
    }

    static let files: [(String, String)] = [
        ("Sources/Auth/AuthService.swift",              authService),
        ("Sources/Auth/TokenStore.swift",               tokenStore),
        ("Sources/Auth/JWTMiddleware.swift",            jwtMiddleware),
        ("Sources/Auth/OAuthProvider.swift",            oauthProvider),
        ("Sources/Auth/SessionManager.swift",           sessionManager),
        ("Sources/Network/NetworkClient.swift",         networkClient),
        ("Sources/Network/TokenRefreshInterceptor.swift", tokenRefreshInterceptor),
        ("Sources/Network/RequestBuilder.swift",        requestBuilder),
        ("Sources/Network/ResponseParser.swift",        responseParser),
        ("Sources/Network/APIEndpoints.swift",          apiEndpoints),
        ("Sources/Models/User.swift",                   userModel),
        ("Sources/Models/AccessToken.swift",            accessTokenModel),
        ("Sources/Models/Project.swift",                projectModel),
        ("Sources/Models/Document.swift",               documentModel),
        ("Sources/Models/Permission.swift",             permissionModel),
        ("Sources/Database/UserRepository.swift",       userRepository),
        ("Sources/Database/ProjectRepository.swift",    projectRepository),
        ("Sources/Database/CacheManager.swift",         cacheManager),
        ("Sources/Database/MigrationRunner.swift",      migrationRunner),
        ("Sources/Sync/SyncEngine.swift",               syncEngine),
        ("Sources/Sync/ConflictResolver.swift",         conflictResolver),
        ("Sources/Sync/ChangeTracker.swift",            changeTracker),
        ("Sources/Services/NotificationService.swift",  notificationService),
        ("Sources/Services/AnalyticsService.swift",     analyticsService),
        ("Sources/Utils/Logger.swift",                  logger),
        ("Sources/Utils/Keychain.swift",                keychain),
        ("Sources/Config/AppConfig.swift",              appConfig),
        ("Tests/AuthServiceTests.swift",                authServiceTests),
        ("Tests/NetworkClientTests.swift",              networkClientTests),
        ("Tests/SyncEngineTests.swift",                 syncEngineTests),
    ]

    // MARK: - Sources/Auth/AuthService.swift

    static let authService = """
    import Foundation
    import CryptoKit

    // AuthService manages the full JWT lifecycle: generation, validation, rotation, and revocation.
    // All tokens use HS256 signatures with a per-deployment secret key.
    // Access tokens are short-lived (15 min); refresh tokens are long-lived (7 days) and opaque.
    final class AuthService {

        static let accessTokenTTL: TimeInterval  = 15 * 60        // 15 minutes
        static let refreshTokenTTL: TimeInterval = 7 * 24 * 3600  // 7 days
        static let refreshWindow: TimeInterval   = 60             // proactive refresh if < 60s left

        private let tokenRepository: TokenRepository
        private let userRepository: UserRepository
        private let secret: String
        private let logger: Logger

        init(
            tokenRepository: TokenRepository,
            userRepository: UserRepository,
            secret: String,
            logger: Logger = .shared
        ) {
            self.tokenRepository = tokenRepository
            self.userRepository  = userRepository
            self.secret          = secret
            self.logger          = logger
        }

        // Generates a short-lived HS256 JWT access token for the given user.
        // The token payload includes the user's role for authorization decisions.
        func generateAccessToken(for user: User) throws -> AccessToken {
            let now = Date()
            let payload = JWTPayload(
                sub:  user.id.uuidString,
                iat:  now,
                exp:  now.addingTimeInterval(Self.accessTokenTTL),
                jti:  UUID().uuidString,
                role: user.role.rawValue,
                email: user.email
            )
            let header    = try encodeBase64URL(JSONEncoder().encode(JWTHeader()))
            let claims    = try encodeBase64URL(JSONEncoder().encode(payload))
            let signature = hmacSHA256(message: "\\(header).\\(claims)", key: secret)
            let rawJWT    = "\\(header).\\(claims).\\(signature)"
            logger.debug("Access token generated for user \\(user.id), expires \\(payload.exp)")
            return AccessToken(rawValue: rawJWT, expiresAt: payload.exp, userId: user.id)
        }

        // Generates a long-lived opaque refresh token and persists it to the token repository.
        // Each call produces a unique token — multiple refresh tokens per user are allowed (multi-device).
        func generateRefreshToken(for user: User) throws -> String {
            let token  = UUID().uuidString + "-" + UUID().uuidString
            let expiry = Date().addingTimeInterval(Self.refreshTokenTTL)
            try tokenRepository.save(refreshToken: token, userId: user.id, expiresAt: expiry)
            logger.info("Refresh token issued for user \\(user.id)")
            return token
        }

        // Validates a JWT access token: checks structure, signature, and expiry.
        // Returns the parsed payload so callers can extract sub, role, and jti.
        func validateAccessToken(_ jwt: String) throws -> JWTPayload {
            let parts = jwt.components(separatedBy: ".")
            guard parts.count == 3 else {
                logger.warn("Malformed JWT received (\\(parts.count) parts)")
                throw AuthError.malformedToken
            }

            let headerClaims = "\\(parts[0]).\\(parts[1])"
            let expectedSig  = hmacSHA256(message: headerClaims, key: secret)
            guard constantTimeEquals(expectedSig, parts[2]) else {
                logger.warn("JWT signature mismatch")
                throw AuthError.invalidSignature
            }

            // Pad base64url to standard base64 before decoding
            var b64 = parts[1]
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }

            guard let data    = Data(base64Encoded: b64),
                  let payload = try? JSONDecoder().decode(JWTPayload.self, from: data)
            else {
                throw AuthError.malformedToken
            }

            guard payload.exp > Date() else {
                logger.debug("JWT expired for user \\(payload.sub)")
                throw AuthError.tokenExpired
            }
            return payload
        }

        // Rotates a refresh token pair: atomically revokes the old token and issues new access + refresh.
        // The revocation happens BEFORE new tokens are issued to prevent replay attacks.
        // If two concurrent requests arrive with the same refresh token, only one will succeed —
        // the second will throw invalidRefreshToken because the first already revoked it.
        func rotateRefreshToken(_ oldToken: String) throws -> (AccessToken, String) {
            guard let stored = try tokenRepository.findRefreshToken(oldToken) else {
                logger.warn("Refresh token not found — possible replay attack")
                throw AuthError.invalidRefreshToken
            }
            guard stored.expiresAt > Date() else {
                try tokenRepository.revokeRefreshToken(oldToken)
                logger.info("Expired refresh token used and revoked for user \\(stored.userId)")
                throw AuthError.tokenExpired
            }
            guard stored.revokedAt == nil else {
                // Token already revoked — possible token theft, revoke all tokens for the user
                logger.error("Revoked token reused — revoking all tokens for user \\(stored.userId)")
                try tokenRepository.revokeAllTokens(userId: stored.userId)
                throw AuthError.tokenTheft
            }
            guard let user = try userRepository.findByID(stored.userId) else {
                throw AuthError.userNotFound
            }
            // Critical ordering: revoke BEFORE issuing to prevent duplicate issuance
            try tokenRepository.revokeRefreshToken(oldToken)
            let newAccess  = try generateAccessToken(for: user)
            let newRefresh = try generateRefreshToken(for: user)
            logger.info("Token pair rotated successfully for user \\(user.id)")
            return (newAccess, newRefresh)
        }

        // Revokes all active tokens for a user. Used for logout-from-all-devices.
        func revokeAllTokens(for userId: UUID) throws {
            try tokenRepository.revokeAllTokens(userId: userId)
            logger.info("All tokens revoked for user \\(userId)")
        }

        // Checks if an access token is approaching expiry and should be proactively refreshed.
        func shouldRefreshProactively(_ token: AccessToken) -> Bool {
            token.expiresWithin(Self.refreshWindow)
        }

        // MARK: - Private helpers

        private func encodeBase64URL(_ data: Data) throws -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }

        private func hmacSHA256(message: String, key: String) -> String {
            let sym = SymmetricKey(data: Data(key.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: sym)
            return Data(mac).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }

        // Constant-time string comparison to prevent timing attacks on signature verification.
        private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a.utf8, b.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    enum AuthError: Error {
        case malformedToken, invalidSignature, tokenExpired
        case invalidRefreshToken, userNotFound, tokenTheft
    }

    struct JWTHeader: Codable {
        let alg = "HS256"
        let typ = "JWT"
    }

    struct JWTPayload: Codable {
        let sub:   String
        let iat:   Date
        let exp:   Date
        let jti:   String
        let role:  String
        let email: String
    }

    protocol TokenRepository {
        func save(refreshToken: String, userId: UUID, expiresAt: Date) throws
        func findRefreshToken(_ token: String) throws -> StoredRefreshToken?
        func revokeRefreshToken(_ token: String) throws
        func revokeAllTokens(userId: UUID) throws
    }
    """

    // MARK: - Sources/Auth/TokenStore.swift

    static let tokenStore = """
    import Foundation

    // TokenStore persists the current access + refresh token pair to the system Keychain.
    // All reads/writes go through the Keychain helper to ensure encryption at rest.
    // Tokens are scoped to the bundle ID so sandbox prevents cross-app access.
    final class TokenStore {

        static let shared = TokenStore()

        private let keychain: KeychainWrapper
        private let accessTokenKey  = "myapp.access_token"
        private let refreshTokenKey = "myapp.refresh_token"
        private let expiryKey       = "myapp.access_token_expiry"

        private init(keychain: KeychainWrapper = .shared) {
            self.keychain = keychain
        }

        // Persists a new token pair after successful login or token rotation.
        // Overwrites any previously stored tokens for this installation.
        func store(accessToken: AccessToken, refreshToken: String) throws {
            try keychain.set(accessToken.rawValue, forKey: accessTokenKey)
            try keychain.set(refreshToken,         forKey: refreshTokenKey)
            try keychain.set(
                String(accessToken.expiresAt.timeIntervalSince1970),
                forKey: expiryKey
            )
        }

        // Returns the stored access token if present and not expired.
        // Returns nil if the token is missing or already expired — caller must refresh.
        func retrieveAccessToken() -> AccessToken? {
            guard
                let raw    = keychain.get(accessTokenKey),
                let expStr = keychain.get(expiryKey),
                let expTS  = TimeInterval(expStr)
            else { return nil }

            let expiry = Date(timeIntervalSince1970: expTS)
            guard expiry > Date() else {
                // Silently clear the stale token — avoid returning something the server will reject
                try? clearAccessToken()
                return nil
            }
            // We don't know the userId from the raw keychain data — caller must decode from JWT
            return AccessToken(rawValue: raw, expiresAt: expiry, userId: UUID())
        }

        // Returns the stored refresh token. Refresh tokens are opaque and have no local expiry check;
        // the server validates their expiry during rotation.
        func retrieveRefreshToken() -> String? {
            keychain.get(refreshTokenKey)
        }

        // Checks whether a valid (non-expired) access token exists without fully parsing it.
        var hasValidAccessToken: Bool {
            retrieveAccessToken() != nil
        }

        // Checks whether a refresh token is present (regardless of expiry).
        var hasRefreshToken: Bool {
            keychain.get(refreshTokenKey) != nil
        }

        // Removes only the access token. Called when a 401 is received to force a refresh cycle.
        func clearAccessToken() throws {
            try keychain.delete(accessTokenKey)
            try keychain.delete(expiryKey)
        }

        // Removes all tokens. Called on explicit logout or when token theft is detected.
        func clearAll() throws {
            try keychain.delete(accessTokenKey)
            try keychain.delete(refreshTokenKey)
            try keychain.delete(expiryKey)
        }
    }
    """

    // MARK: - Sources/Auth/JWTMiddleware.swift

    static let jwtMiddleware = """
    import Foundation

    // JWTMiddleware validates inbound Authorization: Bearer <token> headers.
    // It is used server-side (in the embedded local HTTP server) and in tests.
    struct JWTMiddleware {

        private let authService: AuthService
        private let logger: Logger

        init(authService: AuthService, logger: Logger = .shared) {
            self.authService = authService
            self.logger      = logger
        }

        // Validates the bearer token and returns the parsed JWT payload.
        // Throws AuthError if the token is missing, malformed, expired, or has an invalid signature.
        func validate(request: HTTPRequest) throws -> JWTPayload {
            let token = try extractBearerToken(from: request)
            do {
                return try authService.validateAccessToken(token)
            } catch AuthError.tokenExpired {
                logger.debug("Expired token in request to \\(request.path)")
                throw AuthError.tokenExpired
            }
        }

        // Requires the payload to carry a specific role. Returns 403 Forbidden otherwise.
        func requireRole(_ required: UserRole, in payload: JWTPayload) throws {
            guard payload.role == required.rawValue || payload.role == UserRole.admin.rawValue else {
                logger.warn("Role check failed: required=\\(required.rawValue) actual=\\(payload.role)")
                throw MiddlewareError.forbidden(required: required.rawValue, actual: payload.role)
            }
        }

        // Requires admin role specifically — convenience wrapper used on sensitive endpoints.
        func requireAdmin(_ payload: JWTPayload) throws {
            try requireRole(.admin, in: payload)
        }

        // Extracts the raw JWT string from the Authorization header.
        private func extractBearerToken(from request: HTTPRequest) throws -> String {
            guard let header = request.headers["Authorization"] else {
                throw MiddlewareError.missingAuthHeader
            }
            let parts = header.components(separatedBy: " ")
            guard parts.count == 2, parts[0] == "Bearer", !parts[1].isEmpty else {
                throw MiddlewareError.malformedAuthHeader(header)
            }
            return parts[1]
        }
    }

    enum MiddlewareError: Error {
        case missingAuthHeader
        case malformedAuthHeader(String)
        case forbidden(required: String, actual: String)
    }

    struct HTTPRequest {
        let method: String
        let path: String
        var headers: [String: String] = [:]
        var body: Data? = nil
        var remoteAddress: String = "127.0.0.1"
    }
    """

    // MARK: - Sources/Auth/OAuthProvider.swift

    static let oauthProvider = """
    import Foundation

    // OAuthProvider handles the OAuth 2.0 Authorization Code Flow with PKCE.
    // Used when signing in via external identity providers (Google, GitHub, Apple).
    // All state parameters are cryptographically random to prevent CSRF attacks.
    final class OAuthProvider {

        struct Config {
            let clientId:     String
            let clientSecret: String
            let authURL:      URL
            let tokenURL:     URL
            let redirectURI:  String
            let scopes:       [String]
        }

        private let config:        Config
        private let networkClient: NetworkClient
        private var pendingState:  [String: PKCEChallenge] = [:]

        init(config: Config, networkClient: NetworkClient) {
            self.config        = config
            self.networkClient = networkClient
        }

        // Step 1: Builds the authorization URL. The user is redirected here to grant consent.
        // Generates a PKCE code verifier + challenge pair and stores it keyed by state.
        func buildAuthorizationURL() throws -> (url: URL, state: String) {
            let state     = generateState()
            let challenge = try PKCEChallenge.generate()
            pendingState[state] = challenge

            var components = URLComponents(url: config.authURL, resolvingAgainstBaseURL: true)!
            components.queryItems = [
                URLQueryItem(name: "response_type",         value: "code"),
                URLQueryItem(name: "client_id",             value: config.clientId),
                URLQueryItem(name: "redirect_uri",          value: config.redirectURI),
                URLQueryItem(name: "scope",                 value: config.scopes.joined(separator: " ")),
                URLQueryItem(name: "state",                 value: state),
                URLQueryItem(name: "code_challenge",        value: challenge.challengeBase64URL),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            guard let url = components.url else { throw OAuthError.invalidConfiguration }
            return (url, state)
        }

        // Step 2: Exchanges the authorization code for an access + refresh token pair.
        // Validates state to ensure this matches a pending flow started by this client.
        func exchangeCode(_ code: String, state: String) async throws -> OAuthTokenResponse {
            guard let challenge = pendingState.removeValue(forKey: state) else {
                throw OAuthError.stateValidationFailed
            }
            let body = [
                "grant_type":    "authorization_code",
                "code":          code,
                "redirect_uri":  config.redirectURI,
                "client_id":     config.clientId,
                "client_secret": config.clientSecret,
                "code_verifier": challenge.verifier,
            ]
            let endpoint = APIEndpoint(
                method: "POST",
                path:   config.tokenURL.path,
                body:   try RequestBuilder.jsonBody(body)
            )
            return try await networkClient.send(endpoint, as: OAuthTokenResponse.self)
        }

        // Refreshes an OAuth access token using the stored refresh token.
        // Note: unlike our own JWT rotation, OAuth refresh tokens may be reusable (provider-dependent).
        func refreshAccessToken(_ refreshToken: String) async throws -> OAuthTokenResponse {
            let body = [
                "grant_type":    "refresh_token",
                "refresh_token": refreshToken,
                "client_id":     config.clientId,
                "client_secret": config.clientSecret,
            ]
            let endpoint = APIEndpoint(
                method: "POST",
                path:   config.tokenURL.path,
                body:   try RequestBuilder.jsonBody(body)
            )
            return try await networkClient.send(endpoint, as: OAuthTokenResponse.self)
        }

        private func generateState() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    struct OAuthTokenResponse: Decodable {
        let accessToken:  String
        let tokenType:    String
        let expiresIn:    Int
        let refreshToken: String?
        let scope:        String?
        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case tokenType    = "token_type"
            case expiresIn    = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    struct PKCEChallenge {
        let verifier:           String
        let challengeBase64URL: String
        static func generate() throws -> PKCEChallenge {
            var bytes = [UInt8](repeating: 0, count: 64)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let verifier = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let digest = SHA256.hash(data: Data(verifier.utf8))
            let challenge = Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return PKCEChallenge(verifier: verifier, challengeBase64URL: challenge)
        }
    }

    enum OAuthError: Error {
        case invalidConfiguration, stateValidationFailed, tokenExchangeFailed
    }
    """

    // MARK: - Sources/Auth/SessionManager.swift

    static let sessionManager = """
    import Foundation

    // SessionManager owns the authenticated session lifecycle end-to-end:
    // login → store tokens → monitor expiry → proactive refresh → logout.
    // It coordinates between TokenStore, AuthService, and the NetworkClient interceptor.
    @Observable
    final class SessionManager {

        enum State {
            case unauthenticated
            case authenticated(User)
            case refreshing
            case loggingOut
        }

        private(set) var state: State = .unauthenticated
        private var refreshTask: Task<AccessToken, Error>?
        private let refreshLock = NSLock()

        private let authService:   AuthService
        private let tokenStore:    TokenStore
        private let userRepository: UserRepository
        private let logger:         Logger

        init(
            authService:    AuthService,
            tokenStore:     TokenStore    = .shared,
            userRepository: UserRepository,
            logger:         Logger        = .shared
        ) {
            self.authService    = authService
            self.tokenStore     = tokenStore
            self.userRepository = userRepository
            self.logger         = logger
        }

        // Restores session from Keychain on app launch. Call from the App entry point.
        func restoreSession() async {
            guard
                let raw     = tokenStore.retrieveAccessToken(),
                let userId  = extractUserId(from: raw.rawValue),
                let user    = userRepository.findByID(userId)
            else {
                state = .unauthenticated
                return
            }
            state = .authenticated(user)
            logger.info("Session restored for user \\(userId)")
        }

        // Completes a login flow: stores the token pair and loads the user record.
        func login(accessToken: AccessToken, refreshToken: String, user: User) async throws {
            try tokenStore.store(accessToken: accessToken, refreshToken: refreshToken)
            userRepository.save(user)
            state = .authenticated(user)
            logger.info("Login successful for \\(user.email)")
        }

        // Refreshes the access token using the stored refresh token.
        // Coalesces concurrent refresh requests — only one network call is made.
        // Returns the new access token or throws if the refresh token is expired/invalid.
        func refreshAccessToken() async throws -> AccessToken {
            // Coalesce concurrent refresh requests using a single shared task
            refreshLock.lock()
            if let existing = refreshTask {
                refreshLock.unlock()
                return try await existing.value
            }
            state = .refreshing
            let task = Task<AccessToken, Error> {
                guard let refreshToken = tokenStore.retrieveRefreshToken() else {
                    throw AuthError.invalidRefreshToken
                }
                let (newAccess, newRefresh) = try authService.rotateRefreshToken(refreshToken)
                try tokenStore.store(accessToken: newAccess, refreshToken: newRefresh)
                if case .refreshing = state, let userId = extractUserId(from: newAccess.rawValue),
                   let user = userRepository.findByID(userId) {
                    state = .authenticated(user)
                }
                logger.info("Token refresh completed, new expiry \\(newAccess.expiresAt)")
                return newAccess
            }
            refreshTask = task
            refreshLock.unlock()

            do {
                let token = try await task.value
                refreshLock.withLock { refreshTask = nil }
                return token
            } catch {
                refreshLock.withLock { refreshTask = nil }
                state = .unauthenticated
                logger.error("Token refresh failed: \\(error)")
                throw error
            }
        }

        // Logs out the current user: revokes all server-side tokens and clears local storage.
        func logout() async throws {
            state = .loggingOut
            if case .authenticated(let user) = state {
                try authService.revokeAllTokens(for: user.id)
            }
            try tokenStore.clearAll()
            state = .unauthenticated
            logger.info("User logged out")
        }

        var isAuthenticated: Bool {
            if case .authenticated = state { return true }
            return false
        }

        private func extractUserId(from rawToken: AccessToken) -> UUID? {
            extractUserId(from: rawToken.rawValue)
        }

        private func extractUserId(from jwt: String) -> UUID? {
            let parts = jwt.components(separatedBy: ".")
            guard parts.count == 3 else { return nil }
            var b64 = parts[1]
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64),
                  let payload = try? JSONDecoder().decode(JWTPayload.self, from: data)
            else { return nil }
            return UUID(uuidString: payload.sub)
        }
    }
    """

    // MARK: - Sources/Network/NetworkClient.swift

    static let networkClient = """
    import Foundation

    // NetworkClient handles all outbound HTTP requests.
    // It implements exponential backoff for transient errors (5xx, connection loss),
    // and delegates 401 handling to the injected TokenRefreshInterceptor.
    final class NetworkClient {

        private let session:     URLSession
        private let baseURL:     URL
        private let interceptor: TokenRefreshInterceptor?
        private let maxRetries:  Int
        private let retryDelay:  TimeInterval
        private let logger:      Logger

        init(
            baseURL:     URL,
            session:     URLSession              = .shared,
            interceptor: TokenRefreshInterceptor? = nil,
            maxRetries:  Int                     = 3,
            retryDelay:  TimeInterval            = 0.5,
            logger:      Logger                  = .shared
        ) {
            self.baseURL     = baseURL
            self.session     = session
            self.interceptor = interceptor
            self.maxRetries  = maxRetries
            self.retryDelay  = retryDelay
            self.logger      = logger
        }

        // Sends an authenticated request and decodes the JSON response into type T.
        func send<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
            let data = try await sendRaw(endpoint)
            return try ResponseParser.decode(T.self, from: data)
        }

        // Sends a request with no expected response body (DELETE, fire-and-forget).
        func sendVoid(_ endpoint: APIEndpoint) async throws {
            _ = try await sendRaw(endpoint)
        }

        // Core send path: builds request, injects auth header, handles 401 via interceptor.
        private func sendRaw(_ endpoint: APIEndpoint) async throws -> Data {
            var request = try RequestBuilder.build(endpoint: endpoint, baseURL: baseURL)

            // Inject current access token if available
            if let interceptor, let token = await interceptor.currentAccessToken() {
                request.setValue("Bearer \\(token.rawValue)", forHTTPHeaderField: "Authorization")
            }

            do {
                return try await sendWithRetry(request)
            } catch NetworkError.unauthorized {
                // 401: attempt token refresh once, then retry the original request
                guard let interceptor else { throw NetworkError.unauthorized }
                logger.debug("401 received — triggering token refresh")
                let newToken = try await interceptor.refreshToken()
                request.setValue("Bearer \\(newToken.rawValue)", forHTTPHeaderField: "Authorization")
                return try await sendWithRetry(request, attempt: 0)
            }
        }

        // Implements exponential backoff for transient 5xx errors and network failures.
        // Retries up to maxRetries times with doubling delay starting from retryDelay.
        private func sendWithRetry(_ request: URLRequest, attempt: Int = 0) async throws -> Data {
            let start = Date()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                let elapsed = Date().timeIntervalSince(start)
                logger.debug("\\(request.httpMethod ?? "?") \\(request.url?.path ?? "") → \\(http.statusCode) in \\(Int(elapsed * 1000))ms")

                switch http.statusCode {
                case 200..<300:  return data
                case 401:        throw NetworkError.unauthorized
                case 403:        throw NetworkError.forbidden
                case 404:        throw NetworkError.notFound
                case 429:
                    // Respect Retry-After header if present
                    let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? retryDelay * 4
                    if attempt < maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        return try await sendWithRetry(request, attempt: attempt + 1)
                    }
                    throw NetworkError.rateLimited
                case 500...:     throw NetworkError.serverError(http.statusCode)
                default:         throw NetworkError.clientError(http.statusCode)
                }
            } catch NetworkError.serverError(let code) where attempt < maxRetries {
                let delay = retryDelay * pow(2.0, Double(attempt))
                logger.warn("Server error \\(code) on attempt \\(attempt + 1), retrying in \\(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await sendWithRetry(request, attempt: attempt + 1)
            } catch let err as URLError where err.code == .networkConnectionLost && attempt < maxRetries {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                return try await sendWithRetry(request, attempt: attempt + 1)
            }
        }
    }

    enum NetworkError: Error {
        case invalidResponse, unauthorized, forbidden, notFound, rateLimited
        case serverError(Int), clientError(Int), decodingFailed(String)
    }

    struct APIEndpoint {
        let method: String
        let path:   String
        var queryItems: [URLQueryItem]  = []
        var headers:    [String: String] = [:]
        var body:       Data?            = nil
    }
    """

    // MARK: - Sources/Network/TokenRefreshInterceptor.swift

    static let tokenRefreshInterceptor = """
    import Foundation

    // TokenRefreshInterceptor sits between NetworkClient and SessionManager.
    // When NetworkClient receives a 401, it calls refreshToken() here.
    // This class coalesces concurrent refresh attempts so only one token request is in-flight at a time.
    // It delegates the actual rotation to SessionManager which owns the token lifecycle.
    final class TokenRefreshInterceptor {

        private let sessionManager: SessionManager
        private let tokenStore:     TokenStore
        private let logger:         Logger

        init(sessionManager: SessionManager, tokenStore: TokenStore = .shared, logger: Logger = .shared) {
            self.sessionManager = sessionManager
            self.tokenStore     = tokenStore
            self.logger         = logger
        }

        // Returns the currently stored access token, or nil if none is available.
        // NetworkClient calls this to inject the Authorization header before sending.
        func currentAccessToken() async -> AccessToken? {
            tokenStore.retrieveAccessToken()
        }

        // Triggers a token refresh via SessionManager.
        // The SessionManager coalesces concurrent refresh tasks so this is safe to call in parallel.
        // If refresh fails (expired refresh token, network error), the error propagates up
        // to NetworkClient which will throw NetworkError.unauthorized to the caller.
        func refreshToken() async throws -> AccessToken {
            do {
                let token = try await sessionManager.refreshAccessToken()
                logger.info("Interceptor: token refreshed successfully")
                return token
            } catch AuthError.invalidRefreshToken {
                logger.warn("Interceptor: refresh token invalid — session expired")
                throw NetworkError.unauthorized
            } catch AuthError.tokenExpired {
                logger.warn("Interceptor: refresh token expired — user must re-authenticate")
                throw NetworkError.unauthorized
            } catch {
                logger.error("Interceptor: refresh failed with \\(error)")
                throw error
            }
        }

        // Returns true if the current access token is within the proactive refresh window.
        // This can be used by background tasks to pre-emptively refresh before the token expires.
        var shouldProactivelyRefresh: Bool {
            guard let token = tokenStore.retrieveAccessToken() else { return false }
            return token.expiresWithin(60) // refresh if < 60 seconds left
        }
    }
    """

    // MARK: - Sources/Network/RequestBuilder.swift

    static let requestBuilder = """
    import Foundation

    enum RequestBuilder {

        // Builds a URLRequest from an APIEndpoint descriptor.
        static func build(endpoint: APIEndpoint, baseURL: URL) throws -> URLRequest {
            var components = URLComponents(
                url: baseURL.appendingPathComponent(endpoint.path),
                resolvingAgainstBaseURL: true
            )
            if !endpoint.queryItems.isEmpty {
                components?.queryItems = endpoint.queryItems
            }
            guard let url = components?.url else { throw NetworkError.invalidResponse }

            var request = URLRequest(url: url)
            request.httpMethod      = endpoint.method
            request.httpBody        = endpoint.body
            request.timeoutInterval = 30
            request.cachePolicy     = .reloadIgnoringLocalCacheData

            // Default headers
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("MyApp/1.0 (macOS)",  forHTTPHeaderField: "User-Agent")
            if endpoint.body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            // Per-endpoint header overrides
            for (key, value) in endpoint.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            return request
        }

        // Encodes an Encodable value to JSON Data with sorted keys and ISO 8601 dates.
        static func jsonBody<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting     = [.sortedKeys]
            return try encoder.encode(value)
        }

        // Creates a GET endpoint with query parameters from a dictionary.
        static func get(_ path: String, query: [String: String] = [:]) -> APIEndpoint {
            APIEndpoint(
                method: "GET",
                path:   path,
                queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }
            )
        }

        // Creates a POST endpoint with a JSON-encoded body.
        static func post<T: Encodable>(_ path: String, body: T) throws -> APIEndpoint {
            APIEndpoint(method: "POST", path: path, body: try jsonBody(body))
        }

        // Creates a PATCH endpoint with a partial JSON update body.
        static func patch<T: Encodable>(_ path: String, body: T) throws -> APIEndpoint {
            APIEndpoint(method: "PATCH", path: path, body: try jsonBody(body))
        }

        // Creates a DELETE endpoint.
        static func delete(_ path: String) -> APIEndpoint {
            APIEndpoint(method: "DELETE", path: path)
        }
    }
    """

    // MARK: - Sources/Network/ResponseParser.swift

    static let responseParser = """
    import Foundation

    // ResponseParser handles JSON → Swift type decoding with structured error reporting.
    enum ResponseParser {

        private static let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            d.keyDecodingStrategy  = .convertFromSnakeCase
            return d
        }()

        // Decodes raw Data into a Decodable type. Wraps decoding errors with file/line context.
        static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            do {
                return try decoder.decode(T.self, from: data)
            } catch let err as DecodingError {
                throw NetworkError.decodingFailed(describe(err))
            }
        }

        // Attempts to parse an API error envelope from a non-2xx response body.
        static func parseErrorEnvelope(_ data: Data) -> APIErrorEnvelope? {
            try? decoder.decode(APIErrorEnvelope.self, from: data)
        }

        // Produces a human-readable description of a DecodingError for logging.
        private static func describe(_ error: DecodingError) -> String {
            switch error {
            case .keyNotFound(let key, let ctx):
                return "Key '\\(key.stringValue)' not found at \\(ctx.codingPath.map(\\.stringValue).joined(separator: "."))"
            case .typeMismatch(let type, let ctx):
                return "Type mismatch: expected \\(type) at \\(ctx.codingPath.map(\\.stringValue).joined(separator: "."))"
            case .valueNotFound(let type, let ctx):
                return "Value not found: \\(type) at \\(ctx.codingPath.map(\\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let ctx):
                return "Data corrupted: \\(ctx.debugDescription)"
            @unknown default:
                return error.localizedDescription
            }
        }
    }

    struct APIErrorEnvelope: Decodable {
        let error:   String
        let message: String
        let code:    Int?
    }
    """

    // MARK: - Sources/Network/APIEndpoints.swift

    static let apiEndpoints = """
    import Foundation

    // Centralised API endpoint definitions. All path strings live here — no magic strings elsewhere.
    enum API {

        // MARK: - Auth

        enum Auth {
            static func login(email: String, password: String) throws -> APIEndpoint {
                try RequestBuilder.post("/auth/login", body: ["email": email, "password": password])
            }
            static func logout() -> APIEndpoint {
                RequestBuilder.delete("/auth/session")
            }
            static func refreshToken(_ token: String) throws -> APIEndpoint {
                try RequestBuilder.post("/auth/refresh", body: ["refresh_token": token])
            }
            static func verifyEmail(token: String) -> APIEndpoint {
                RequestBuilder.get("/auth/verify-email", query: ["token": token])
            }
            static func requestPasswordReset(email: String) throws -> APIEndpoint {
                try RequestBuilder.post("/auth/password-reset", body: ["email": email])
            }
        }

        // MARK: - Users

        enum Users {
            static func me() -> APIEndpoint {
                RequestBuilder.get("/users/me")
            }
            static func update(userId: UUID, displayName: String) throws -> APIEndpoint {
                try RequestBuilder.patch("/users/\\(userId)", body: ["display_name": displayName])
            }
            static func list(role: UserRole? = nil, page: Int = 1) -> APIEndpoint {
                var query: [String: String] = ["page": String(page)]
                if let role { query["role"] = role.rawValue }
                return RequestBuilder.get("/users", query: query)
            }
            static func delete(userId: UUID) -> APIEndpoint {
                RequestBuilder.delete("/users/\\(userId)")
            }
        }

        // MARK: - Projects

        enum Projects {
            static func list() -> APIEndpoint {
                RequestBuilder.get("/projects")
            }
            static func get(id: UUID) -> APIEndpoint {
                RequestBuilder.get("/projects/\\(id)")
            }
            static func create(name: String, slug: String) throws -> APIEndpoint {
                try RequestBuilder.post("/projects", body: ["name": name, "slug": slug])
            }
            static func update(id: UUID, name: String) throws -> APIEndpoint {
                try RequestBuilder.patch("/projects/\\(id)", body: ["name": name])
            }
            static func delete(id: UUID) -> APIEndpoint {
                RequestBuilder.delete("/projects/\\(id)")
            }
            static func members(id: UUID) -> APIEndpoint {
                RequestBuilder.get("/projects/\\(id)/members")
            }
        }

        // MARK: - Documents

        enum Documents {
            static func list(projectId: UUID) -> APIEndpoint {
                RequestBuilder.get("/projects/\\(projectId)/documents")
            }
            static func get(id: UUID) -> APIEndpoint {
                RequestBuilder.get("/documents/\\(id)")
            }
            static func create(projectId: UUID, title: String, content: String) throws -> APIEndpoint {
                try RequestBuilder.post("/projects/\\(projectId)/documents",
                    body: ["title": title, "content": content])
            }
            static func update(id: UUID, content: String) throws -> APIEndpoint {
                try RequestBuilder.patch("/documents/\\(id)", body: ["content": content])
            }
        }

        // MARK: - Sync

        enum Sync {
            static func diff(since cursor: String) -> APIEndpoint {
                RequestBuilder.get("/sync/diff", query: ["since": cursor])
            }
            static func push(changes: [String: Any]) throws -> APIEndpoint {
                let data = try JSONSerialization.data(withJSONObject: changes)
                return APIEndpoint(method: "POST", path: "/sync/push", body: data)
            }
            static func cursor() -> APIEndpoint {
                RequestBuilder.get("/sync/cursor")
            }
        }
    }
    """

    // MARK: - Sources/Models/User.swift

    static let userModel = """
    import Foundation

    struct User: Identifiable, Codable, Hashable {
        let id:        UUID
        var email:     String
        var displayName: String
        var role:      UserRole
        var createdAt: Date
        var updatedAt: Date
        var lastActiveAt: Date?
        var isEmailVerified: Bool
        var avatarURL:   URL?
        var preferences: UserPreferences

        init(
            id:          UUID         = UUID(),
            email:       String,
            displayName: String,
            role:        UserRole     = .viewer
        ) {
            self.id              = id
            self.email           = email
            self.displayName     = displayName
            self.role            = role
            self.createdAt       = Date()
            self.updatedAt       = Date()
            self.lastActiveAt    = nil
            self.isEmailVerified = false
            self.avatarURL       = nil
            self.preferences     = UserPreferences()
        }

        var isAdmin: Bool { role == .admin }
        var isGuest: Bool { role == .guest }

        var initials: String {
            displayName
                .components(separatedBy: " ")
                .compactMap { $0.first }
                .prefix(2)
                .map(String.init)
                .joined()
                .uppercased()
        }

        // Returns true if the user has not been active for more than threshold seconds.
        func isInactive(threshold: TimeInterval = 30 * 24 * 3600) -> Bool {
            guard let last = lastActiveAt else { return true }
            return Date().timeIntervalSince(last) > threshold
        }
    }

    struct UserPreferences: Codable, Hashable {
        var theme:            String = "system"
        var notificationsEnabled: Bool = true
        var language:         String = "en"
        var timezone:         String = "UTC"
    }

    enum UserRole: String, Codable, CaseIterable {
        case admin, editor, viewer, guest

        var displayName: String {
            switch self {
            case .admin:  return "Administrator"
            case .editor: return "Editor"
            case .viewer: return "Viewer"
            case .guest:  return "Guest"
            }
        }

        var canEdit: Bool { self == .admin || self == .editor }
        var canAdmin: Bool { self == .admin }
    }
    """

    // MARK: - Sources/Models/AccessToken.swift

    static let accessTokenModel = """
    import Foundation

    struct AccessToken: Codable {
        let rawValue:  String
        let expiresAt: Date
        let userId:    UUID

        var isExpired: Bool {
            expiresAt <= Date()
        }

        var remainingTTL: TimeInterval {
            max(0, expiresAt.timeIntervalSinceNow)
        }

        // Returns true if the token will expire within the given window.
        // Used by SessionManager and TokenRefreshInterceptor to decide proactive refresh.
        func expiresWithin(_ window: TimeInterval) -> Bool {
            remainingTTL < window
        }
    }

    struct StoredRefreshToken: Codable {
        let token:     String
        let userId:    UUID
        let expiresAt: Date
        var revokedAt: Date?
        var createdAt: Date

        init(token: String, userId: UUID, expiresAt: Date) {
            self.token     = token
            self.userId    = userId
            self.expiresAt = expiresAt
            self.revokedAt = nil
            self.createdAt = Date()
        }

        var isValid: Bool {
            revokedAt == nil && expiresAt > Date()
        }

        var isRevoked: Bool {
            revokedAt != nil
        }
    }
    """

    // MARK: - Sources/Models/Project.swift

    static let projectModel = """
    import Foundation

    struct Project: Identifiable, Codable, Hashable {
        let id:        UUID
        var name:      String
        var slug:      String
        var ownerId:   UUID
        var createdAt: Date
        var updatedAt: Date
        var isArchived: Bool
        var memberCount: Int
        var documentCount: Int
        var settings: ProjectSettings

        init(id: UUID = UUID(), name: String, ownerId: UUID) {
            self.id            = id
            self.name          = name
            self.slug          = name.lowercased().replacingOccurrences(of: " ", with: "-")
            self.ownerId       = ownerId
            self.createdAt     = Date()
            self.updatedAt     = Date()
            self.isArchived    = false
            self.memberCount   = 1
            self.documentCount = 0
            self.settings      = ProjectSettings()
        }
    }

    struct ProjectSettings: Codable, Hashable {
        var isPublic:       Bool   = false
        var allowGuestView: Bool   = true
        var defaultRole:    String = "viewer"
        var syncEnabled:    Bool   = true
        var retentionDays:  Int    = 365
    }
    """

    // MARK: - Sources/Models/Document.swift

    static let documentModel = """
    import Foundation

    struct Document: Identifiable, Codable, Hashable {
        let id:        UUID
        var title:     String
        var content:   String
        var projectId: UUID
        var authorId:  UUID
        var createdAt: Date
        var updatedAt: Date
        var version:   Int
        var tags:      [String]
        var isLocked:  Bool

        init(id: UUID = UUID(), title: String, content: String, projectId: UUID, authorId: UUID) {
            self.id        = id
            self.title     = title
            self.content   = content
            self.projectId = projectId
            self.authorId  = authorId
            self.createdAt = Date()
            self.updatedAt = Date()
            self.version   = 1
            self.tags      = []
            self.isLocked  = false
        }

        var wordCount: Int {
            content.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .count
        }

        mutating func update(content: String) {
            self.content   = content
            self.updatedAt = Date()
            self.version  += 1
        }
    }
    """

    // MARK: - Sources/Models/Permission.swift

    static let permissionModel = """
    import Foundation

    struct Permission: Codable, Hashable {
        let userId:    UUID
        let projectId: UUID
        var role:      UserRole
        var grantedAt: Date
        var grantedBy: UUID

        init(userId: UUID, projectId: UUID, role: UserRole, grantedBy: UUID) {
            self.userId    = userId
            self.projectId = projectId
            self.role      = role
            self.grantedAt = Date()
            self.grantedBy = grantedBy
        }

        var canRead:   Bool { true }
        var canWrite:  Bool { role == .admin || role == .editor }
        var canDelete: Bool { role == .admin }
        var canManageMembers: Bool { role == .admin }
    }

    struct PermissionCheck {
        let user:    User
        let project: Project

        func can(_ action: Action) -> Bool {
            switch action {
            case .read:          return !project.isArchived || user.role == .admin
            case .write:         return user.role.canEdit
            case .delete:        return user.isAdmin
            case .manageMembers: return user.isAdmin
            case .archive:       return user.isAdmin
            }
        }

        enum Action { case read, write, delete, manageMembers, archive }
    }
    """

    // MARK: - Sources/Database/UserRepository.swift

    static let userRepository = """
    import Foundation

    final class UserRepository {

        private var store:      [UUID:   User] = [:]
        private var emailIndex: [String: UUID] = [:]
        var syncCursor: String? = nil

        // Persists or updates a user. Maintains the email → id index for fast lookups.
        func save(_ user: User) {
            if let existing = store[user.id] {
                emailIndex.removeValue(forKey: existing.email.lowercased())
            }
            store[user.id] = user
            emailIndex[user.email.lowercased()] = user.id
        }

        // O(1) lookup by primary key.
        func findByID(_ id: UUID) -> User? {
            store[id]
        }

        // O(1) lookup by email via the email index. Normalises to lowercase before lookup.
        func findByEmail(_ email: String) -> User? {
            guard let id = emailIndex[email.lowercased()] else { return nil }
            return store[id]
        }

        // Throws if used from AuthService — matches the protocol signature.
        func findByID(_ id: UUID) throws -> User? {
            store[id]
        }

        // Soft-delete: replaces PII with placeholder values. Does not remove the record.
        func anonymize(_ id: UUID) {
            guard var user = store[id] else { return }
            emailIndex.removeValue(forKey: user.email.lowercased())
            user.email       = "deleted-\\(id.uuidString)@deleted.invalid"
            user.displayName = "Deleted User"
            user.role        = .guest
            user.avatarURL   = nil
            store[id] = user
        }

        // Returns all users with the given role, sorted alphabetically by displayName.
        func findAll(role: UserRole) -> [User] {
            store.values
                .filter { $0.role == role }
                .sorted { $0.displayName < $1.displayName }
        }

        // Returns all users, sorted by most recent activity descending.
        func findAllByActivity() -> [User] {
            store.values.sorted {
                ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
            }
        }

        // Updates the lastActiveAt timestamp — called by the sync engine after each cycle.
        func touchActivity(_ id: UUID, at date: Date = Date()) {
            store[id]?.lastActiveAt = date
        }

        // Returns total count of stored users.
        var count: Int { store.count }
    }
    """

    // MARK: - Sources/Database/ProjectRepository.swift

    static let projectRepository = """
    import Foundation

    final class ProjectRepository {

        private var store:    [UUID:   Project]    = [:]
        private var slugIndex:[String: UUID]        = [:]
        private var memberMap:[UUID:   Set<UUID>]   = [:]  // projectId → userIds

        // Persists a project and updates the slug index.
        func save(_ project: Project) {
            if let existing = store[project.id] {
                slugIndex.removeValue(forKey: existing.slug)
            }
            store[project.id] = project
            slugIndex[project.slug] = project.id
        }

        // O(1) lookup by id.
        func findByID(_ id: UUID) -> Project? { store[id] }

        // O(1) lookup by URL slug.
        func findBySlug(_ slug: String) -> Project? {
            guard let id = slugIndex[slug] else { return nil }
            return store[id]
        }

        // Returns all non-archived projects the user is a member of, sorted by name.
        func findForUser(_ userId: UUID) -> [Project] {
            store.values
                .filter { project in
                    !project.isArchived &&
                    (project.ownerId == userId || (memberMap[project.id]?.contains(userId) ?? false))
                }
                .sorted { $0.name < $1.name }
        }

        // Adds a user as a member of a project.
        func addMember(_ userId: UUID, to projectId: UUID) {
            memberMap[projectId, default: []].insert(userId)
            store[projectId]?.memberCount = memberMap[projectId]?.count ?? 0
        }

        // Removes a user from a project's member list.
        func removeMember(_ userId: UUID, from projectId: UUID) {
            memberMap[projectId]?.remove(userId)
            store[projectId]?.memberCount = memberMap[projectId]?.count ?? 0
        }

        // Archives a project — it remains in the store but is excluded from normal queries.
        func archive(_ id: UUID) {
            store[id]?.isArchived = true
        }

        var count: Int { store.count }
    }
    """

    // MARK: - Sources/Database/CacheManager.swift

    static let cacheManager = """
    import Foundation

    // CacheManager provides a simple TTL-based in-memory cache for decoded API responses.
    // Used to avoid redundant network requests for data that changes infrequently (user profile, project list).
    final class CacheManager {

        static let shared = CacheManager()

        private struct Entry {
            let value:     Any
            let expiresAt: Date
            var isValid: Bool { expiresAt > Date() }
        }

        private var cache: [String: Entry] = [:]
        private let lock = NSLock()

        private init() {}

        // Stores a value with the given TTL. Thread-safe.
        func set(_ value: Any, forKey key: String, ttl: TimeInterval = 300) {
            lock.withLock {
                cache[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
            }
        }

        // Returns a cached value if present and not expired. Thread-safe.
        func get<T>(_ key: String, as type: T.Type) -> T? {
            lock.withLock {
                guard let entry = cache[key], entry.isValid else {
                    cache.removeValue(forKey: key)
                    return nil
                }
                return entry.value as? T
            }
        }

        // Removes a specific cache entry (e.g., after a mutation).
        func invalidate(_ key: String) {
            lock.withLock { cache.removeValue(forKey: key) }
        }

        // Removes all entries matching a key prefix (e.g., "projects/" to invalidate all project caches).
        func invalidatePrefix(_ prefix: String) {
            lock.withLock {
                cache = cache.filter { !$0.key.hasPrefix(prefix) }
            }
        }

        // Removes all expired entries. Call periodically to reclaim memory.
        func evictExpired() {
            lock.withLock {
                cache = cache.filter { $0.value.isValid }
            }
        }

        var count: Int { lock.withLock { cache.count } }
    }
    """

    // MARK: - Sources/Database/MigrationRunner.swift

    static let migrationRunner = """
    import Foundation

    // MigrationRunner applies versioned schema migrations to the local store.
    // Migrations run in order and are idempotent — safe to run on each launch.
    // The applied version is persisted in UserDefaults under "db_schema_version".
    final class MigrationRunner {

        struct Migration {
            let version:     Int
            let description: String
            let up:          () throws -> Void
        }

        private let migrations: [Migration]
        private let versionKey = "db_schema_version"
        private let logger:     Logger

        init(migrations: [Migration], logger: Logger = .shared) {
            self.migrations = migrations.sorted { $0.version < $1.version }
            self.logger     = logger
        }

        // Applies all pending migrations in order. Returns the number of migrations applied.
        @discardableResult
        func run() throws -> Int {
            let currentVersion = UserDefaults.standard.integer(forKey: versionKey)
            let pending = migrations.filter { $0.version > currentVersion }
            guard !pending.isEmpty else {
                logger.debug("Schema is up-to-date at version \\(currentVersion)")
                return 0
            }
            logger.info("Running \\(pending.count) pending migration(s) from version \\(currentVersion)")
            for migration in pending {
                logger.info("Applying migration v\\(migration.version): \\(migration.description)")
                try migration.up()
                UserDefaults.standard.set(migration.version, forKey: versionKey)
            }
            logger.info("Schema now at version \\(pending.last!.version)")
            return pending.count
        }

        var currentVersion: Int {
            UserDefaults.standard.integer(forKey: versionKey)
        }

        var latestVersion: Int {
            migrations.last?.version ?? 0
        }

        var isUpToDate: Bool {
            currentVersion >= latestVersion
        }
    }
    """

    // MARK: - Sources/Sync/SyncEngine.swift

    static let syncEngine = """
    import Foundation

    // SyncEngine runs a continuous background poll loop that fetches remote changes
    // and applies them locally using a CRDT last-write-wins merge strategy.
    // The engine respects a configurable poll interval and backs off on errors.
    final class SyncEngine {

        private let networkClient:  NetworkClient
        private let userRepository: UserRepository
        private let changeTracker:  ChangeTracker
        private let conflictResolver: ConflictResolver
        private var syncTask:       Task<Void, Never>?
        private var consecutiveErrors = 0
        private let maxBackoffInterval: TimeInterval = 300  // 5 minutes max backoff
        private(set) var isRunning = false
        private(set) var lastSyncAt: Date? = nil
        private let pollInterval: TimeInterval
        private let logger: Logger

        init(
            networkClient:   NetworkClient,
            userRepository:  UserRepository,
            changeTracker:   ChangeTracker,
            conflictResolver: ConflictResolver,
            pollInterval:    TimeInterval = 30,
            logger:          Logger       = .shared
        ) {
            self.networkClient   = networkClient
            self.userRepository  = userRepository
            self.changeTracker   = changeTracker
            self.conflictResolver = conflictResolver
            self.pollInterval    = pollInterval
            self.logger          = logger
        }

        // Starts the background sync loop. Idempotent — safe to call multiple times.
        func start() {
            guard !isRunning else { return }
            isRunning = true
            logger.info("SyncEngine started with \\(pollInterval)s poll interval")

            syncTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    await self?.syncCycle()
                    let interval = await self?.effectivePollInterval ?? 30
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                await MainActor.run { self?.isRunning = false }
            }
        }

        // Stops the sync loop and waits for any in-progress cycle to complete.
        func stop() async {
            syncTask?.cancel()
            await syncTask?.value
            syncTask = nil
            isRunning = false
            logger.info("SyncEngine stopped")
        }

        // Forces an immediate sync outside the normal poll cycle. Used after a push.
        func syncNow() async {
            await syncCycle()
        }

        // Runs one complete sync cycle: fetch diff → apply changes → push local mutations.
        private func syncCycle() async {
            do {
                let diff = try await fetchRemoteDiff()
                var appliedCount = 0
                for change in diff.changes {
                    try await applyChange(change)
                    appliedCount += 1
                }
                // Push any locally queued changes
                let pending = changeTracker.pendingChanges()
                if !pending.isEmpty {
                    try await pushLocalChanges(pending)
                    changeTracker.markSynced(pending)
                }
                consecutiveErrors = 0
                lastSyncAt = Date()
                if appliedCount > 0 {
                    logger.debug("Sync cycle: applied \\(appliedCount) remote changes, pushed \\(pending.count) local")
                }
            } catch {
                consecutiveErrors += 1
                logger.warn("Sync cycle failed (attempt \\(consecutiveErrors)): \\(error)")
            }
        }

        // Backoff interval grows exponentially with consecutive errors, capped at maxBackoffInterval.
        private var effectivePollInterval: TimeInterval {
            guard consecutiveErrors > 0 else { return pollInterval }
            let backoff = pollInterval * pow(2.0, Double(min(consecutiveErrors, 8)))
            return min(backoff, maxBackoffInterval)
        }

        private func fetchRemoteDiff() async throws -> RemoteDiff {
            let cursor   = userRepository.syncCursor ?? "0"
            let endpoint = API.Sync.diff(since: cursor)
            return try await networkClient.send(endpoint, as: RemoteDiff.self)
        }

        // Applies a single remote change, delegating conflict detection to ConflictResolver.
        private func applyChange(_ change: RemoteChange) async throws {
            let local = userRepository.findByID(change.userId)
            if let local {
                let resolved = conflictResolver.resolve(local: local, remote: change)
                userRepository.save(resolved)
            } else {
                let newUser = User(id: change.userId, email: change.email, displayName: change.displayName)
                userRepository.save(newUser)
            }
        }

        private func pushLocalChanges(_ changes: [LocalChange]) async throws {
            let payload = changes.reduce(into: [String: Any]()) { dict, change in
                dict[change.id.uuidString] = change.payload
            }
            try await networkClient.sendVoid(API.Sync.push(changes: payload))
        }
    }

    struct RemoteDiff: Decodable {
        let changes: [RemoteChange]
        let cursor:  String
    }

    struct RemoteChange: Decodable {
        let userId:      UUID
        let email:       String
        let displayName: String
        let updatedAt:   Date?
    }
    """

    // MARK: - Sources/Sync/ConflictResolver.swift

    static let conflictResolver = """
    import Foundation

    // ConflictResolver applies last-write-wins (LWW) merge semantics on a per-field basis.
    // This is a simple CRDT-compatible strategy: whichever write has the later timestamp wins.
    // For fields without a timestamp, remote always wins (server is source of truth).
    struct ConflictResolver {

        // Resolves a conflict between a local User record and a remote change.
        // Returns the merged record that should be persisted.
        func resolve(local: User, remote: RemoteChange) -> User {
            var merged = local

            if let remoteTs = remote.updatedAt, let localTs = local.updatedAt {
                if remoteTs > localTs {
                    // Remote is newer — apply remote values for mutable fields
                    merged.email       = remote.email
                    merged.displayName = remote.displayName
                    merged.updatedAt   = remoteTs
                }
                // If local is newer, keep local values (local mutations will be pushed next cycle)
            } else {
                // No local timestamp — remote wins unconditionally
                merged.email       = remote.email
                merged.displayName = remote.displayName
                if let remoteTs = remote.updatedAt { merged.updatedAt = remoteTs }
            }
            return merged
        }

        // Resolves a conflict for a text field using a character-level LCS diff.
        // Returns the merged string or the remote version if they diverged irreconcilably.
        func resolveText(base: String, local: String, remote: String) -> String {
            // Three-way merge: if local == base, remote wins; if remote == base, local wins
            if local == base  { return remote }
            if remote == base { return local }
            // Both diverged from base — last-write-wins (remote)
            return remote
        }
    }
    """

    // MARK: - Sources/Sync/ChangeTracker.swift

    static let changeTracker = """
    import Foundation

    // ChangeTracker records local mutations that have not yet been synced to the server.
    // It ensures that local changes made while offline are not lost and are pushed on reconnect.
    final class ChangeTracker {

        struct LocalChange: Identifiable {
            let id:        UUID
            let entityId:  UUID
            let entityType: String
            let payload:   [String: Any]
            let createdAt: Date
        }

        private var pending: [UUID: LocalChange] = [:]
        private let lock = NSLock()

        // Records a new local mutation. Each change gets a unique ID.
        func record(entityId: UUID, entityType: String, payload: [String: Any]) {
            let change = LocalChange(
                id:         UUID(),
                entityId:   entityId,
                entityType: entityType,
                payload:    payload,
                createdAt:  Date()
            )
            lock.withLock { pending[change.id] = change }
        }

        // Returns all currently pending changes, sorted by creation time.
        func pendingChanges() -> [LocalChange] {
            lock.withLock {
                pending.values.sorted { $0.createdAt < $1.createdAt }
            }
        }

        // Removes the given changes from the pending queue after successful sync.
        func markSynced(_ changes: [LocalChange]) {
            lock.withLock {
                for change in changes { pending.removeValue(forKey: change.id) }
            }
        }

        var hasPendingChanges: Bool {
            lock.withLock { !pending.isEmpty }
        }

        var pendingCount: Int {
            lock.withLock { pending.count }
        }
    }

    typealias LocalChange = ChangeTracker.LocalChange
    """

    // MARK: - Sources/Services/NotificationService.swift

    static let notificationService = """
    import Foundation

    // NotificationService manages push notification registration and delivery.
    // Device tokens are registered with the server and kept in sync with the current user session.
    final class NotificationService {

        private let networkClient: NetworkClient
        private let logger:        Logger
        private var deviceToken:   String?

        init(networkClient: NetworkClient, logger: Logger = .shared) {
            self.networkClient = networkClient
            self.logger        = logger
        }

        // Registers a new APNs device token with the backend.
        // Called from the AppDelegate when a new push token is received.
        func registerDeviceToken(_ tokenData: Data, userId: UUID) async throws {
            let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
            deviceToken = tokenString
            let body: [String: String] = ["token": tokenString, "platform": "apns", "userId": userId.uuidString]
            let endpoint = APIEndpoint(method: "POST", path: "/notifications/register", body: try RequestBuilder.jsonBody(body))
            try await networkClient.sendVoid(endpoint)
            logger.info("Push token registered for user \\(userId)")
        }

        // Unregisters the current device token on logout.
        func unregisterDeviceToken(userId: UUID) async throws {
            guard let token = deviceToken else { return }
            let body: [String: String] = ["token": token, "userId": userId.uuidString]
            let endpoint = APIEndpoint(method: "DELETE", path: "/notifications/register", body: try RequestBuilder.jsonBody(body))
            try await networkClient.sendVoid(endpoint)
            deviceToken = nil
            logger.info("Push token unregistered for user \\(userId)")
        }

        // Updates notification preferences for the current user.
        func updatePreferences(_ prefs: NotificationPreferences, userId: UUID) async throws {
            let endpoint = try RequestBuilder.patch("/users/\\(userId)/notification-preferences", body: prefs)
            try await networkClient.sendVoid(endpoint)
        }
    }

    struct NotificationPreferences: Codable {
        var mentionsEnabled:  Bool = true
        var commentsEnabled:  Bool = true
        var updatesEnabled:   Bool = false
        var digestEnabled:    Bool = true
        var quietHoursStart:  Int  = 22
        var quietHoursEnd:    Int  = 8
    }
    """

    // MARK: - Sources/Services/AnalyticsService.swift

    static let analyticsService = """
    import Foundation

    // AnalyticsService tracks user interactions for product analytics.
    // Events are batched and flushed to the server every 30 seconds or when the batch is full.
    // No PII is sent — only anonymised event names and properties.
    final class AnalyticsService {

        static let shared = AnalyticsService()

        private var queue:     [AnalyticsEvent] = []
        private var flushTask: Task<Void, Never>?
        private var userId:    UUID?
        private let batchSize  = 50
        private let flushInterval: TimeInterval = 30
        private let logger: Logger

        private init(logger: Logger = .shared) {
            self.logger = logger
        }

        // Identifies the current user for session attribution. Call after login.
        func identify(userId: UUID) {
            self.userId = userId
            track("session_start", properties: ["user_id": userId.uuidString])
        }

        // Resets the identity on logout.
        func reset() {
            track("session_end", properties: [:])
            userId = nil
        }

        // Enqueues an analytics event. Automatically flushes if the batch is full.
        func track(_ name: String, properties: [String: Any] = [:]) {
            let event = AnalyticsEvent(
                name:       name,
                userId:     userId?.uuidString,
                properties: properties,
                timestamp:  Date()
            )
            queue.append(event)
            if queue.count >= batchSize { Task { await flush() } }
        }

        // Flushes all queued events to the analytics endpoint.
        // Safe to call concurrently — only one flush runs at a time.
        func flush() async {
            guard !queue.isEmpty else { return }
            let batch = queue
            queue.removeAll()
            logger.debug("Analytics: flushing \\(batch.count) events")
            // In production, POST to analytics endpoint; omitted here for test environment
        }
    }

    struct AnalyticsEvent: Codable {
        let name:       String
        let userId:     String?
        let properties: [String: String]
        let timestamp:  Date

        init(name: String, userId: String?, properties: [String: Any], timestamp: Date) {
            self.name       = name
            self.userId     = userId
            self.properties = properties.mapValues { String(describing: $0) }
            self.timestamp  = timestamp
        }
    }
    """

    // MARK: - Sources/Utils/Logger.swift

    static let logger = """
    import Foundation

    // Structured logger with log levels and optional prefix filtering.
    // In DEBUG builds, all levels are printed. In RELEASE, only warn and above.
    final class Logger {

        static let shared = Logger()

        enum Level: Int, Comparable {
            case debug = 0, info = 1, warn = 2, error = 3
            static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
            var label: String {
                switch self { case .debug: return "DEBUG"; case .info: return "INFO ";
                              case .warn:  return "WARN "; case .error: return "ERROR" }
            }
        }

        var minimumLevel: Level = {
            #if DEBUG
            return .debug
            #else
            return .warn
            #endif
        }()

        var prefix: String = "MyApp"

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        func debug(_ message: String, file: String = #file, line: Int = #line) {
            log(.debug, message, file: file, line: line)
        }

        func info(_ message: String, file: String = #file, line: Int = #line) {
            log(.info, message, file: file, line: line)
        }

        func warn(_ message: String, file: String = #file, line: Int = #line) {
            log(.warn, message, file: file, line: line)
        }

        func error(_ message: String, file: String = #file, line: Int = #line) {
            log(.error, message, file: file, line: line)
        }

        private func log(_ level: Level, _ message: String, file: String, line: Int) {
            guard level >= minimumLevel else { return }
            let filename = URL(fileURLWithPath: file).lastPathComponent
            let timestamp = dateFormatter.string(from: Date())
            print("[\\(timestamp)] [\\(level.label)] [\\(filename):\\(line)] \\(message)")
        }
    }
    """

    // MARK: - Sources/Utils/Keychain.swift

    static let keychain = """
    import Foundation
    import Security

    // KeychainWrapper provides a simple typed interface over the macOS/iOS Keychain API.
    // All items are stored with kSecAttrService = bundle identifier for isolation.
    final class KeychainWrapper {

        static let shared = KeychainWrapper()

        private let service: String

        init(service: String = Bundle.main.bundleIdentifier ?? "com.myapp") {
            self.service = service
        }

        // Stores a string value. Overwrites any existing value for the same key.
        func set(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            // Delete any existing item first to allow update
            let deleteQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String:            kSecClassGenericPassword,
                kSecAttrService as String:      service,
                kSecAttrAccount as String:      key,
                kSecValueData as String:        data,
                kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.writeFailed(status) }
        }

        // Retrieves a string value, or nil if not found.
        func get(_ key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String:  true,
                kSecMatchLimit as String:  kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // Deletes a stored value.
        func delete(_ key: String) throws {
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.deleteFailed(status)
            }
        }
    }

    enum KeychainError: Error {
        case encodingFailed, writeFailed(OSStatus), deleteFailed(OSStatus)
    }
    """

    // MARK: - Sources/Config/AppConfig.swift

    static let appConfig = """
    import Foundation

    // AppConfig reads build-time and runtime configuration from Info.plist and environment.
    // All app-wide constants live here — no magic strings scattered across the codebase.
    struct AppConfig {

        static let shared = AppConfig()

        // API base URL — overridable via MYAPP_API_URL environment variable for testing.
        var apiBaseURL: URL {
            if let override = ProcessInfo.processInfo.environment["MYAPP_API_URL"],
               let url = URL(string: override) { return url }
            let urlString = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
                ?? "https://api.myapp.io/v1"
            return URL(string: urlString)!
        }

        // Feature flags loaded from remote config. Defaults to safe values.
        var featureFlags: FeatureFlags = .defaults

        var isDebugBuild: Bool {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }

        var appVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        }

        var buildNumber: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        }
    }

    struct FeatureFlags: Codable {
        var syncEnabled:       Bool = true
        var oauthEnabled:      Bool = false
        var analyticsEnabled:  Bool = true
        var offlineModeEnabled: Bool = true
        var betaFeaturesEnabled: Bool = false

        static let defaults = FeatureFlags()
    }
    """

    // MARK: - Tests/AuthServiceTests.swift

    static let authServiceTests = """
    import Foundation

    struct AuthServiceTests {

        func testGenerateAccessTokenProducesValidJWT() throws {
            let sut   = makeAuthService()
            let user  = makeUser()
            let token = try sut.generateAccessToken(for: user)
            let parts = token.rawValue.components(separatedBy: ".")
            assert(parts.count == 3, "JWT must have exactly 3 dot-separated parts")
            assert(!token.isExpired, "Freshly generated token must not be expired")
            assert(token.userId == user.id)
        }

        func testValidateAccessTokenReturnsCorrectPayload() throws {
            let sut     = makeAuthService()
            let user    = makeUser()
            let token   = try sut.generateAccessToken(for: user)
            let payload = try sut.validateAccessToken(token.rawValue)
            assert(payload.sub  == user.id.uuidString)
            assert(payload.role == user.role.rawValue)
            assert(payload.email == user.email)
        }

        func testValidateAccessTokenThrowsOnTamperedSignature() throws {
            let sut     = makeAuthService()
            let user    = makeUser()
            let token   = try sut.generateAccessToken(for: user)
            let tampered = String(token.rawValue.dropLast(4)) + "xxxx"
            var threw = false
            do { _ = try sut.validateAccessToken(tampered) }
            catch AuthError.invalidSignature { threw = true }
            assert(threw, "Tampered JWT must throw .invalidSignature")
        }

        func testRotateRefreshTokenIssuesNewPair() throws {
            let sut      = makeAuthService()
            let user     = makeUser()
            let refresh1 = try sut.generateRefreshToken(for: user)
            let (access2, refresh2) = try sut.rotateRefreshToken(refresh1)
            assert(!access2.isExpired)
            assert(!refresh2.isEmpty)
            assert(refresh1 != refresh2, "Rotated refresh token must be different")
        }

        func testRotateRefreshTokenRevokesOldToken() throws {
            let sut      = makeAuthService()
            let user     = makeUser()
            let refresh  = try sut.generateRefreshToken(for: user)
            _            = try sut.rotateRefreshToken(refresh)
            // Attempting to rotate the same token again must fail
            var threw = false
            do { _ = try sut.rotateRefreshToken(refresh) }
            catch { threw = true }
            assert(threw, "Already-rotated token must not be reusable")
        }

        func testRevokeAllTokensInvalidatesRefreshToken() throws {
            let sut     = makeAuthService()
            let user    = makeUser()
            let refresh = try sut.generateRefreshToken(for: user)
            try sut.revokeAllTokens(for: user.id)
            var threw = false
            do { _ = try sut.rotateRefreshToken(refresh) }
            catch { threw = true }
            assert(threw, "Revoked refresh token must not produce a new pair")
        }

        func testShouldRefreshProactivelyReturnsTrueNearExpiry() throws {
            // Create a token that expires in 30 seconds
            let sut     = makeAuthService()
            let user    = makeUser()
            let token   = AccessToken(
                rawValue:  "fake.jwt.token",
                expiresAt: Date().addingTimeInterval(30),
                userId:    user.id
            )
            assert(sut.shouldRefreshProactively(token), "Token expiring in 30s should trigger proactive refresh")
        }

        private func makeUser() -> User {
            User(id: UUID(), email: "test@example.com", displayName: "Test User", role: .admin)
        }

        private func makeAuthService() -> AuthService {
            AuthService(
                tokenRepository: InMemoryTokenRepository(),
                userRepository:  UserRepository(),
                secret:          "test-secret-key-minimum-32-bytes!"
            )
        }
    }

    final class InMemoryTokenRepository: TokenRepository {
        private var tokens: [String: StoredRefreshToken] = [:]
        func save(refreshToken: String, userId: UUID, expiresAt: Date) throws {
            tokens[refreshToken] = StoredRefreshToken(token: refreshToken, userId: userId, expiresAt: expiresAt)
        }
        func findRefreshToken(_ token: String) throws -> StoredRefreshToken? { tokens[token] }
        func revokeRefreshToken(_ token: String) throws { tokens[token]?.revokedAt = Date() }
        func revokeAllTokens(userId: UUID) throws {
            for key in tokens.keys where tokens[key]?.userId == userId {
                tokens[key]?.revokedAt = Date()
            }
        }
    }
    """

    // MARK: - Tests/NetworkClientTests.swift

    static let networkClientTests = """
    import Foundation

    struct NetworkClientTests {

        func testRequestBuilderSetsAuthorizationHeader() throws {
            let token    = AccessToken(rawValue: "test.jwt.token", expiresAt: .distantFuture, userId: UUID())
            let endpoint = APIEndpoint(method: "GET", path: "/me")
            let authed   = RequestBuilder.authenticated(endpoint, token: token)
            assert(authed.headers["Authorization"] == "Bearer test.jwt.token")
        }

        func testRequestBuilderEncodesSortedJSONBody() throws {
            struct Payload: Codable { let b: String; let a: Int }
            let data = try RequestBuilder.jsonBody(Payload(b: "hello", a: 42))
            let json = String(data: data, encoding: .utf8)!
            // Sorted keys: 'a' must come before 'b'
            let aIdx = json.range(of: "\\"a\\"")!.lowerBound
            let bIdx = json.range(of: "\\"b\\"")!.lowerBound
            assert(aIdx < bIdx, "Keys must be sorted: 'a' should precede 'b'")
        }

        func testGetEndpointAppendsQueryItems() throws {
            let endpoint = RequestBuilder.get("/users", query: ["role": "admin", "page": "2"])
            let request  = try RequestBuilder.build(endpoint: endpoint, baseURL: URL(string: "https://api.test.io")!)
            let url      = request.url!.absoluteString
            assert(url.contains("role=admin"))
            assert(url.contains("page=2"))
        }

        func testResponseParserDecodesSnakeCaseKeys() throws {
            struct Item: Decodable { let displayName: String }
            let json = #"{"display_name":"Alice"}"#
            let item = try ResponseParser.decode(Item.self, from: Data(json.utf8))
            assert(item.displayName == "Alice")
        }

        func testCacheManagerStoresAndRetrievesValues() {
            let cache = CacheManager.shared
            cache.set("hello", forKey: "test-key", ttl: 60)
            let retrieved = cache.get("test-key", as: String.self)
            assert(retrieved == "hello")
            cache.invalidate("test-key")
        }

        func testCacheManagerInvalidatesPrefixes() {
            let cache = CacheManager.shared
            cache.set("v1", forKey: "projects/1", ttl: 60)
            cache.set("v2", forKey: "projects/2", ttl: 60)
            cache.set("keep", forKey: "users/1",    ttl: 60)
            cache.invalidatePrefix("projects/")
            assert(cache.get("projects/1", as: String.self) == nil)
            assert(cache.get("projects/2", as: String.self) == nil)
            assert(cache.get("users/1",    as: String.self) == "keep")
            cache.invalidate("users/1")
        }
    }
    """

    // MARK: - Tests/SyncEngineTests.swift

    static let syncEngineTests = """
    import Foundation

    struct SyncEngineTests {

        func testConflictResolverPrefersRemoteWhenRemoteIsNewer() {
            let resolver = ConflictResolver()
            var local    = User(id: UUID(), email: "old@example.com", displayName: "Old Name")
            local.updatedAt = Date().addingTimeInterval(-120)  // 2 minutes ago

            let remote = RemoteChange(
                userId:      local.id,
                email:       "new@example.com",
                displayName: "New Name",
                updatedAt:   Date()
            )
            let merged = resolver.resolve(local: local, remote: remote)
            assert(merged.email == "new@example.com", "Remote email should win when remote is newer")
            assert(merged.displayName == "New Name")
        }

        func testConflictResolverKeepsLocalWhenLocalIsNewer() {
            let resolver = ConflictResolver()
            var local    = User(id: UUID(), email: "local@example.com", displayName: "Local Name")
            local.updatedAt = Date()  // just updated locally

            let remote = RemoteChange(
                userId:      local.id,
                email:       "remote@example.com",
                displayName: "Remote Name",
                updatedAt:   Date().addingTimeInterval(-60)  // 1 minute ago
            )
            let merged = resolver.resolve(local: local, remote: remote)
            assert(merged.email == "local@example.com", "Local email should win when local is newer")
        }

        func testChangeTrackerRecordsAndFlushes() {
            let tracker = ChangeTracker()
            let userId  = UUID()
            tracker.record(entityId: userId, entityType: "User", payload: ["email": "test@example.com"])
            assert(tracker.pendingCount == 1)
            assert(tracker.hasPendingChanges)

            let pending = tracker.pendingChanges()
            tracker.markSynced(pending)
            assert(tracker.pendingCount == 0)
            assert(!tracker.hasPendingChanges)
        }

        func testChangeTrackerPreservesInsertionOrder() {
            let tracker = ChangeTracker()
            let ids     = (0..<5).map { _ in UUID() }
            for id in ids {
                tracker.record(entityId: id, entityType: "User", payload: [:])
                Thread.sleep(forTimeInterval: 0.001)  // ensure distinct timestamps
            }
            let pending = tracker.pendingChanges()
            assert(pending.count == 5)
            // Each change should correspond to a user entity
            assert(pending.allSatisfy { $0.entityType == "User" })
        }

        func testUserRepositoryEmailIndexIsUpdatedOnSave() {
            let repo  = UserRepository()
            var user  = User(id: UUID(), email: "alice@example.com", displayName: "Alice")
            repo.save(user)
            assert(repo.findByEmail("alice@example.com") != nil)

            // Update email
            user.email = "alice-new@example.com"
            repo.save(user)
            assert(repo.findByEmail("alice-new@example.com") != nil)
            assert(repo.findByEmail("alice@example.com") == nil, "Old email index entry must be removed")
        }

        func testUserRepositoryAnonymize() {
            let repo = UserRepository()
            let user = User(id: UUID(), email: "pii@example.com", displayName: "Real Name")
            repo.save(user)
            repo.anonymize(user.id)
            let anon = repo.findByID(user.id)!
            assert(anon.email.contains("deleted"), "Anonymized email must contain 'deleted'")
            assert(anon.displayName == "Deleted User")
            assert(anon.role == .guest)
            assert(repo.findByEmail("pii@example.com") == nil, "PII email must be removed from index")
        }
    }
    """
}
