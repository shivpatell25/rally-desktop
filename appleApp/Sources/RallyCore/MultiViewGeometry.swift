import Foundation

public enum MultiViewGeometry {
    /// Tight adjacent bounds; the renderer fits its video inside each cell.
    public static func frames(count: Int, width: Double, height: Double, immersive: Bool, focus: Bool = false) -> [CGRect] {
        guard count > 0, width > 0, height > 0 else { return [] }
        let gap: Double = immersive ? 0 : 8
        if count == 1 { return [CGRect(x: 0, y: 0, width: width, height: height)] }
        if focus {
            let main = (width - gap) * 0.67, sidebar = width - main - gap
            let sideHeight = (height - gap * Double(count - 2)) / Double(count - 1)
            return [CGRect(x: 0, y: 0, width: main, height: height)] + (0..<(count - 1)).map { CGRect(x: main + gap, y: Double($0) * (sideHeight + gap), width: sidebar, height: sideHeight) }
        }
        let rows = count > 2 ? 2 : 1
        let w = (width - gap) / 2, h = (height - gap * Double(rows - 1)) / Double(rows)
        return (0..<count).map { index in
            let x = count == 3 && index == 2 ? (width - w) / 2 : Double(index % 2) * (w + gap)
            return CGRect(x: x, y: Double(index / 2) * (h + gap), width: w, height: h)
        }
    }
}
