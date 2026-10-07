import SwiftUI

/// The layout Volisle's sheets share, like the sheets in System Settings: an
/// icon, the title and what the sheet is for at the top, then the content
/// (usually a grouped form, as in Settings), then a bar of buttons — secondary
/// actions on the left, the way out and the main action on the right.
/// The sheet is as tall as its content: nothing floats in empty space.
struct SheetScaffold<Content: View, Buttons: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let systemImage: String
    private let tint: Color
    private let content: Content
    private let buttons: Buttons

    init(_ title: Text, subtitle: Text? = nil, systemImage: String, tint: Color = .accentColor,
         @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A lone title sits level with the icon; with a subtitle both start at its top.
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 14) {
                SheetIcon(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        subtitle.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 22)
            content
            Divider()
            HStack(spacing: 8) { buttons }
                .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
}

/// A white glyph on a colored rounded square, like the icons in System Settings.
struct SheetIcon: View {
    let systemImage: String
    let tint: Color
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Stands in for a sheet's form while it loads, or when there is nothing to show.
struct SheetPlaceholder: View {
    /// Nil shows a spinner.
    var systemImage: String? = nil
    var tint: Color = .secondary
    let title: Text
    var message: Text? = nil
    var body: some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 34)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint).padding(.bottom, 2).accessibilityHidden(true)
            } else {
                ProgressView().padding(.bottom, 4)
            }
            title.font(.headline)
            if let message {
                message.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.horizontal, 32)
    }
}

extension View {
    /// A grouped form on the sheet's own background, as in Settings.
    func sheetForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }

    /// Notes under a form section, aligned with the rows rather than centered.
    func sectionNote() -> some View {
        font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
    }

    /// A message that stays in view between the content and the buttons.
    func sheetStatus() -> some View {
        font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 14)
    }

    /// A text field that looks editable, next to its label in a form row.
    func formField() -> some View {
        labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 220)
    }
}
