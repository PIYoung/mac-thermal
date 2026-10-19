import Foundation
import CoreGraphics

@main
enum DashboardLayoutProbe {
    static func main() {
        let primary = NSSize(width: 340, height: 420)
        let companion = NSSize(width: 300, height: 420)
        let screens = [NSRect(x: 0, y: 0, width: 1512, height: 944),
                       NSRect(x: -1440, y: 130, width: 1440, height: 875),
                       NSRect(x: 1512, y: -300, width: 1024, height: 720),
                       NSRect(x: 0, y: 0, width: 640, height: 440)]
        var checked = 0
        for screen in screens {
            for offset in stride(from: CGFloat(0), through: screen.width, by: 37) {
                for width: CGFloat in [18, 76, 336] {
                    let anchor = NSRect(x: screen.minX + offset - width / 2,
                                        y: screen.maxY, width: width, height: 22)
                    for optionalCompanion in [Optional<NSSize>.none, companion] {
                        let layout = DashboardLayout.make(anchor: anchor, screen: screen,
                                                          primary: primary, companion: optionalCompanion)
                        let visible = layout.windowFrame.insetBy(dx: 24, dy: 24)
                        precondition(visible.minX >= screen.minX + 7.9 && visible.maxX <= screen.maxX - 7.9)
                        precondition(visible.minY >= screen.minY + 7.9 && visible.maxY <= screen.maxY - 1.9)
                        precondition(abs(visible.maxY - (screen.maxY - 2)) < 0.1,
                                     "Opening must preserve the 2pt menu gap")
                        precondition(layout.primarySurface.size == primary)
                        precondition(layout.primaryFrame.size == NSSize(width: 388, height: 468))
                        if optionalCompanion != nil {
                            let other = layout.companionSurface!
                            precondition(other.size == companion)
                            if screen.width >= 668 {
                                precondition(!layout.scrollsVertically)
                                precondition(layout.primarySurface.minY == other.minY)
                                let distance = max(layout.primarySurface.minX, other.minX) - min(layout.primarySurface.maxX, other.maxX)
                                precondition(distance == 12)
                                precondition(other.maxX + 12 == layout.primarySurface.minX,
                                             "Codex must remain to the left for every anchor and screen")
                            } else {
                                precondition(layout.scrollsVertically && other.minY == layout.primarySurface.maxY + 12)
                            }
                        } else {
                            precondition(layout.companionSurface == nil && !layout.scrollsVertically)
                        }
                        checked += 1
                    }
                }
            }
        }
        print("Dashboard layout passed: \(checked) opening fixtures, both sides, secondary screens, fixed gap and narrow-screen scrolling fallback")
    }
}
