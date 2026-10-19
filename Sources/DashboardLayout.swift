import Foundation
import CoreGraphics

/// Two independent surfaces share a window so their shadow margins cannot
/// intercept sibling-window clicks. Geometry changes only when opening.
struct DashboardLayout {
    let windowFrame: NSRect
    let documentSize: NSSize
    let primaryFrame: NSRect
    let companionFrame: NSRect?
    let primarySurface: NSRect
    let companionSurface: NSRect?
    let scrollsVertically: Bool

    static func make(anchor: NSRect, screen: NSRect, primary: NSSize,
                     companion: NSSize?, inset: CGFloat = 24, gap: CGFloat = 12) -> Self {
        let usable = NSRect(x: screen.minX + 8, y: screen.minY + 8,
                            width: max(0, screen.width - 16), height: max(0, screen.height - 10))
        let horizontal = companion.map { primary.width + gap + $0.width <= usable.width } ?? true
        let primaryOrigin: NSPoint
        let companionOrigin: NSPoint?
        let bodySize: NSSize
        if let companion, horizontal {
            primaryOrigin = NSPoint(x: inset + companion.width + gap, y: inset)
            companionOrigin = NSPoint(x: inset, y: inset)
            bodySize = NSSize(width: primary.width + gap + companion.width, height: max(primary.height, companion.height))
        } else if let companion {
            primaryOrigin = NSPoint(x: inset, y: inset)
            companionOrigin = NSPoint(x: inset, y: inset + primary.height + gap)
            bodySize = NSSize(width: max(primary.width, companion.width), height: primary.height + gap + companion.height)
        } else {
            primaryOrigin = NSPoint(x: inset, y: inset)
            companionOrigin = nil
            bodySize = primary
        }
        let visibleHeight = min(bodySize.height, max(120, usable.height))
        let documentSize = NSSize(width: bodySize.width + inset * 2, height: bodySize.height + inset * 2)
        let primaryOffset = primaryOrigin.x - inset
        let idealX = anchor.midX - primary.width / 2 - primaryOffset
        let bodyX = min(max(idealX, usable.minX), max(usable.minX, usable.maxX - bodySize.width))
        let top = min(anchor.minY, screen.maxY) - 2
        let bodyY = min(max(top - visibleHeight, usable.minY), max(usable.minY, usable.maxY - visibleHeight))
        let frame = NSRect(x: bodyX - inset, y: bodyY - inset,
                           width: documentSize.width, height: visibleHeight + inset * 2)
        let primaryFrame = NSRect(x: primaryOrigin.x - inset, y: primaryOrigin.y - inset,
                                  width: primary.width + inset * 2, height: primary.height + inset * 2)
        let companionFrame = companion.flatMap { size in companionOrigin.map {
            NSRect(x: $0.x - inset, y: $0.y - inset, width: size.width + inset * 2, height: size.height + inset * 2)
        } }
        return Self(windowFrame: frame, documentSize: documentSize,
                    primaryFrame: primaryFrame, companionFrame: companionFrame,
                    primarySurface: NSRect(origin: primaryOrigin, size: primary),
                    companionSurface: companion.flatMap { size in companionOrigin.map { NSRect(origin: $0, size: size) } },
                    scrollsVertically: bodySize.height > visibleHeight)
    }
}
