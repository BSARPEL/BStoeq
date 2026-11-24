import SwiftUI
import BStoeqCore
import ConvertCore

/// The ring's drawing. It decides nothing: `DonutController` fills the model, hit-tests with
/// `DonutGeometry` and writes the status line; this view only paints what the model says.
struct DonutView: View {
    /// What the ring shows right now. Every write goes through `set` so an unchanged value redraws nothing:
    /// AppKit repeats `draggingUpdated` while the pointer rests.
    @MainActor final class Model: ObservableObject {
        enum Hover: Equatable { case slice(Int), hub, rim }
        @Published private(set) var faces = DonutFaces(front: [], back: [])
        @Published private(set) var back = false
        @Published private(set) var hover: Hover?
        /// The pointer has been outside the hub since the ring opened: the hub now means "cancel".
        @Published private(set) var leftHub = false
        @Published private(set) var count = 0
        @Published private(set) var status = " "
        @Published private(set) var note: String?
        /// Drives the opening animation.
        @Published private(set) var shown = false
        private(set) var localizer = Localizer(language: .system)
        private(set) var scheme: ColorScheme?

        var slices: [DonutSlice] { back ? faces.back : faces.front }
        var geometry: DonutGeometry { DonutGeometry(count: slices.count) }
        var hasBack: Bool { !faces.back.isEmpty }

        func reset(faces: DonutFaces, count: Int, localizer: Localizer, scheme: ColorScheme?) {
            self.localizer = localizer; self.scheme = scheme
            set(\.faces, faces); set(\.back, false); set(\.hover, nil); set(\.leftHub, false)
            set(\.count, count); set(\.shown, false)
        }
        func setHover(_ hover: Hover?) {
            if hover != .hub, hover != nil { set(\.leftHub, true) }
            set(\.hover, hover)
        }
        func flip() { set(\.back, !back); set(\.hover, nil) }
        func setStatus(_ status: String, note: String?) { set(\.status, status); set(\.note, note) }
        func setShown(_ shown: Bool) { set(\.shown, shown) }

        private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Model, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
    }

    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room above the ring's band for the status pill, kept on both sides so the ring stays centred.
    static let pillSpace: CGFloat = 56
    /// The panel's side.
    static var side: CGFloat { DonutGeometry(count: 0).extent + 2 * pillSpace }

    private func L(_ key: String, _ arguments: CVarArg...) -> String { model.localizer.text(key, arguments: arguments) }

    var body: some View {
        let geometry = model.geometry
        ZStack {
            // Fully transparent pixels let a drag through to the window below. This barely visible disc makes
            // the ring, the hub and the band around them the panel's, so a near miss is refused, not dropped.
            Circle().fill(Color.black.opacity(0.02)).frame(width: geometry.extent, height: geometry.extent)
            ZStack {
                ForEach(Array(model.slices.enumerated()), id: \.element.id) { index, slice in
                    wedge(slice, index: index, geometry: geometry)
                }
                hub(geometry)
            }
            .scaleEffect(model.shown || reduceMotion ? 1 : 0.86).opacity(model.shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.shown)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.back)
            pill.offset(y: -(geometry.outerRadius + geometry.margin + 20)).opacity(model.shown ? 1 : 0)
        }
        .frame(width: Self.side, height: Self.side)
        .tint(Palette.accent)
        .environment(\.locale, Locale(identifier: model.localizer.language.rawValue))
        .preferredColorScheme(model.scheme)
    }

    private func wedge(_ slice: DonutSlice, index: Int, geometry: DonutGeometry) -> some View {
        let hovered = model.hover == .slice(index) && slice.enabled
        let label = slice.titleIsKey ? L(slice.shortTitle) : slice.shortTitle
        let point = geometry.labelPoint(of: index)
        return ZStack {
            let shape = Wedge(start: geometry.midAngle(of: index) - geometry.sweep / 2, sweep: geometry.sweep,
                              inner: geometry.innerRadius, outer: geometry.outerRadius, gap: 2)
            if hovered { shape.fill(Palette.accent) } else { shape.fill(.regularMaterial) }
            VStack(spacing: 3) {
                Image(systemName: slice.symbol).font(.system(size: 17)).accessibilityHidden(true)
                Text(verbatim: label).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 78)
            .foregroundStyle(hovered ? Color.white : Color.primary)
            .offset(x: point.x, y: -point.y)
        }
        .opacity(slice.enabled ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slice.titleIsKey ? L(slice.title) : slice.title)
        .accessibilityAddTraits(hovered ? .isSelected : [])
    }

    private func hub(_ geometry: DonutGeometry) -> some View {
        ZStack {
            Circle().fill(.regularMaterial)
            // The way out shows only once the pointer has come back to the hub: it starts there.
            if model.hover == .hub, model.leftHub {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Text(verbatim: "\(model.count)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            }
        }
        .frame(width: (geometry.innerRadius - 4) * 2, height: (geometry.innerRadius - 4) * 2)
        .accessibilityHidden(true)
    }

    private var pill: some View {
        VStack(spacing: 2) {
            Text(verbatim: model.status).font(.system(size: 11)).lineLimit(1)
            if let note = model.note {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: Self.side - 24)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    /// One slice of the band: an annular sector whose straight sides are moved in by half the gap, so the
    /// gap is equally wide from the hub to the rim. Angles are measured from 12 o'clock, clockwise.
    private struct Wedge: Shape {
        let start: CGFloat, sweep: CGFloat, inner: CGFloat, outer: CGFloat, gap: CGFloat

        func path(in rect: CGRect) -> Path {
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            // Up and clockwise on screen is the drawing system's angle minus a quarter turn (y grows downwards).
            func angle(_ value: CGFloat) -> Angle { .radians(Double(value - .pi / 2)) }
            func inset(_ radius: CGFloat) -> CGFloat { sweep >= 2 * .pi ? 0 : asin(min(1, gap / 2 / radius)) }
            var path = Path()
            path.addArc(center: centre, radius: outer, startAngle: angle(start + inset(outer)),
                        endAngle: angle(start + sweep - inset(outer)), clockwise: false)
            path.addArc(center: centre, radius: inner, startAngle: angle(start + sweep - inset(inner)),
                        endAngle: angle(start + inset(inner)), clockwise: true)
            path.closeSubpath()
            return path
        }
    }
}
