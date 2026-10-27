import SwiftUI

// MARK: - Listen Together screen: create / join / members / queue / controls.
// Never invents a party offline: every error shows the URL that was tried,
// and the connection state pill is always visible while in a party.

struct ListenTogetherView: View {
    @StateObject private var party = ListenTogether.shared
    @StateObject private var player = PlayerEngine.shared
    @State private var joinCode = ""
    @State private var joinError: String?
    @State private var busy = false
    @State private var healthOK: Bool?
    @State private var showingLeaveConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if let bye = party.byeReason {
                    Section { Label(bye, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let err = party.lastServerError {
                    Section("Server") {
                        Text(err).foregroundStyle(.red).font(.callout)
                        if let tried = party.lastAttemptedURL { Text("Tried: \(tried)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("Server") {
                    TextField("Party server", text: $party.serverBaseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout)
                    Text("Default: \(ListenTogether.defaultAPIHost). Invite links use \(ListenTogether.inviteOrigin).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check server") {
                            Task {
                                healthOK = await party.checkHealth()
                            }
                        }
                        if let ok = healthOK {
                            Label(ok ? "Reachable" : "Unreachable", systemImage: ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(ok ? .green : .red)
                        }
                    }
                    TextField("Display name", text: $party.displayName)
                }

                if !party.isInParty {
                    Section("Start or join") {
                        Button(busy ? "Creating…" : "Create party") {
                            Task { busy = true; defer { busy = false }
                                do { try await party.createParty(); joinError = nil }
                                catch { joinError = error.localizedDescription } }
                        }.disabled(busy || party.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        TextField("Party code (6 letters/digits)", text: $joinCode)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button(busy ? "Joining…" : "Join party") {
                            Task { busy = true; defer { busy = false }
                                do { try await party.joinParty(rawCode: joinCode); joinError = nil }
                                catch { joinError = error.localizedDescription } }
                        }.disabled(busy || joinCode.isEmpty)
                        if let saved = UserDefaults.standard.string(forKey: "listenTogetherLastCode"), !saved.isEmpty {
                            Button("Resume saved party \(saved)") {
                                Task { await party.reconnectWithStoredToken(code: saved) }
                            }
                            Text("Resuming reuses the saved token, so your device slot is reclaimed within the 45-second grace period.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let err = joinError { Text(err).foregroundStyle(.red).font(.callout) }
                        Text("Tip: type O for 0 and I/L for 1 — codes are normalised the same way the server does.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Party \(party.code ?? "")") {
                        HStack {
                            Label(party.connectionState.label, systemImage: party.connectionState == .connected ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                                .foregroundStyle(party.connectionState == .connected ? .green : .orange)
                            Spacer()
                            if party.clockSynced, let rtt = party.roundTripMs {
                                Text("Clock synced · \(rtt) ms RTT").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Clock not yet synced").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let url = party.inviteURL {
                            HStack {
                                Text(url).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Copy") { UIPasteboard.general.string = url }
                            }
                            Text("Anyone with this link joins the same party.").font(.caption).foregroundStyle(.secondary)
                        }
                        if party.connectionState == .reconnecting || party.connectionState == .error {
                            Button("Reconnect") { Task { await party.manualReconnect() } }
                        }
                    }

                    Section("Now playing") {
                        if let track = party.playback?.track {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.headline)
                                Text(track.artist).foregroundStyle(.secondary)
                                if let by = party.playback?.startedByName { Text("Started by \(by)").font(.caption).foregroundStyle(.secondary) }
                                if let dur = track.durationMs { Text("Duration \(dur / 1000)s · position \(Int(player.position))s").font(.caption).foregroundStyle(.secondary) }
                            }
                            HStack {
                                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                                Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                                Button { player.next() } label: { Image(systemName: "forward.fill") }
                            }
                            .disabled(!party.canControl)
                            if !party.canControl {
                                Text("Host-only control is on — only the host can change the music.").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Nothing playing yet — pick a track and it plays for everyone.").foregroundStyle(.secondary)
                        }
                        if let activity = party.lastActivity { Text(activity).font(.caption).foregroundStyle(.secondary) }
                    }

                    Section("Members (\(party.members.count)/\(party.maxMembers))") {
                        ForEach(party.members) { member in
                            HStack {
                                Text(member.displayName)
                                if member.isHost { Text("HOST").font(.caption2).bold().padding(3).background(.blue.opacity(0.2)).clipShape(Capsule()) }
                                Spacer()
                                if !member.connected { Text("offline").font(.caption).foregroundStyle(.secondary) }
                                if party.you?.isHost == true, member.memberId != party.you?.memberId {
                                    Button("Remove") { party.partyKick(memberId: member.memberId) }
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        Toggle("Host-only control", isOn: Binding(
                            get: { party.hostOnlyControl },
                            set: { newValue in party.partySetHostOnlyControl(newValue) }
                        ))
                        .disabled(party.you?.isHost != true)
                        Text("When on, the server refuses playback and queue actions from everyone but the host (403 host_only) — it is not just hidden buttons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Queue (\(party.upcomingCount) upcoming · max \(ListenTogether.maxUpcoming))") {
                        if party.queue.isEmpty {
                            Text("Queue is empty.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(party.queue.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item.title).lineLimit(1)
                                Spacer()
                                if index == party.queueIndex { Text("Now").font(.caption).foregroundStyle(.secondary) }
                                if index > party.queueIndex {
                                    Button { party.partyQueueRemove(videoId: item.videoId) } label: { Image(systemName: "xmark") }
                                }
                            }
                        }
                        if party.isQueueFull {
                            Text("Queue is full — no more upcoming songs can be added.").font(.caption).foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button("Leave party", role: .destructive) { showingLeaveConfirm = true }
                            .alert("Leave party?", isPresented: $showingLeaveConfirm) {
                                Button("Leave", role: .destructive) { Task { await party.leaveParty() } }
                                Button("Stay", role: .cancel) {}
                            } message: {
                                Text("Your device slot is freed for others.")
                            }
                    }
                }
            }
            .navigationTitle("Listen Together")
        }
    }
}
