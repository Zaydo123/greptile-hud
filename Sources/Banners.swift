import SwiftUI

// MARK: - Crew banners
//
// Short, time-boxed shout-outs ("🎂 Happy birthday!") that ride across the top
// of every crew member's HUD until they expire (24h). Posting lives in the Crew
// tab (`BannerComposer`); the strip (`CrewBannerStrip`) shows on every tab.

/// "23h left", "45m left" — coarse on purpose; the strip isn't a stopwatch.
func bannerTimeLeft(_ expiresAt: Date, now: Date = Date()) -> String {
    let s = max(0, Int(expiresAt.timeIntervalSince(now)))
    if s >= 3600 { return "\(s / 3600)h left" }
    return "\(max(1, s / 60))m left"
}

/// The strip under the tab bar. Shows one banner at a time; a pager steps
/// through the rest. ✕ hides a banner on this Mac; the author or recipient
/// can also remove it for everyone from the context menu.
struct CrewBannerStrip: View {
    @ObservedObject var vibecoders: VibecodersStore
    @State private var index = 0
    @State private var hovered = false
    @State private var wiggle = false

    var body: some View {
        let banners = vibecoders.visibleBanners
        if !banners.isEmpty {
            let banner = banners[min(index, banners.count - 1)]
            row(banner, position: min(index, banners.count - 1), count: banners.count)
                .id(banner.id)
                .transition(.opacity)
                .onChange(of: banners.count) { count in
                    if index >= count { index = max(0, count - 1) }
                }
        }
    }

    private func row(_ banner: VCBanner, position: Int, count: Int) -> some View {
        let accent = Tokyo.banner(banner.emoji)
        let forMe = vibecoders.isMe(banner.to)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 10) {
            Text(banner.emoji.isEmpty ? "📣" : banner.emoji)
                .font(.system(size: 20))
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.2), in: Circle())
                .overlay(Circle().strokeBorder(accent.opacity(0.45), lineWidth: 0.5))
                .rotationEffect(.degrees(forMe && wiggle ? 8 : 0))
                .animation(forMe ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                           value: wiggle)
                .onAppear { wiggle = forMe }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(banner.message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokyo.fg)
                        .lineLimit(1)
                    if forMe {
                        Text("For you")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Tokyo.bgDark)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(accent, in: Capsule())
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    if let to = banner.to {
                        CrewAvatar(login: to, avatarPath: banner.toAvatarUrl, size: 14)
                        Text("for @\(to)").foregroundStyle(accent)
                        Text("·").foregroundStyle(Tokyo.comment)
                    } else {
                        Text("for the crew").foregroundStyle(accent)
                        Text("·").foregroundStyle(Tokyo.comment)
                    }
                    Text("from @\(banner.author)")
                    Text("·").foregroundStyle(Tokyo.comment)
                    TimelineView(.periodic(from: Date(), by: 60)) { ctx in
                        Text(bannerTimeLeft(banner.expiresAt, now: ctx.date))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Tokyo.fgDim)
                .lineLimit(1)
            }
            Spacer(minLength: 0)

            if count > 1 {
                Text("\(position + 1)/\(count)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Tokyo.comment)
                    .fixedSize()
                ToolbarIconButton(symbol: "chevron.right", help: "Next banner") {
                    withAnimation(.easeInOut(duration: 0.16)) { index = (position + 1) % count }
                }
            }
            ToolbarIconButton(symbol: "xmark", help: "Hide this banner on this Mac") {
                withAnimation(.easeInOut(duration: 0.16)) { vibecoders.dismissBanner(banner) }
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
        .background {
            ZStack {
                shape.fill(Tokyo.surface(hovered ? 1 : 0))
                shape.fill(LinearGradient(colors: [accent.opacity(forMe ? 0.26 : 0.16), accent.opacity(0.03)],
                                          startPoint: .leading, endPoint: .trailing))
            }
        }
        .overlay(shape.strokeBorder(accent.opacity(forMe ? 0.6 : 0.32), lineWidth: forMe ? 1 : 0.5))
        .contentShape(shape)
        .onHover { hovered = $0 }
        .contextMenu {
            if vibecoders.canRemove(banner) {
                Button("Remove for Everyone") { vibecoders.removeBanner(banner) }
            }
            Button("Hide on This Mac") { vibecoders.dismissBanner(banner) }
        }
        .help(vibecoders.canRemove(banner)
              ? "Right-click to remove this banner for everyone"
              : "Shown to the whole crew until it expires")
        .padding(.horizontal, 16).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.message), \(banner.to.map { "for \($0)" } ?? "for the crew"), from \(banner.author)")
    }
}

/// Crew-tab composer: pick a preset, optionally a recipient, tweak the text,
/// post. Also lists your own live banners so you can take one down.
struct BannerComposer: View {
    @ObservedObject var vibecoders: VibecodersStore
    var onTextEditing: (Bool) -> Void = { _ in }

