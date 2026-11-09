import SwiftUI

/// A sidebar that slides in from the leading edge and pushes the page aside.
///
/// iPhone has no built-in drawer, so this draws one: drag from the leading edge or
/// tap the sidebar button to open it, and tap the page or drag back to close it.
struct SidebarShell<Sidebar: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.82, 340)
            let offset = clamped((isOpen ? width : 0) + drag, to: width)
            ZStack(alignment: .leading) {
                sidebar
                    .frame(width: width)
                    .offset(x: (offset - width) * 0.3)
                    // A closed sidebar still sits under the page, so keep VoiceOver out of it.
                    .accessibilityHidden(!isOpen)
                content
                    .accessibilityHidden(isOpen)
                    .environment(\.openSidebar, OpenSidebarAction { isOpen = true })
                    .frame(width: proxy.size.width)
                    .overlay {
                        Color.black.opacity(0.25 * offset / width)
                            .ignoresSafeArea()
                            .allowsHitTesting(isOpen)
                            .onTapGesture { isOpen = false }
                    }
                    .clipShape(.rect(cornerRadius: offset > 0 ? 28 : 0))
                    .shadow(color: .black.opacity(offset > 0 ? 0.15 : 0), radius: 12)
                    .offset(x: offset)
                    .ignoresSafeArea()
            }
            .gesture(dragGesture(width: width), including: isOpen ? .all : .subviews)
            .simultaneousGesture(edgeGesture(width: width))
            .animation(.snappy(duration: 0.3), value: isOpen)
        }
    }

    /// Opens from a drag that starts near the leading edge.
    private func edgeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                guard !isOpen, value.startLocation.x < 28 else { return }
                state = max(0, value.translation.width)
            }
            .onEnded { value in
                guard !isOpen, value.startLocation.x < 28 else { return }
                if value.predictedEndTranslation.width > width / 2 { isOpen = true }
            }
    }

    /// Closes from a drag back toward the leading edge while open.
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                guard isOpen else { return }
                state = min(0, value.translation.width)
            }
            .onEnded { value in
                guard isOpen else { return }
                if value.predictedEndTranslation.width < -width / 3 { isOpen = false }
            }
    }

    private func clamped(_ value: CGFloat, to width: CGFloat) -> CGFloat {
        min(max(value, 0), width)
    }
}

/// Opens the app sidebar from any screen inside the shell.
struct OpenSidebarAction {
    let open: @MainActor () -> Void
    @MainActor func callAsFunction() { open() }
}

extension EnvironmentValues {
    @Entry var openSidebar = OpenSidebarAction {}
}

/// The toolbar button that opens the sidebar, placed on each app's first screen.
struct SidebarButton: ToolbarContent {
    @Environment(\.openSidebar) private var openSidebar

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Menu", systemImage: "line.3.horizontal") { openSidebar() }
        }
    }
}
