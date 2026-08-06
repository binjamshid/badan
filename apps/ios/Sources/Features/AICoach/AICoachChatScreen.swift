import SwiftUI

/// One transcript entry. `.user` carries the exact context bundle sent alongside that query — the
/// "see what context was actually included in this turn" transparency the client task asks for —
/// so the disclosure is per-message, not a single global note the user has to remember applies to
/// everything.
private struct AICoachTurn: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case error(LocalizedString)
    }
    let id = UUID()
    let kind: Kind
    let text: String
    let contextIncluded: AICoachContextAssembler.ContextBundle?
}

/// The AI coach's chat surface (A9 / ADR-0010 / D-22). Reachable ONLY when
/// `env.profile.aiCoachEnabled` is true (`LogHubScreen`'s tile routes here instead of to
/// `AICoachConsentScreen` once the flag flips) — but this screen holds its own second check
/// anyway (`client.isEnabled`, i.e. "does a device token actually exist") and shows an inert,
/// non-crashing placeholder rather than assume the flag alone is enough, matching
/// `RouteConsentStore`'s two-gate reasoning this codebase already applies elsewhere.
///
/// Conversation history is in-memory (`@State`) ONLY — never persisted to disk on this device,
/// matching `backend/api/main.py`'s own promise that the server keeps none either ("holds no user
/// accounts, no health data, and no conversation history"). Leaving this screen loses the
/// transcript; that is the deliberate, honest behavior, not a bug.
struct AICoachChatScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var client = AICoachClient()
    @State private var turns: [AICoachTurn] = []
    @State private var draft = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            if !client.isEnabled {
                notEnabledState
            } else {
                transcript
                composer
            }
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(AICoachChatStrings.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    AICoachConsentScreen()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text(AICoachChatStrings.manageAction, language: env.language))
            }
        }
    }

    // MARK: - Defense-in-depth inert state (client task: "typed, non-crashing state")

    private var notEnabledState: some View {
        VStack(spacing: BadanSpace.space4) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(env.s(AICoachChatStrings.notEnabledTitle))
                .font(BadanFont.body.weight(.semibold))
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(env.s(AICoachChatStrings.notEnabledBody))
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                AICoachConsentScreen()
            } label: {
                Text(env.s(AICoachChatStrings.goToConsentAction))
                    .font(BadanFont.body.weight(.semibold))
                    .frame(minHeight: BadanSpace.touchMin)
            }
            .buttonStyle(.borderedProminent)
            .tint(BadanColor.primary)
            Spacer()
        }
        .padding(BadanSpace.space6)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BadanSpace.space3) {
                    if turns.isEmpty {
                        Text(env.s(AICoachChatStrings.emptyStateBody))
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if isSending {
                        HStack(spacing: BadanSpace.space2) {
                            ProgressView()
                            Text(env.s(AICoachChatStrings.thinking))
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                        }
                    }
                }
                .padding(BadanSpace.space4)
            }
            .onChange(of: turns.count) { _, _ in
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: AICoachTurn) -> some View {
        switch turn.kind {
        case .user:
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(env.s(AICoachChatStrings.youLabel))
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.textSecondary)
                Text(turn.text)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let bundle = turn.contextIncluded {
                    contextDisclosure(bundle)
                }
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        case .assistant:
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Text(env.s(AICoachChatStrings.coachLabel))
                    .font(BadanFont.caption.weight(.semibold))
                    .foregroundStyle(BadanColor.primary)
                Text(turn.text)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                    .stroke(BadanColor.separator, lineWidth: 1)
            )
        case .error(let message):
            HStack(alignment: .top, spacing: BadanSpace.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(BadanColor.outOfBand)
                    .accessibilityHidden(true)
                Text(env.s(message))
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BadanColor.surfaceElevated, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
        }
    }

    /// The transparency disclosure: exactly the text that accompanied THIS query, in the same
    /// rendering `AICoachContextAssembler.renderForRequest` used to build the request itself — so
    /// what's shown here can never drift from what was actually sent.
    private func contextDisclosure(_ bundle: AICoachContextAssembler.ContextBundle) -> some View {
        DisclosureGroup {
            Text(AICoachContextAssembler.renderForRequest(bundle, language: env.language))
                .font(BadanFont.caption.monospaced())
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BadanSpace.space1)
        } label: {
            Text(env.s(AICoachChatStrings.contextIncludedLabel))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: BadanSpace.space2) {
            TextField(env.s(AICoachChatStrings.composerPlaceholder), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(BadanSpace.space3)
                .background(BadanColor.surface, in: RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BadanRadius.control, style: .continuous)
                        .stroke(BadanColor.separator, lineWidth: 1)
                )
                .submitLabel(.send)
                .onSubmit { send() }
                .disabled(isSending)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? BadanColor.primary : BadanColor.textSecondary)
            }
            .disabled(!canSend)
            .frame(minWidth: BadanSpace.touchMin, minHeight: BadanSpace.touchMin)
            .accessibilityLabel(Text(AICoachChatStrings.sendAction, language: env.language))
        }
        .padding(BadanSpace.space3)
        .background(BadanColor.background)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    // MARK: - Send

    private func send() {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSending else { return }
        draft = ""

        // Assembled fresh for THIS turn — never cached from a prior send — so "what was included"
        // always reflects the scores as they stood at the moment this specific query was sent.
        let bundle = (try? AICoachContextAssembler.assembleToday(
            derivation: AICoachContextAssembler.NonSensitiveDerivation(env.database),
            now: env.now(), tz: TimeZone.current.identifier))
            ?? AICoachContextAssembler.ContextBundle(items: [], asOfDayKey: "")

        turns.append(AICoachTurn(kind: .user, text: query, contextIncluded: bundle))
        isSending = true

        let contextText = AICoachContextAssembler.renderForRequest(bundle, language: env.language)
        let systemContent = env.s(AICoachChatStrings.systemPreamble) + "\n\n" + contextText
        var messages: [AICoachMessage] = [AICoachMessage(role: .system, content: systemContent)]
        messages += turns.compactMap { turn in
            switch turn.kind {
            case .user: return AICoachMessage(role: .user, content: turn.text)
            case .assistant: return AICoachMessage(role: .assistant, content: turn.text)
            case .error: return nil
            }
        }

        Task {
            do {
                let reply = try await client.sendChat(messages: messages)
                isSending = false
                turns.append(AICoachTurn(kind: .assistant, text: reply, contextIncluded: nil))
            } catch {
                isSending = false
                let notice = errorNotice(for: error)
                turns.append(AICoachTurn(kind: .error(notice), text: "", contextIncluded: nil))
                Announce.failure(env.s(notice))
            }
        }
    }

    private func errorNotice(for error: Error) -> LocalizedString {
        guard let coachError = error as? AICoachError else { return AICoachChatStrings.genericErrorNotice }
        switch coachError {
        case .notEnabled:
            return AICoachChatStrings.notEnabledNoticeInline
        case .transportError:
            return AICoachChatStrings.transportErrorNotice
        case .decodingError:
            return AICoachChatStrings.genericErrorNotice
        case .serverError(let status) where status == 429:
            return AICoachChatStrings.rateLimitedNotice
        case .serverError:
            return AICoachChatStrings.serverErrorNotice
        case .attestationUnavailable, .attestationFailedTransiently:
            // Both unreachable in practice from this screen — attestation happens once, at
            // opt-in (`AICoachConsentScreen`), and the chat screen is only reachable with a
            // token already stored. Mapped to the generic notice rather than left to the
            // exhaustive-switch error, because a device that somehow arrives here should still
            // see a sentence, not nothing. The retryable/not-retryable distinction the consent
            // screen draws between them has nothing to act on here.
            return AICoachChatStrings.genericErrorNotice
        }
    }
}