    @State private var preset: BannerPreset? = .birthday
    @State private var emoji = BannerPreset.birthday.rawValue
    @State private var message = BannerPreset.birthday.message
    @State private var recipient = ""
    @State private var posted = false

    private var accent: Color { Tokyo.banner(emoji) }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPost: Bool { !trimmedMessage.isEmpty && !vibecoders.bannerPosting }

    /// Online crew (not you) as one-click recipients.
    private var suggestions: [VCOnlineUser] {
        Array(vibecoders.online.filter { !vibecoders.isMe($0.login) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Shout-outs") {
                Spacer()
                Text("Banner on every crew HUD for 24h")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            }

            HStack(spacing: 6) {
                ForEach(BannerPreset.allCases) { p in presetChip(p) }
                Spacer(minLength: 0)
            }

            InsetGroup {
                HStack(spacing: 8) {
                    Text("For").foregroundStyle(Tokyo.comment).frame(width: 34, alignment: .leading)
                    Text("@").foregroundStyle(Tokyo.comment)
                    HUDTextField(text: $recipient,
                                 placeholder: "username — leave blank for the whole crew",
                                 fontSize: 12,
                                 maximumCharacters: 39,
                                 onEditing: onTextEditing,
                                 onSubmit: post)
                        .frame(height: 22)
                    if !suggestions.isEmpty && recipient.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(suggestions, id: \.login) { u in
                                Button { recipient = u.login } label: {
                                    CrewAvatar(login: u.login, avatarPath: u.avatarUrl, size: 20)
                                        .frame(width: 26, height: 26)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Send to @\(u.login)")
                            }
                        }
                        .fixedSize()
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).frame(minHeight: 40)

                RowDivider(inset: 12)

                HStack(spacing: 8) {
                    Text(emoji.isEmpty ? "📣" : emoji)
                        .font(.system(size: 16))
                        .frame(width: 34, alignment: .leading)
                    HUDTextField(text: $message,
                                 placeholder: "Message",
                                 fontSize: 12,
                                 maximumCharacters: BannerPreset.messageLimit,
                                 onEditing: onTextEditing,
                                 onSubmit: post)
                        .frame(height: 22)
                    Button(action: post) {
                        HStack(spacing: 5) {
                            if vibecoders.bannerPosting {
                                Spinner(size: 10, color: Tokyo.bgDark)
                            } else {
                                Image(systemName: posted ? "checkmark" : "megaphone.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(posted ? "Posted" : "Post")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokyo.bgDark)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(canPost ? accent : Tokyo.comment, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPost)
                    .fixedSize()
                    .help("Show this banner on every crew member’s HUD for 24 hours")
                }
                .padding(.leading, 12).padding(.trailing, 8).frame(minHeight: 44)

                ForEach(vibecoders.myBanners) { banner in
                    RowDivider(inset: 12)
                    myBannerRow(banner)
                }
            }

            if let error = vibecoders.bannerError {
                Text(error).font(.system(size: 11)).foregroundStyle(Tokyo.orange)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func presetChip(_ p: BannerPreset) -> some View {
        let selected = preset == p
        let tone = Tokyo.banner(p.rawValue)
        return Button {
            // Only overwrite the text if it's still a preset's (or empty), so
            // picking a different emoji never eats a message you typed.
            let untouched = trimmedMessage.isEmpty || BannerPreset.allCases.contains { $0.message == message }
            preset = p
            emoji = p.rawValue
            if untouched { message = p.message }
        } label: {
            HStack(spacing: 4) {
                Text(p.rawValue).font(.system(size: 13))
                Text(p.label).font(.system(size: 11, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? tone : Tokyo.fgDim)
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? tone.opacity(0.16) : Tokyo.surface(0), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tone.opacity(0.55) : Tokyo.stroke(),
                                            lineWidth: selected ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "")
    }

    private func myBannerRow(_ banner: VCBanner) -> some View {
        HStack(spacing: 8) {
            Text(banner.emoji.isEmpty ? "📣" : banner.emoji)
                .font(.system(size: 13)).frame(width: 34, alignment: .leading)
            Text(banner.message).foregroundStyle(Tokyo.fg).lineLimit(1)
            Text(banner.to.map { "for @\($0)" } ?? "for the crew")
                .foregroundStyle(Tokyo.banner(banner.emoji)).lineLimit(1)
            Spacer(minLength: 6)
            Text(bannerTimeLeft(banner.expiresAt)).foregroundStyle(Tokyo.comment).fixedSize()
            ToolbarIconButton(symbol: "trash", help: "Remove this banner for everyone",
                              tint: Tokyo.comment) {
                vibecoders.removeBanner(banner)
            }
        }
        .font(.system(size: 11))
        .padding(.leading, 12).padding(.trailing, 6).frame(minHeight: 40)
    }

    private func post() {
        guard canPost else { return }
        let text = trimmedMessage
        Task { @MainActor in
            if await vibecoders.postBanner(to: recipient, emoji: emoji, message: text) {
                recipient = ""
                withAnimation { posted = true }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { posted = false }
            }
        }
    }
}
