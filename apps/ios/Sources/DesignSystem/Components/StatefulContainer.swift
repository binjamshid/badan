import SwiftUI

/// The four states any data-backed surface can be in. Modelled explicitly so screens can't
/// forget the empty/error paths.
enum LoadState<T> {
    case loading
    case empty(String)
    case error(String)
    case loaded(T)
}

/// Switches over a `LoadState`, rendering calm loading/empty/error surfaces or handing the
/// loaded value to its content. No idle spinners of drama — quiet by default.
struct StatefulContainer<T, Content: View>: View {
    var state: LoadState<T>
    @ViewBuilder var content: (T) -> Content

    init(_ state: LoadState<T>, @ViewBuilder content: @escaping (T) -> Content) {
        self.state = state
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            VStack(spacing: BadanSpace.space3) {
                ProgressView()
                    .tint(BadanColor.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BadanSpace.space7)
        case .empty(let message):
            EmptyStateView(
                icon: "tray",
                title: message,
                message: ""
            )
        case .error(let message):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: message,
                message: ""
            )
        case .loaded(let value):
            content(value)
        }
    }
}

/// A gentle empty/error surface: icon, title, supporting message and an optional action. The
/// action honours the 44pt minimum touch target.
struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(icon: String, title: String, message: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: BadanSpace.space3) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(BadanFont.sectionTitle)
                .foregroundStyle(BadanColor.textPrimary)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(BadanFont.body.weight(.medium))
                        .frame(minHeight: BadanSpace.touchMin)
                        .padding(.horizontal, BadanSpace.space5)
                }
                .foregroundStyle(BadanColor.primary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BadanSpace.space7)
        .padding(.horizontal, BadanSpace.space5)
    }
}