// MARK: - Screen-local strings (bilingual; wellness-safe by hand)

private enum AICoachChatStrings {
    static let title = LocalizedString(en: "AI coach", ar: "المدرب الذكي")
    static let manageAction = LocalizedString(en: "Manage AI coach", ar: "إدارة المدرب الذكي")

    static let emptyStateBody = LocalizedString(
        en: "Ask about today's Readiness, Effort, or Sleep score — the reply is a hosted AI's "
            + "response, in plain language, not a diagnosis or a plan.",
        ar: "اسأل عن نتيجة الجاهزية أو الجهد أو النوم لهذا اليوم — الإجابة هي رد ذكاء اصطناعي "
            + "مستضاف، بلغة واضحة، وليست تشخيصًا أو خطة علاج.")
    static let composerPlaceholder = LocalizedString(en: "Ask a question", ar: "اطرح سؤالاً")
    static let sendAction = LocalizedString(en: "Send", ar: "إرسال")
    static let thinking = LocalizedString(en: "Thinking…", ar: "جارٍ التفكير…")
    static let youLabel = LocalizedString(en: "You", ar: "أنت")
    static let coachLabel = LocalizedString(en: "AI coach", ar: "المدرب الذكي")
    static let contextIncludedLabel = LocalizedString(en: "Context included", ar: "السياق المُرسَل")

