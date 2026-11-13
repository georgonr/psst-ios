// PSST: no analytics, crash reporting, rageshake or MapTiler keys are ever compiled into psst.
// Every value is nil, which disables PostHog, Sentry, bug reports and the bundled map tiles.
nonisolated enum Secrets {
    static let sentryDSN: String? = nil
    static let sentryRustDSN: String? = nil
    static let postHogHost: String? = nil
    static let postHogAPIKey: String? = nil
    static let rageshakeURL: String? = nil
    static let mapLibreAPIKey: String? = nil
}
