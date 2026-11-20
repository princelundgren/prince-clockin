import PrinceClockInCore
import SwiftUI

extension View {
    /// A panel tile's frame: its padding and rounded fill, the same for login and preset tiles.
    func tileFrame(_ fill: AnyShapeStyle) -> some View {
        padding(8)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A tile's fill: a tint of `colour`, or a system fill without one, a step stronger while the
/// pointer is on a tile a click logs in.
func tileFill(colour: ColourToken?, isHovered: Bool) -> AnyShapeStyle {
    guard let colour else {
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }
    return AnyShapeStyle(Color(colour.rawValue).opacity(isHovered ? 0.16 : 0.1))
}

/// A tile's first line as a control: the label alone, dimmed while pressed or disabled.
struct TileButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
    }
}

/// The visible Log In on a due tile, or under the pointer on any tile a click logs in, which the
/// whole tile's button performs, so it is plain text rather than a button's shape. Prominent, on
/// the login Return logs in, it is bold.
struct LogInLabel: View {
    let isProminent: Bool

    var body: some View {
        Text("Log In")
            .bold(isProminent)
            .foregroundStyle(.primary)
    }
}
