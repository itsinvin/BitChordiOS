import SwiftUI

// MARK: - App entry: real tab bar + persistent mini-player above it.
// The mini-player sits in a bottom safe-area inset, so it stays above the
// tab bar on every tab and opens the full Now Playing sheet.

@main
struct BitChordApp: App {
    @StateObject private var settings = SettingsStore.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.themeMode == .system ? nil : (settings.themeMode == .dark ? .dark : .light))
                .onOpenURL { url in
                    // Spotify PKCE redirect: bitchord://spotify-callback?code=…
                    if url.scheme == "bitchord", url.host == "spotify-callback",
                       let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value {
                        Task { _ = await SpotifyAccount.shared.exchange(code: code, redirectURI: "bitchord://spotify-callback") }
                    }
                    // Listen Together invite: bitchord.kushagrasingh.in/invite/<CODE>
                    if let code = ListenTogether.parseInviteURL(url.absoluteString) {
                        Task { try? await ListenTogether.shared.joinParty(rawCode: code) }
                    }
                }
        }
    }
}

struct ContentView: View {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var settings = SettingsStore.shared
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            ExploreView()
                .tabItem { Label("Explore", systemImage: "globe") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
            ListenTogetherView()
                .tabItem { Label("Listen Together", systemImage: "person.2.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer()
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }
        .onAppear { settings.applyToPlayer() }
    }
}
