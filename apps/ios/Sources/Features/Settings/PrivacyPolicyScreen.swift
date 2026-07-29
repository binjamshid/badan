import SwiftUI

// MARK: - Screen

/// The full privacy policy, rendered in-app and bilingually (COMP-04). BADAN is offline-first
/// with no backend, so the policy ships inside the binary rather than linking to a hosted URL —
/// it must be readable with no network. The English text here is kept in sync with
/// `docs/PRIVACY_POLICY.md`; the Arabic is a faithful translation at the same calm register as
/// the rest of the app. Reachable from Settings → Data & privacy → Privacy Policy.
///
/// Pushed screen: relies on the parent `NavigationStack` supplied by the app shell.
struct PrivacyPolicyScreen: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space4) {
                // Lede card: the one-line promise plus the version/date this policy applies to,
                // so the honest "everything stays on your device" claim is the first thing read.
                BadanCard {
                    HStack(alignment: .top, spacing: BadanSpace.space3) {
                        Image(systemName: "lock.shield")
                            .imageScale(.large)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BadanSpace.space2) {
                            LText(PrivacyPolicyStrings.lede)
                                .font(BadanFont.body.weight(.semibold))
                                .foregroundStyle(BadanColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            LText(PrivacyPolicyStrings.appliesTo)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                ForEach(PrivacyPolicyStrings.sections) { section in
                    policySection(section)
                }
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(PrivacyPolicyStrings.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policySection(_ section: PrivacyPolicyStrings.Section) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(section.heading))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space3) {
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        LText(paragraph)
                            .font(BadanFont.bodyCompact)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Strings (screen-local, always bilingual)

/// The policy text itself. English mirrors `docs/PRIVACY_POLICY.md`; the two are meant to be
/// updated together. Kept as structured `LocalizedString`s (not one long blob) so each clause
/// stays translatable and the layout can breathe between sections.
private enum PrivacyPolicyStrings {
    struct Section: Identifiable {
        let id = UUID()
        let heading: LocalizedString
        let paragraphs: [LocalizedString]
    }

    static let title = LocalizedString(en: "Privacy Policy", ar: "سياسة الخصوصية")

    static let lede = LocalizedString(
        en: "Everything stays on your device. BADAN has no servers, no accounts, and makes no "
            + "network calls — nothing you see here is ever transmitted anywhere.",
        ar: "كل شيء يبقى على جهازك. لا يملك بدن أي خوادم ولا حسابات، ولا يجري أي اتصال بالشبكة — "
            + "ولا يُنقل أي شيء تراه هنا إلى أي مكان.")

    static let appliesTo = LocalizedString(
        en: "Applies to BADAN for iOS, version 0.1.0. Last updated 2026-07-12.",
        ar: "ينطبق على بدن لنظام iOS، الإصدار 0.1.0. آخر تحديث 2026-07-12.")

    static let sections: [Section] = [
        Section(
            heading: LocalizedString(en: "What BADAN is", ar: "ما هو بدن"),
            paragraphs: [
                LocalizedString(
                    en: "BADAN organizes your own health readings and the things you choose to log, "
                        + "and shows them back to you. There is no sign-up and no account — you give "
                        + "BADAN no name, email, or password, because there is nowhere for it to go.",
                    ar: "ينظّم بدن قراءاتك الصحية وما تختار تسجيله، ويعرضها لك مجدداً. لا يوجد تسجيل "
                        + "دخول ولا حساب — فأنت لا تعطي بدن اسماً ولا بريداً ولا كلمة مرور، لأنه لا "
                        + "مكان يذهب إليه أيٌّ من ذلك."),
                LocalizedString(
                    en: "BADAN is a wellness and self-tracking tool. It is not a medical device and "
                        + "does not diagnose, treat, or give medical advice.",
                    ar: "بدن أداة للعافية والتتبّع الذاتي. ليس جهازاً طبياً ولا يشخّص ولا يعالج ولا "
                        + "يقدّم استشارة طبية."),
            ]),
        Section(
            heading: LocalizedString(en: "What data BADAN accesses", ar: "ما البيانات التي يصل إليها بدن"),
            paragraphs: [
                LocalizedString(
                    en: "From Apple Health — only if you connect it. BADAN never reads Apple Health "
                        + "until you tap Connect and grant permission. On a grant, it reads only: "
                        + "sleep, heart rate, resting heart rate, and steps. If you never connect, it "
                        + "reads none of it, and you can revoke access anytime in iOS Settings.",
                    ar: "من صحة آبل — فقط إن ربطتها. لا يقرأ بدن صحة آبل إطلاقاً حتى تضغط «اتصال» "
                        + "وتمنح الإذن. وعند المنح يقرأ فقط: النوم ومعدل ضربات القلب ومعدل القلب أثناء "
                        + "الراحة والخطوات. وإن لم تربطها فلا يقرأ منها شيئاً، ويمكنك سحب الإذن في أي "
                        + "وقت من إعدادات iOS."),
                LocalizedString(
                    en: "What you log yourself: workouts, nutrition, and notes — and sensitive health "
                        + "records: medications and symptoms. You choose what to enter; "
                        + "nothing is required.",
                    ar: "وما تسجّله بنفسك: التمارين والتغذية والملاحظات — والسجلات الصحية الحساسة: "
                        + "الأدوية والأعراض. أنت تختار ما تُدخله؛ ولا شيء إلزامي."),
                LocalizedString(
                    en: "BADAN does not access your contacts, location, photos, microphone, camera, "
                        + "calendar, or advertising identifier.",
                    ar: "لا يصل بدن إلى جهات اتصالك ولا موقعك ولا صورك ولا الميكروفون ولا الكاميرا ولا "
                        + "التقويم ولا معرّف الإعلانات."),
            ]),
        Section(
            heading: LocalizedString(en: "Where your data lives", ar: "أين تُحفظ بياناتك"),
            paragraphs: [
                LocalizedString(
                    en: "All of your data is stored on your device only, in two local databases: a "
                        + "main database for readings, sources, summaries, workouts, nutrition, and "
                        + "notes; and a separate, sensitive database used only for medications and "
                        + "symptoms — so you can turn those off and erase them on their own.",
                    ar: "تُحفظ كل بياناتك على جهازك فقط، في قاعدتَي بيانات محليتين: قاعدة رئيسية "
                        + "للقراءات والمصادر والملخّصات والتمارين والتغذية والملاحظات؛ وقاعدة منفصلة "
                        + "حساسة تُستخدم فقط للأدوية والأعراض — لتتمكّن من إيقافها ومحوها وحدها."),
                LocalizedString(
                    en: "Both databases are excluded from iCloud and device backups, and are "
                        + "protected with iOS file protection (encrypted at rest). There is no cloud "
                        + "copy and no sync. If you delete the app, the databases go with it.",
                    ar: "كلتا القاعدتين مستبعدتان من نسخ iCloud ونسخ الجهاز الاحتياطية، ومحميّتان "
                        + "بحماية ملفات iOS (مشفّرتان أثناء التخزين). لا توجد نسخة سحابية ولا مزامنة. "
                        + "وإن حذفت التطبيق ذهبت القاعدتان معه."),
            ]),
        Section(
            heading: LocalizedString(en: "What BADAN does not do", ar: "ما لا يفعله بدن"),
            paragraphs: [
                // Corrected for ADR-0010/D-22 and ADR-0011/D-37. The previous wording — "makes no
                // network calls", "no telemetry", "the only way data leaves the app is an export you
                // start yourself" — was already false when the AI coach shipped. ADR-0010 §A9
                // required this update before ship and it never landed; it is discharged here.
                LocalizedString(
                    en: "BADAN has no accounts, no third-party SDKs, no crash reporting, and no "
                        + "advertising. It does not track you across apps or websites and collects "
                        + "no advertising identifier.",
                    ar: "ليس في بدن حسابات ولا حزم برمجية خارجية ولا تقارير أعطال ولا إعلانات. ولا "
                        + "يتعقّبك عبر التطبيقات أو المواقع، ولا يجمع أي معرّف إعلاني."),
                LocalizedString(
                    en: "BADAN reaches the internet in exactly three situations, and each one is "
                        + "something you switched on or started yourself: an export you send to a "
                        + "destination you configured; the AI coach, if you enabled it, which sends "
                        + "your question and nothing else; and methodology feedback, if you enabled "
                        + "it, described below. Nothing else in the app opens a connection — "
                        + "recording, scores and export files are all produced on this device.",
                    ar: "يتصل بدن بالإنترنت في ثلاث حالات فقط، وكلٌّ منها شيء فعّلته أو بدأته بنفسك: "
                        + "تصدير ترسله إلى وجهة أعددتها؛ والمدرّب الذكي، إن فعّلته، ويرسل سؤالك ولا "
                        + "شيء غيره؛ وملاحظات المنهجية، إن فعّلتها، الموضّحة أدناه. لا شيء آخر في "
                        + "التطبيق يفتح اتصالاً — فالتسجيل والدرجات وملفات التصدير تُنتَج على هذا الجهاز."),
                // D-37, stated as a limit rather than as a reassurance. The last sentence is the
                // one users are least likely to expect and most entitled to know: with no
                // identifier there is nothing on the server that is recognisably theirs, so
                // "delete my data" has no meaning there — which is a consequence of the privacy
                // design, not a gap in it.
                LocalizedString(
                    en: "Methodology feedback is off unless you turn it on, and it never includes a "
                        + "reading, a date, a location, or anything that identifies you or your "
                        + "device. It carries only which metric and calculation method you "
                        + "disagreed with, in which direction, and roughly how often — and only "
                        + "after you have answered about that metric at least ten times. You can "
                        + "read every submission it has made, word for word, in Settings. Because "
                        + "it carries no identifier, nothing on the server is recognisably yours, "
                        + "which also means there is nothing there to single out and delete.",
                    ar: "ملاحظات المنهجية معطّلة ما لم تفعّلها، ولا تتضمّن أبداً قراءة أو تاريخاً أو "
                        + "موقعاً أو أي شيء يعرّفك أو يعرّف جهازك. تحمل فقط أي مؤشر وأي طريقة حساب "
                        + "اختلفت معها، وفي أي اتجاه، وتقريباً كم مرة — وفقط بعد إجابتك عن ذلك "
                        + "المؤشر عشر مرات على الأقل. ويمكنك قراءة كل إرسال قامت به، كلمة بكلمة، "
                        + "في الإعدادات. ولأنها لا تحمل أي معرّف، لا شيء على الخادم يخصّك بشكل "
                        + "مميّز، ما يعني أيضاً أنه لا يوجد هناك ما يمكن تحديده وحذفه."),
            ]),
        Section(
            heading: LocalizedString(en: "Your control", ar: "ما تتحكّم فيه"),
            paragraphs: [
                LocalizedString(
                    en: "Export: from Data & privacy → Export, you can export your data as CSV or "
                        + "JSON with a checksummed manifest. The export is created on your device and "
                        + "handed to you; BADAN does not send it anywhere.",
                    ar: "التصدير: من البيانات والخصوصية ← التصدير، يمكنك تصدير بياناتك بصيغة CSV أو "
                        + "JSON مع بيان مُدقَّق بمجموع تحقّق. يُنشَأ التصدير على جهازك ويُسلَّم إليك؛ "
                        + "ولا يرسله بدن إلى أي مكان."),
                LocalizedString(
                    en: "Delete everything: Data management → Delete all data permanently deletes "
                        + "everything on the device across both databases, including anything you "
                        + "logged yourself. This can't be undone.",
                    ar: "حذف كل شيء: إدارة البيانات ← حذف جميع البيانات يحذف نهائياً كل شيء على "
                        + "الجهاز في القاعدتين، بما في ذلك كل ما سجّلته بنفسك. ولا يمكن التراجع عنه."),
                LocalizedString(
                    en: "Erase sensitive records separately: turning off Sensitive records "
                        + "permanently removes all medication and symptom records on their own. "
                        + "And you can revoke Apple Health access anytime in iOS Settings.",
                    ar: "محو السجلات الحساسة وحدها: إيقاف «السجلات الحساسة» يزيل نهائياً جميع سجلات "
                        + "الأدوية والأعراض وحدها. ويمكنك سحب إذن صحة آبل في أي وقت من "
                        + "إعدادات iOS."),
            ]),
        Section(
            heading: LocalizedString(en: "Children", ar: "الأطفال"),
            paragraphs: [
                LocalizedString(
                    en: "BADAN is not directed at children and does not knowingly request or collect "
                        + "personal information from anyone. Because it has no accounts and transmits "
                        + "nothing off the device, it gathers no age or identity information at all.",
                    ar: "بدن ليس موجّهاً للأطفال ولا يطلب أو يجمع عن قصد أي معلومات شخصية من أي أحد. "
                        + "ولأنه بلا حسابات ولا يَنقل شيئاً خارج الجهاز، فهو لا يجمع أي معلومات عن "
                        + "العمر أو الهوية إطلاقاً."),
            ]),
        Section(
            heading: LocalizedString(en: "Health data and wellness", ar: "البيانات الصحية والعافية"),
            paragraphs: [
                LocalizedString(
                    en: "BADAN is a self-tracking and wellness tool, not a medical device. The "
                        + "readings, summaries, and observations it shows are informational only — "
                        + "not a diagnosis and not medical advice. Always consult a qualified health "
                        + "professional about your health.",
                    ar: "بدن أداة للتتبّع الذاتي والعافية، لا جهاز طبي. القراءات والملخّصات "
                        + "والملاحظات التي يعرضها لغرض المعلومات فقط — ليست تشخيصاً ولا استشارة طبية. "
                        + "استشر دائماً مختصّاً صحياً مؤهّلاً بشأن صحتك."),
            ]),
        Section(
            heading: LocalizedString(en: "Changes and contact", ar: "التغييرات والتواصل"),
            paragraphs: [
                LocalizedString(
                    en: "If the app's behavior changes in a way that affects your privacy, this "
                        + "policy and the date above will be updated. The current policy always ships "
                        + "inside the app.",
                    ar: "إن تغيّر سلوك التطبيق بما يؤثّر في خصوصيتك، فسيُحدَّث هذا النص والتاريخ أعلاه. "
                        + "وتُشحَن السياسة الحالية دائماً داخل التطبيق."),
                LocalizedString(
                    en: "Contact: support@binjamshid.com",
                    ar: "التواصل: support@binjamshid.com"),
            ]),
    ]
}