    static let notEnabledTitle = LocalizedString(en: "AI coach isn't on yet", ar: "المدرب الذكي غير مفعّل بعد")
    static let notEnabledBody = LocalizedString(
        en: "Turn it on from its own consent screen first — nothing is sent until you do.",
        ar: "فعّله أولاً من شاشة الموافقة الخاصة به — لا يُرسَل أي شيء قبل ذلك.")
    static let goToConsentAction = LocalizedString(en: "Turn on AI coach", ar: "تفعيل المدرب الذكي")
    static let notEnabledNoticeInline = LocalizedString(
        en: "The AI coach isn't on. Turn it on from Manage before sending a question.",
        ar: "المدرب الذكي غير مفعّل. فعّله من (إدارة) قبل إرسال سؤال.")

    static let transportErrorNotice = LocalizedString(
        en: "Couldn't reach the AI coach. Check your connection and try again.",
        ar: "تعذّر الوصول إلى المدرب الذكي. تحقّق من اتصالك وحاول مرة أخرى.")
    static let rateLimitedNotice = LocalizedString(
        en: "That's a lot of questions in a short time — wait a moment and try again.",
        ar: "هذا عدد كبير من الأسئلة خلال وقت قصير — انتظر قليلاً وحاول مرة أخرى.")
    static let serverErrorNotice = LocalizedString(
        en: "The AI coach couldn't answer that just now. Try again in a moment.",
        ar: "تعذّر على المدرب الذكي الإجابة الآن. حاول مرة أخرى بعد قليل.")
    static let genericErrorNotice = LocalizedString(
        en: "Something didn't go through. Try again.",
        ar: "لم يتم إرسال ذلك. حاول مرة أخرى.")

    /// The model-facing instruction preamble — sets the reply register (plain language, no
    /// diagnosis/treatment framing) but is not itself the mechanically-linted copy path (only
    /// `packages/contracts/insights/templates.json` is linted); written by hand to the same
    /// standard regardless.
    static let systemPreamble = LocalizedString(
        en: "You are BADAN's AI coach. Answer plainly and briefly about the user's own Readiness, "
            + "Effort, and Sleep scores given below. Never diagnose, never suggest medication or "
            + "dosing, avoid alarming language, and note when a score is still settling in rather "
            + "than stating it as certain.",
        ar: "أنت المدرب الذكي في بدن. أجب بوضوح وإيجاز عن نتائج الجاهزية والجهد والنوم الخاصة "
            + "بالمستخدم أدناه. لا تُشخّص أبدًا، ولا تقترح دواءً أو جرعة، وتجنّب اللغة المثيرة "
            + "للقلق، وأشر إلى أن النتيجة لا تزال قيد الاستقرار بدلاً من ذكرها كحقيقة مؤكدة.")
}
