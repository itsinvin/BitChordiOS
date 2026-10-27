# BitChord for iOS (SwiftUI port)

An unofficial YouTube Music client, ported from
[kushagrasinghx/BitChord](https://github.com/kushagrasinghx/BitChord) (Android/Kotlin).
The original source is kept read-only at `../original/` for reference; nothing in
this project edits it.

> **This will not pass App Store review** — it is an unofficial YouTube Music
> client, same as the Android APK. Install it the same way: sign with a personal
> team in Xcode and sideload it onto your own device (see "Build" below).

## Build (Xcode, on a Mac — NOT verified on this Linux VM)

No Xcode/Swift toolchain exists on the Linux VM this was written on, so
**on-device Xcode compilation is still required and has not been run.**
The code was written carefully against real APIs only
(SwiftUI + AVFoundation + MediaPlayer-ready + JavaScriptCore-ready, iOS 17+,
`ObservableObject`/`@Published` — no `@Observable` macro confusion), then
mechanically checked for brace balance and TODO stubs in core paths (see
"Mechanical check" below).

1. Open `BitChordIOS.xcodeproj` in Xcode.
2. Select the `BitChordIOS` target → Signing & Capabilities → Team: pick your
   personal team. Xcode will assign a bundle id under it if
   `com.bitchord.ios` is taken; any personal-team id works.
3. Make sure the `audio` background mode is present (it is in `Info.plist`:
   `UIBackgroundModes = audio`, plus `NSAppleMusicUsageDescription` for the
   local library).
4. Add real app-icon images to `Assets.xcassets/AppIcon.appiconset` (the set
   is scaffolded; icon slots are currently empty).
5. Build & run on a physical iPhone (the simulator cannot do background audio
   / AirPlay faithfully). Or Product → Archive → Distribute → Development, and
   sideload the resulting IPA.
6. First launch: sign in to YouTube Music from the account screen (in the full
   port) so Innertube requests carry a session cookie + visitor id; otherwise
   playback is guest-only and ciphered streams will fail honestly (see below).

## What is built so far

| Area | File(s) | Status |
|---|---|---|
| Dynamic JSON for Innertube | `BitChordIOS/BitChordIOS/JSONValue.swift` | Done |
| Models (Track/Artist/Album/Playlist/Shelf/StreamFormat) | `Models.swift` | Done |
| Keychain token store + MD5/SHA helpers | `Keychain.swift` | Done |
| Innertube WEB_REMIX client 67 (`/browse`, `/search`, `/player`, `/next`, visitorData, SAPISIDHASH) | `InnertubeClient.swift` | Done |
| Stream resolution (Opus/AAC, per-network ceilings, cipher error, no faked URLs) | `StreamResolver.swift` | Done |
| Real player engine (AVPlayer, background session, local-first, queue/shuffle-adjacent ops, speed) | `PlayerEngine.swift` | Done |
| **Listen Together, end-to-end** | `ListenTogether.swift`, `ListenTogetherView.swift` | Done (see below) |
| App entry + full tab bar + mini-player | `BitChordApp.swift` | Done — Home / Explore / Search / Library / Listen Together / Settings tabs, mini-player in a bottom safe-area inset opening the full Now Playing sheet |
| Home / Explore / Search / Library / Detail | `HomeViews.swift` | Done — FEmusic_home / FEmusic_explore / FEmusic_library_landing shelves, search filters + history + continuation ("Load more"), artist/album/playlist detail with play-all + shuffle |
| Player upgrades | `PlayerEngine.swift` (surgical; party contract intact) | Done — shuffle, repeat off/all/one, queue history, autoplay via `/next`, dual-AVPlayer crossfade 0–12 s (disabled in a party), Automix mode, speed 0.5–2.0×, trailing-silence skip (see limits), sleep timer (15/30/45/60 min + stop after this track), MPNowPlayingInfoCenter + remote commands, AirPlay picker, stats for nerds (current StreamFormat), listening-history recording |
| Lyrics | `LyricsService.swift`, `NowPlayingView.swift` (LyricsView) | Done — LRCLIB first, then LrcRed / BiniLyrics / LyricsPlus / Unison / PaxSenix (key required) / Megalobiz, synced `[mm:ss.xx]` + `<mm:ss.xx>` word timing, line + word highlighting, offset ±5000 ms, Google-translate translation, provider order, share-as-card image |
| Downloads | `DownloadsStore.swift`, `LibraryViews.swift` (DownloadsView) | Done — URLSession downloads to Documents/BitChord/Downloads + manifest JSON, progress, cancel/delete, offline playback via localURL, downloaded-tracks list |
| Local library | `LocalLibrary.swift`, `LibraryViews.swift` (LocalLibraryView) | Done — MPMediaQuery songs/albums/artists, Files import via UIDocumentPicker (copied to Documents/BitChord/Local), sort options |
| Accounts | `Accounts.swift`, `AccountViews.swift` | Done — Google/YouTube Music WKWebView cookie + visitorData capture + sign-out, Spotify OAuth PKCE (user client id, `bitchord://spotify-callback` scheme in Info.plist) + playlists/Liked Songs, Discord gateway presence (quality toggle), Last.fm (MD5 auth, now-playing, 50%/240 s scrobble) + ListenBrainz, all tokens in Keychain |
| Sources | `Sources.swift`, `AccountViews.swift` (SourcesView) | Done — reorderable registry, YouTube built-in/non-removable, JioSaavn (DES "38346591", 320 kbps rewrite only when catalogue says so), Addon (/manifest.json, /search, /stream), Module (JavaScriptCore sandbox, searchTracks/getTrackStreamUrl only), WebDAV (PROPFIND/GET), per-source health check; sources are consulted before YouTube in PlayerEngine.loadCurrentTrack |
| Equalizer | `EqualizerTap.swift`, `SettingsViews.swift` (EqualizerView) | Done — MTAudioProcessingTap biquad filters, 7 bands 60/150/400/1000/2500/6000/14000 Hz (low shelf / peaking / high shelf), all 16 original presets with original gains, ±12 dB sliders, balance, preamp headroom, loudness toggle |
| Automix | `Automix.swift` | Done — 4-bar overlap (capped at last 30 s), tempo-matched rate clamped to 40–220 BPM and ±8% (else plain crossfade), DJ gain ride; BPM by onset/peak detection over decoded audio (no ONNX on iOS) |
| Settings / Replay / Canvas | `SettingsStore.swift`, `SettingsViews.swift`, `NowPlayingView.swift` (CanvasView) | Done — Wi-Fi/cellular/download quality, Wi-Fi-only downloads, crossfade, automix, skip silence, loudness, theme, dynamic artwork theming (pixel-sampled dominant colour), liquid glass, animated canvas (animated gradient; no canvas video URL exists in the Innertube track model), full-bleed artwork, lyrics settings, backup/restore JSON (tokens excluded), signature-API field, Replay (top tracks/artists/minutes + share) |

## Listen Together — protocol (implemented exactly)

Source of truth: `../original/backend/README.md`,
`../original/backend/protocol/protocol.go`,
`../original/backend/party/party.go`, `../original/backend/codes/codes.go`,
and the Android client `../original/app/src/main/java/com/music/bitchord/data/listentogether/ListenTogether.kt`.

- **Hosts.** API host (REST + WebSocket): `https://api.bitchord.kushagrasingh.in`
  (editable in the Listen Together screen; a bare hostname gets `https://`
  prepended). Invite links use a *different* origin:
  `https://bitchord.kushagrasingh.in/invite/<CODE>`.
- **REST.** `GET /healthz`, `GET /api/time`,
  `POST /api/parties` → 201 `{code, token, you, party}` (create + join as host,
  body `userId`, `deviceId`, `displayName`, optional `avatarUrl`, `maxMembers`,
  `autoplayEnabled`),
  `POST /api/parties/{code}/join` → 200 same shape
  (404 unknown code, 409 full, 422 no identity),
  `GET /api/parties/{code}` and `POST /api/parties/{code}/leave`, all after
  join with `Authorization: Bearer <token>`.
- **Token.** Returned exactly once, stored in the Keychain under
  `listenTogether.token.<CODE>` — never in UserDefaults, never in a URL.
  Reconnecting within the 45 s grace period reuses it (no new REST join), so
  the same device slot is reclaimed instead of filling a new one. If the
  server answers `bad_token`/`no_such_party`, the client stops dialling and
  tells the user, rather than retrying forever.
- **Codes.** Typed codes are normalised exactly like the server
  (`codes.Normalise`): trim, uppercase, drop non-alphanumerics, `O`→`0`,
  `I`/`L`→`1`; a valid code is 6 chars from `0123456789ABCDEFGHJKMNPQRSTUVWXYZ`.
  Invite URLs are parsed only in the exact shape
  `<inviteOrigin>/invite/<6 alnum chars>`.
- **WebSocket.** `/ws/parties/{code}` via `URLSessionWebSocketTask` built from a
  `URLRequest` carrying `Authorization: Bearer <token>` on the handshake.
  The token is never in the URL. Client frames: `ping {clientMs}`, `sync`,
  `syncQueue`, `report {positionMs, isPlaying}`, `control` with actions
  `play`/`pause`/`seek` (seek requires `positionMs`) / `setTrack`
  `{track, positionMs, isPlaying}` / `setQueue {queue, queueIndex}` /
  `queueAdd {tracks, playNext}` / `queueRemove {videoId}` / `queueClear` /
  `queueMove {fromIndex, toIndex, videoId}` / `next` / `previous` /
  `setHostOnlyControl {enabled}` / `kick {memberId}`.
  Server frames handled: `welcome {you, party, serverMs}`, `pong`, `state
  {playback, serverMs}`, `queue {queue:{seq, index, items}, serverMs}`,
  `members {members, maxMembers, hostOnlyControl, serverMs}`, `activity`,
  `error`, `bye {reason left|kicked}`.
- **Clock sync.** `offset = serverMs − (t0 + t1) / 2` from ping/pong; only the
  smallest-RTT sample sets the offset. `GET /api/time` gives a first estimate
  before the socket exists. Playhead =
  `positionMs + max(0, serverNow − anchorMs)` while playing, else `positionMs`
  (clamped to the track duration when known). Play/seek anchors are 350 ms
  ahead (`JAM_PLAY_LEAD_MS`); the client waits for the anchor before starting,
  so all devices aim at one common instant. The clock is reset on a socket
  drop — an offset measured before a gap is not trusted after it.
- **Sequencing.** Any `state` frame whose `playback.seq` is not greater than
  the last applied seq is ignored (this is what keeps two simultaneous
  controllers from sending each other backwards). `state` carries only
  `queueSeq`/`queueIndex`/`queueLength`; if `queueSeq` disagrees with the held
  queue's seq, the client sends `syncQueue`. Queue frames arrive before the
  state frame that points at them, and snapshots (`welcome`, REST party
  object) carry the whole queue.
- **Tracks on the wire.** Only
  `{videoId, title, artist, thumbnailUrl, durationMs, fromAutoplay}`
  (+ `startedBy`/`startedByName`/`updatedBy` on state). Stream URLs are never
  shared: each device resolves its own URL from the videoId via
  `StreamResolver`, so two phones can be on different bitrates and still be
  in the same place.
- **Player wiring.** `PlayerEngine` reports local gestures to its party
  delegate and applies remote state with an `applyingPartyState` flag so
  remote state never echoes back as a control frame. Local play/pause/seek/
  queue edits while in a party send the matching control frame; remote state
  drives `PlayerEngine` (same track + drift ≤ 1.5 s + same play state = no
  action, so heartbeats don't fight local playback). Track end in a party
  sends `next`, not a local skip.
- **Rules enforced in UI and by the server.** Max 5 members; host-only control
  toggle is host-only in the UI *and* the server answers `403 host_only` to
  anyone else — that error is surfaced in the UI, not just hidden buttons.
  Upcoming queue cap 25 (local trim on `setQueue`, local block + error on
  `queueAdd` past 25). Kicked members: the party view closes, the reason is
  shown, and this device refuses to rejoin that code for 24 hours
  (mirroring the Android client; the server itself forgets parties quickly).
  Host promotion is read from `members` frames only — the one place the
  server announces it.
- **Failure honesty.** Connection state is always visible
  (connecting / connected / reconnecting / error), plus the last server error
  and the exact URL that was tried. If the backend is unreachable, the screen
  says so with that URL — it never pretends a party exists offline.
  Reconnect uses jittered exponential backoff (1 s → 30 s cap); pings are a
  burst of 4 × 300 ms on connect, then every 15 s; position reports go every
  10 s (reports are monitoring only — the server never averages towards a
  straggler).

### Test Listen Together with two devices

1. On device A: Listen Together → display name → Create party. Note the code
   and share the invite link.
2. On device B: same screen → enter the code (or open the invite link) →
   Join party. Both screens should show Connected, both members, and the
   host badge on A.
3. On A, play any track (once the library/search screens land) or, today,
   play a track through `PlayerEngine` — B must start the *same* track.
   Pause on B: A pauses. Seek on A: B follows within about a second.
   Add tracks to the queue on either device: both queues match; adding a
   26th upcoming track is refused with the cap message.
4. On A (host), turn on Host-only control: B's transport buttons disable,
   and any control B still sends is answered `host_only` and shown as an error.
5. Turn A's Wi-Fi off for ~10 s, then back on: the state shows Reconnecting,
   then Connected again, in the same party, at the right position — no new
   code, no duplicate member. (The server holds the slot for 45 s.)
6. On A, remove B: B's party view closes with "The host removed you", and
   B cannot rejoin that code for 24 hours.
7. Kill the backend (or point the server field at a dead host): both screens
   show the error *and the URL tried*, and no fake party appears.

## Honest limits (this port, after the full build)

- **Skip silence is trailing-only.** The RMS tap can see a silent tail in
  real time, so a silent last ~20 s is skipped after 2 s of near-silence.
  A silent intro cannot be skipped without offline analysis, and this port
  does not claim otherwise.
- **KuGou lyrics are not decoded.** KuGou answers KRC (encoded) lyrics;
  decoding that format is not implemented, so KuGou falls through to the
  next lyrics provider instead of returning garbage.
- **Automix BPM is onset-based, not ONNX.** The original uses neural beat
  tracking + vocal separation; iOS has no bundled ONNX runtime, so BPM
  comes from an onset/peak detector over decoded local audio (streamed
  tracks have no local file to analyse, so their BPM is unknown and
  Automix falls back to a plain crossfade for them).
- **Animated canvas is a gradient, not a video.** The Innertube track
  model carries no canvas-video URL, so CanvasView renders animated
  motion over the artwork instead of the original's motion artwork.
- **Dolby Atmos / spatial audio has no per-app iOS switch.** Tracks play
  through the system audio session as delivered; there is no iOS API to
  toggle Atmos per app for AVPlayer streams.
- **DSD / USB-DAC and Chromecast are Android-only** (replaced by the iOS
  audio session + AirPlay). **SMB is via the Files app** on iOS, not an
  in-app SMB client. WebDAV is in-app.
- **Spotify redirect needs the URL scheme.** `bitchord://spotify-callback`
  is registered in Info.plist and handled in `BitChordApp.onOpenURL`; the
  Spotify app on the Spotify dashboard must list that exact redirect URI.
  If it is not registered there, paste the code from the redirect URL
  into the Accounts screen instead.

## Honest limits (carried from the full port brief)

- **poToken / signatureCipher streams.** If YouTube returns only ciphered
  formats, playback fails with a clear message naming the poToken/cipher
  step — no URL is fabricated. Signing in (Google account flow, full port)
  is the route to a poToken.
- **DSD / USB-DAC and Cast are Android-only.** On iOS they are replaced by
  the iOS audio session + AirPlay route picker (full port). SMB is via the
  Files app on iOS, not an in-app SMB client.
- **Keys are never hardcoded.** Spotify client id, Last.fm api key/secret and
  Discord token are entered in-app in the full port and stored in the
  Keychain, never in UserDefaults and never in source.
- **Not compiled yet.** See "Build" above — Xcode on a Mac is required to
  verify compilation; this VM has no Swift toolchain.

## Mechanical check (this VM, no Xcode)

- Brace/paren/bracket balance per Swift file: checked by script that
  strips comments and string literals first (including `#""#` raw
  strings, whose quotes broke the first naive pass) — **all 22 Swift
  files balance**.
- No duplicate top-level type names across the 22 files.
- Every Swift file is listed in `project.pbxproj` (22
  `sourcecode.swift` references: 9 original + 13 new).
- No `TODO`/`FIXME` stubs in core paths.
- `~/workspace/bitchord-ios/original/` untouched (git status clean).
- `ListenTogether.swift` untouched; `PlayerEngine.swift` edited only by
  adding published settings + helpers — every pre-existing public
  signature (`play`, `pause`, `togglePlayPause`, `seek`,
  `setPlaybackSpeed`, `playTrack`, `setQueue`, `next`, `previous`,
  `addToQueue`, `removeFromQueue`, `clearUpcoming`, `moveQueue`,
  `loadCurrentTrack`, `applyPartyTrack`, `applyPartyPlayState`,
  `applyPartySeek`, `applyPartyQueue`, `detachParty`, `partyDelegate`,
  `applyingPartyState`, `streamResolver`, `maxKbps`, `queue`,
  `currentIndex`, `isPlaying`, `position`, `duration`, `errorMessage`,
  `playbackSpeed`) is intact.
- Imports are real frameworks only: Foundation, SwiftUI, AVFoundation,
  AVKit, MediaPlayer, MediaToolbox, Network, WebKit, JavaScriptCore,
  UIKit, UniformTypeIdentifiers, CommonCrypto, Security.
