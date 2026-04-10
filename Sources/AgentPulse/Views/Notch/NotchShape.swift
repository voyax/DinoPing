import SwiftUI

/// Notch-matching shape: concave top corners (match physical notch) + convex bottom corners.
struct NotchShape: Shape, Animatable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    static let closed = NotchShape(topRadius: 6, bottomRadius: 20)
    static let opened = NotchShape(topRadius: 22, bottomRadius: 36)
    static let pill = NotchShape(topRadius: 12, bottomRadius: 12) // non-notch floating

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tr = min(topRadius, w / 4, h / 4)
        let br = min(bottomRadius, w / 4, h / 4)

        var p = Path()
        p.move(to: .init(x: 0, y: 0))
        p.addQuadCurve(to: .init(x: tr, y: tr), control: .init(x: tr, y: 0))
        p.addLine(to: .init(x: tr, y: h - br))
        p.addQuadCurve(to: .init(x: tr + br, y: h), control: .init(x: tr, y: h))
        p.addLine(to: .init(x: w - tr - br, y: h))
        p.addQuadCurve(to: .init(x: w - tr, y: h - br), control: .init(x: w - tr, y: h))
        p.addLine(to: .init(x: w - tr, y: tr))
        p.addQuadCurve(to: .init(x: w, y: 0), control: .init(x: w - tr, y: 0))
        p.closeSubpath()
        return p
    }
}
