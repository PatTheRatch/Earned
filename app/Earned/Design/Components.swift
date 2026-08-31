import SwiftUI

// The reusable primitives of the v2 system (docs/design-language.md). Every
// top-level surface is built from these rather than from stock Form styling,
// which is what makes the whole app read as one product instead of an app
// containing Earned.

/// The scaffold for a poster-voiced page: paper, left-aligned, one padding.
struct PosterPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
    }
}

/// The masthead every top-level screen opens with: the small-caps brand
/// kicker, then the page's one declaration.
struct PageHeader: View {
    var kicker: String = "Earned"
    let title: String
    var titleColor: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: kicker, color: Theme.ink)
            StateWord(word: title, size: 56)
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A hairline where a thick rule would shout.
struct HairRule: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

/// One scoreboard figure with its quiet caption. The screen's answer, in the
/// factual voice — never a score to chase.
struct Metric: View {
    let value: String
    let caption: String
    var size: CGFloat = 44
    var color: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.metric(size))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(Theme.footnote)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value), \(caption)")
    }
}

/// A rule-separated content row: small-caps label, one bold line, quiet
/// context. The unit Today taught the rest of the app.
struct PosterRow<Line: View>: View {
    let label: String
    @ViewBuilder var line: Line
    var context: String?
    var chevron: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThickRule()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: label)
                    line
                    if let context {
                        Text(context).font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, Theme.rowSpacing)
        }
        .contentShape(Rectangle())
    }
}

/// A single selectable answer in the creation flow: square marker, plain
/// words. Replaces pickers dropped into poster layouts.
struct ChoiceRow: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Rectangle()
                    .strokeBorder(Theme.ink, lineWidth: 2)
                    .background(Rectangle().fill(selected ? Theme.ink : .clear))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: selected ? .bold : .regular))
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle).font(Theme.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One line of the contract, as a receipt prints it: quiet label on the
/// left, the term set in the bold factual voice.
struct ReceiptRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairRule()
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: label)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(Theme.blocker(16))
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A navigation destination on a poster page: rule, name, current value.
struct DestinationRow: View {
    let title: String
    var detail: String?
    var detailColor: Color = Theme.muted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairRule()
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let detail {
                    Text(detail).font(Theme.footnote).foregroundStyle(detailColor)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 13)
        }
        .contentShape(Rectangle())
    }
}

/// An empty state that explains the product instead of apologising for the
/// database. Title in the declaration voice, one factual line under it.
struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.display(28))
                .foregroundStyle(Theme.ink)
            + Text(".").font(Theme.display(28)).foregroundStyle(Theme.signal)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A small status declaration: ACTIVE, REQUEST SENT, OVERDUE. Signal color
/// only when it names a consequence.
struct StatusTag: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

/// Progressive disclosure: a quiet ⓘ that opens the reasoning on demand,
/// so the primary UI never carries the paragraph.
struct InfoButton: View {
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Earned", color: Theme.ink)
                    .padding(.top, 8)
                Text(title.uppercased())
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.paper)
            .presentationDetents([.medium])
        }
    }
}

/// The quiet underlined text action — the secondary voice next to a poster
/// button.
struct UnderlineButtonStyle: ButtonStyle {
    var color: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 2) }
            .frame(minHeight: 44, alignment: .center)
    }
}
