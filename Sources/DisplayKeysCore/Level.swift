/// Step arithmetic for brightness and volume, mirroring macOS: 16 coarse steps across the
/// range, or 64 fine steps when Shift-Option is held.
public enum Level {
    public static let coarseSteps = 16
    public static let fineSteps = 64

    /// The next value one step up or down, snapped to the step grid.
    public static func stepped(_ value: DDC.Value, up: Bool, fine: Bool) -> Int {
        let maximum = value.maximum
        guard maximum > 0 else { return 0 }
        let steps = Double(fine ? fineSteps : coarseSteps)
        func gridValue(_ index: Double) -> Int {
            Int((index * Double(maximum) / steps).rounded())
        }

        let position = Double(value.current) * steps / Double(maximum)
        let nearest = position.rounded()
        // Grid points are rounded to whole device values, so compare in device units.
        let isOnGrid = gridValue(nearest) == value.current
        let index = isOnGrid ? nearest + (up ? 1 : -1) : position.rounded(up ? .up : .down)

        var result = gridValue(min(max(index, 0), steps))
        // Ranges shorter than the grid map several grid points to one value; always move.
        if result == value.current { result += up ? 1 : -1 }
        return min(max(result, 0), maximum)
    }

    public static func value(percent: Int, maximum: Int) -> Int {
        Int((Double(min(max(percent, 0), 100)) * Double(maximum) / 100).rounded())
    }
}
