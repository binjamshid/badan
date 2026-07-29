import SwiftUI

enum SubmissionLogCopy {
    static let title = LocalizedString(en: "What has been sent", ar: "ما الذي أُرسل")
    static let intro = LocalizedString(
        en: "Every submission BADAN has made, exactly as it was sent. This is the message itself, "
            + "not a description of it.",
        ar: "كل إرسال قام به بادن، تماماً كما أُرسل. هذه هي الرسالة نفسها، لا وصفٌ لها.")
    static let empty = LocalizedString(en: "Nothing has been sent.", ar: "لم يُرسل شيء.")
    /// The empty state must not read as "nothing is being hidden from you" — it should say why it
    /// is empty, since the commonest reason is simply that the feature is off.
    static let emptyBecauseOff = LocalizedString(
        en: "Methodology feedback is off, so nothing has been sent and nothing will be.",
        ar: "ملاحظات المنهجية معطّلة، فلم يُرسل شيء ولن يُرسل.")
    static let emptyButOn = LocalizedString(
        en: "Nothing has been sent yet. A submission is only made after you have answered about "
            + "the same metric at least ten times.",
        ar: "لم يُرسل شيء بعد. لا يتم الإرسال إلا بعد إجابتك عن المؤشر نفسه عشر مرات على الأقل.")
    static let clear = LocalizedString(en: "Clear this list", ar: "مسح هذه القائمة")
    /// Clearing the local list does not unsend anything, and pretending otherwise would be the
    /// exact dishonesty this screen exists to prevent.
    static let clearNote = LocalizedString(
        en: "Clearing this removes your own copy of the list. It does not unsend anything — and "
            + "because a submission carries nothing that identifies you, there is nothing on the "
            + "server that could be found and removed.",
        ar: "المسح يزيل نسختك من القائمة فقط. لا يلغي الإرسال — ولأن الإرسال لا يحمل ما يعرّفك، "
            + "لا يوجد على الخادم ما يمكن إيجاده وحذفه.")
}

/// Settings → Privacy & Security → Telemetry → "What has been sent" (ADR-0011 / D-37).
///
/// The anti-dark-pattern move, and it only works because it is VERBATIM: the stored
/// `FootprintBatch` is re-encoded and shown as JSON, so the user reads precisely the bytes that
/// left their device. A friendly summary would be a description someone wrote, and a description
/// can drift from the payload — this cannot.
struct TelemetrySubmissionLogScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var entries: [RecordedSubmission] = []

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted and pretty-printed so it is READABLE. A wall of minified JSON would be verbatim
        // and useless, which would make this screen a gesture rather than a disclosure.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                LText(SubmissionLogCopy.intro)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if entries.isEmpty {
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            LText(SubmissionLogCopy.empty)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            LText(env.profile.methodologyTelemetryEnabled
                                  ? SubmissionLogCopy.emptyButOn
                                  : SubmissionLogCopy.emptyBecauseOff)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(entries) { entry in
                        submissionCard(entry)
                    }
                    BadanCard {
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            Button(role: .destructive) {
                                SubmissionLog().clear()
                                entries = []
                            } label: {
                                Text(SubmissionLogCopy.clear, language: env.language)
                                    .font(BadanFont.body)
                                    .foregroundStyle(BadanColor.critical)
                                    .frame(minHeight: BadanSpace.touchMin)
                            }
                            .buttonStyle(.plain)
                            LText(SubmissionLogCopy.clearNote)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(SubmissionLogCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = SubmissionLog().all() }
    }

    private func submissionCard(_ entry: RecordedSubmission) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                // A plain localized date/time. `ValueFormatter` has no date facility — it formats
                // measurements — so this uses Foundation directly rather than growing that type a
                // responsibility it does not otherwise have.
                Text(entry.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                Text(json(entry.batch))
                    .font(BadanFont.caption.monospaced())
                    .foregroundStyle(BadanColor.textPrimary)
                    .textSelection(.enabled)
                    // LTR regardless of app language: this is a JSON document, and mirroring it
                    // would misrepresent the bytes it claims to be showing verbatim.
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func json(_ batch: FootprintBatch) -> String {
        guard let data = try? Self.encoder.encode(batch),
              let text = String(data: data, encoding: .utf8) else { return "—" }
        return text
    }
}
