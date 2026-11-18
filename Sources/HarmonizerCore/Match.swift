/// A plain-word grade for how well one Transition works (see CONTEXT.md).
/// Working out the Match from key, tempo and energy comes with #16.
public enum Match: String, CaseIterable, Sendable {
    case smooth, energyUp, energyDown, keyChange, clash

    public var title: String {
        switch self {
        case .smooth: "Smooth"
        case .energyUp: "Energy up"
        case .energyDown: "Energy down"
        case .keyChange: "Key change"
        case .clash: "Clash"
        }
    }
}
