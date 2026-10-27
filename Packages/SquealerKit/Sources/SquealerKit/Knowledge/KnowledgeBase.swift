import Foundation

/// A small offline reference that explains common servers and macOS processes, so alerts can say *what* an app is
/// talking to without sending anything to a lookup service.
public enum KnowledgeBase {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case analytics
        case advertising
        case crashReporting
        case logging
        case featureFlags
        case cdn
        case cloud
        case payments
        case authentication
        case updates
        case messaging
        case collaboration
        case ai
        case maps
        case media
        case developer
        case security
        case platform

        /// Categories most people would rather block.
        public var isTracking: Bool {
            self == .analytics || self == .advertising
        }
    }

    public struct Service: Sendable, Hashable {
        public var name: String
        public var category: Category

        init(_ name: String, _ category: Category) {
            self.name = name
            self.category = category
        }
    }

    public static func service(for hostname: String) -> Service? {
        var suffix = Substring(hostname.lowercased())
        while true {
            if let service = services[String(suffix)] { return service }
            guard let dot = suffix.firstIndex(of: ".") else { return nil }
            suffix = suffix[suffix.index(after: dot)...]
        }
    }

    /// What a macOS system process does, in a sentence.
    public static func processDescription(signingID: String?) -> String? {
        guard let signingID else { return nil }
        return processes[signingID] ?? processes[String(signingID.split(separator: ".").last ?? "")]
    }

    private static let services: [String: Service] = {
        var table: [String: Service] = [:]
        func add(_ category: Category, _ name: String, _ domains: String...) {
            for domain in domains { table[domain] = Service(name, category) }
        }
        add(.analytics, "Google Analytics", "google-analytics.com", "analytics.google.com", "googletagmanager.com")
        add(.analytics, "Segment", "segment.io", "segment.com", "segmentapis.com")
        add(.analytics, "Amplitude", "amplitude.com")
        add(.analytics, "Mixpanel", "mixpanel.com", "mxpnl.com")
        add(.analytics, "Heap", "heapanalytics.com")
        add(.analytics, "PostHog", "posthog.com", "i.posthog.com")
        add(.analytics, "Hotjar", "hotjar.com", "hotjar.io")
        add(.analytics, "FullStory", "fullstory.com")
        add(.analytics, "Microsoft Clarity", "clarity.ms")
        add(.analytics, "Firebase Analytics", "app-measurement.com", "firebase-settings.crashlytics.com")
        add(.analytics, "Adobe Analytics", "omtrdc.net", "2o7.net", "demdex.net")
        add(.analytics, "Plausible", "plausible.io")
        add(.analytics, "TelemetryDeck", "telemetrydeck.com")
        add(.analytics, "AppsFlyer", "appsflyer.com")
        add(.analytics, "Branch", "branch.io", "app.link")
        add(.analytics, "Pendo", "pendo.io")
        add(.analytics, "Intercom", "intercom.io", "intercomcdn.com")
        add(.advertising, "Google Ads", "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com")
        add(.advertising, "Meta Ads", "facebook.net", "connect.facebook.net")
        add(.advertising, "Criteo", "criteo.com", "criteo.net")
        add(.advertising, "Taboola", "taboola.com")
        add(.advertising, "Outbrain", "outbrain.com")
        add(.advertising, "Amazon Ads", "amazon-adsystem.com")
        add(.advertising, "AppLovin", "applovin.com")
        add(.advertising, "Unity Ads", "unityads.unity3d.com")
        add(.crashReporting, "Sentry", "sentry.io", "ingest.sentry.io", "sentry-cdn.com")
        add(.crashReporting, "Crashlytics", "crashlytics.com")
        add(.crashReporting, "Bugsnag", "bugsnag.com")
        add(.crashReporting, "Raygun", "raygun.io", "raygun.com")
        add(.crashReporting, "Embrace", "embrace.io")
        add(.logging, "Datadog", "datadoghq.com", "datadoghq.eu", "browser-intake-datadoghq.com")
        add(.logging, "New Relic", "newrelic.com", "nr-data.net")
        add(.logging, "Honeycomb", "honeycomb.io")
        add(.logging, "Grafana Cloud", "grafana.net")
        add(.logging, "Splunk", "splunkcloud.com")
        add(.logging, "Elastic", "elastic-cloud.com")
        add(.featureFlags, "LaunchDarkly", "launchdarkly.com")
        add(.featureFlags, "Statsig", "statsig.com", "statsigapi.net")
        add(.featureFlags, "Optimizely", "optimizely.com")
        add(.cdn, "Cloudflare", "cloudflare.com", "cloudflare.net", "cdnjs.cloudflare.com")
        add(.cdn, "Akamai", "akamai.net", "akamaiedge.net", "akamaihd.net", "akamaized.net", "edgekey.net", "edgesuite.net")
        add(.cdn, "Fastly", "fastly.net", "fastlylb.net")
        add(.cdn, "Amazon CloudFront", "cloudfront.net")
        add(.cdn, "jsDelivr", "jsdelivr.net")
        add(.cdn, "unpkg", "unpkg.com")
        add(.cdn, "Google Fonts", "fonts.googleapis.com", "fonts.gstatic.com")
        add(.cloud, "Amazon Web Services", "amazonaws.com", "aws.amazon.com")
        add(.cloud, "Google Cloud", "googleapis.com", "gstatic.com", "googleusercontent.com", "appspot.com")
        add(.cloud, "Microsoft Azure", "azure.com", "azurewebsites.net", "windows.net", "azureedge.net")
        add(.cloud, "Vercel", "vercel.app", "vercel.com")
        add(.cloud, "Netlify", "netlify.app", "netlify.com")
        add(.cloud, "Dropbox", "dropbox.com", "dropboxapi.com", "dropboxusercontent.com")
        add(.cloud, "Box", "box.com", "boxcdn.net")
        add(.payments, "Stripe", "stripe.com", "stripe.network", "stripecdn.com")
        add(.payments, "Paddle", "paddle.com")
        add(.payments, "PayPal", "paypal.com", "paypalobjects.com")
        add(.payments, "Lemon Squeezy", "lemonsqueezy.com")
        add(.authentication, "Okta", "okta.com", "oktacdn.com")
        add(.authentication, "Auth0", "auth0.com")
        add(.authentication, "Microsoft sign-in", "login.microsoftonline.com", "login.live.com")
        add(.authentication, "Google sign-in", "accounts.google.com")
        add(.authentication, "hCaptcha", "hcaptcha.com")
        add(.authentication, "reCAPTCHA", "recaptcha.net")
        add(.security, "1Password", "1password.com", "1passwordservices.com")
        add(.security, "Kandji", "kandji.io")
        add(.security, "Jamf", "jamfcloud.com")
        add(.security, "CrowdStrike", "crowdstrike.com")
        add(.security, "OneTrust (cookie consent)", "onetrust.com", "cookielaw.org")
        add(.security, "PerimeterX (bot protection)", "px-cloud.net", "perimeterx.net")
        add(.security, "Tailscale", "tailscale.com", "tailscale.io")
        add(.updates, "Sparkle update feed (GitHub)", "objects.githubusercontent.com")
        add(.updates, "Homebrew", "formulae.brew.sh", "ghcr.io")
        add(.updates, "Microsoft AutoUpdate", "officecdn.microsoft.com")
        add(.messaging, "Slack", "slack.com", "slack-edge.com", "slack-imgs.com", "slackb.com")
        add(.messaging, "Discord", "discord.com", "discord.gg", "discordapp.com", "discordapp.net")
        add(.messaging, "Zoom", "zoom.us", "zoom.com")
        add(.messaging, "Microsoft Teams", "teams.microsoft.com", "skype.com")
        add(.messaging, "WhatsApp", "whatsapp.net", "whatsapp.com")
        add(.messaging, "Telegram", "telegram.org", "t.me")
        add(.messaging, "Signal", "signal.org")
        add(.messaging, "Superhuman", "superhuman.com")
        add(.collaboration, "Notion", "notion.so", "notion.com")
        add(.collaboration, "Figma", "figma.com")
        add(.collaboration, "Linear", "linear.app")
        add(.collaboration, "Atlassian", "atlassian.com", "atlassian.net", "jira.com")
        add(.collaboration, "Google Workspace", "google.com", "googleapis.com", "clients6.google.com")
        add(.collaboration, "Microsoft 365", "office.com", "office.net", "office365.com", "sharepoint.com")
        add(.collaboration, "Cal.com", "cal.com", "cal.video")
        add(.ai, "Anthropic", "anthropic.com", "claude.ai")
        add(.ai, "OpenAI", "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com")
        add(.ai, "Cursor", "cursor.sh", "cursor.com", "cursor-cdn.com", "cursorvm.com")
        add(.ai, "GitHub Copilot", "githubcopilot.com")
        add(.ai, "Google Gemini", "gemini.google.com", "generativelanguage.googleapis.com")
        add(.ai, "Wispr Flow", "wisprflow.com", "wisprflow.ai")
        add(.maps, "Apple Maps", "ls.apple.com")
        add(.maps, "Google Maps", "maps.googleapis.com")
        add(.maps, "Mapbox", "mapbox.com")
        add(.media, "Spotify", "spotify.com", "scdn.co", "spotifycdn.com")
        add(.media, "YouTube", "youtube.com", "ytimg.com", "googlevideo.com")
        add(.media, "Netflix", "netflix.com", "nflxvideo.net")
        add(.developer, "GitHub", "github.com", "githubusercontent.com", "githubassets.com")
        add(.developer, "GitLab", "gitlab.com")
        add(.developer, "npm", "npmjs.org", "npmjs.com")
        add(.developer, "PyPI", "pypi.org", "pythonhosted.org")
        add(.developer, "Docker Hub", "docker.io", "docker.com")
        add(.developer, "Raycast", "raycast.com")
        add(.developer, "Statuspage", "statuspage.io")
        add(.platform, "Apple", "apple.com", "aaplimg.com", "cdn-apple.com", "mzstatic.com", "apple-dns.net")
        add(.platform, "iCloud", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "me.com")
        add(.platform, "Apple Push Notifications", "push.apple.com")
        add(.platform, "Microsoft", "microsoft.com", "live.com", "msftconnecttest.com")
        return table
    }()

    private static let processes: [String: String] = [
        "com.apple.mDNSResponder": "Resolves host names (DNS) and finds devices on your network (Bonjour) for every app.",
        "com.apple.trustd": "Checks that the certificates websites and apps present are valid and not revoked.",
        "com.apple.nsurlsessiond": "Performs background downloads and uploads on behalf of apps.",
        "com.apple.apsd": "Keeps the connection to Apple's push notification service open so apps can receive notifications.",
        "com.apple.ApplePushService": "Keeps the connection to Apple's push notification service open so apps can receive notifications.",
        "com.apple.softwareupdated": "Checks for and downloads macOS updates.",
        "com.apple.appstoreagent": "Downloads App Store purchases and updates.",
        "com.apple.storedownloadd": "Downloads App Store purchases and updates.",
        "com.apple.bird": "Syncs iCloud Drive.",
        "com.apple.cloudd": "Syncs app data with iCloud through CloudKit.",
        "com.apple.identityservicesd": "Handles iMessage, FaceTime and Continuity identity and keys.",
        "com.apple.imagent": "Sends and receives iMessages.",
        "com.apple.akd": "Manages your Apple Account sign-in.",
        "com.apple.appleaccountd": "Manages your Apple Account and its settings.",
        "com.apple.geod": "Downloads map tiles and location data for Maps and location services.",
        "com.apple.locationd": "Determines your location using Wi-Fi and other signals.",
        "com.apple.timed": "Keeps the clock accurate using network time servers.",
        "com.apple.syspolicyd": "Checks apps with Gatekeeper and notarization before they open.",
        "com.apple.XProtect": "Apple's built-in malware protection, which updates its signatures from Apple.",
        "com.apple.parsecd": "Provides Spotlight and Siri suggestions.",
        "com.apple.CoreParsec": "Provides Spotlight and Siri suggestions.",
        "com.apple.icloud.searchpartyuseragent": "Find My: locates your devices and AirTags.",
        "com.apple.icloud.findmydeviced": "Find My: reports this Mac's location when you look for it.",
        "com.apple.findmy.findmylocateagent": "Find My: shares and fetches locations.",
        "com.apple.rtcreportingd": "Sends FaceTime and real-time communication quality reports to Apple.",
        "com.apple.analyticsd": "Sends diagnostics and usage data to Apple if you've opted in.",
        "com.apple.WebKit.Networking": "Loads web content for Safari and apps that show web pages.",
        "com.apple.configd": "Manages network configuration (Wi-Fi, DHCP, VPN).",
        "com.apple.mobileassetd": "Downloads system assets such as fonts, voices and language models.",
        "com.apple.amsaccountsd": "Handles App Store and Apple Media account requests.",
        "com.apple.commerce": "Handles App Store purchases.",
        "com.apple.sharingd": "Powers AirDrop, Handoff and other Continuity features.",
        "com.apple.rapportd": "Lets your Apple devices discover and talk to each other nearby.",
        "com.apple.AirPlayXPCHelper": "Streams audio and video with AirPlay.",
        "com.apple.netbiosd": "Discovers Windows file servers on your local network.",
        "com.apple.ocspd": "Checks whether certificates have been revoked.",
        "com.apple.siriknowledged": "Keeps Siri's knowledge up to date.",
        "com.apple.assistantd": "Talks to Siri's servers.",
        "com.apple.photoanalysisd": "Analyses your photo library (people, places, memories).",
        "com.apple.cloudphotod": "Syncs iCloud Photos.",
        "com.apple.mediaanalysisd": "Analyses photos and videos for search and Visual Look Up.",
        "com.apple.Safari": "Apple's web browser.",
        "com.apple.mail": "Apple Mail.",
        "com.apple.ctkd": "Handles smart cards and security tokens.",
        "com.apple.ssh": "Secure Shell: remote logins and Git over SSH.",
        "com.apple.curl": "Command-line tool for transferring data from URLs.",
    ]
}
