import SwiftUI

// Small pieces every app's screens share, so they look the same everywhere.
// The palette stays gray; color is kept for data, such as a calendar's color or a
// document's type.

/// Says the screen shows sample data, because the site has no mail server.
struct SampleNotice: View {
    var body: some View {
        Label("Sample data. This site has no mail server yet.", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A person's initial in a gray circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .circle)
    }
}

/// A section title with an optional action on the right, for scrolling screens.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            trailing.font(.subheadline)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

extension View {
    /// A white card with a hairline edge, the one box screens use to group things.
    /// What sits inside a card is separated by space, not by lines.
    func card(cornerRadius: CGFloat = 12) -> some View {
        background(Color(.systemBackground), in: .rect(cornerRadius: cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(.separator), lineWidth: 0.5) }
    }
}

/// A capsule button in gray, for secondary actions beside a list.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color(.tertiarySystemFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

/// Gray for swipe actions that are not destructive.
extension Color {
    static let swipe = Color(.systemGray)
}
