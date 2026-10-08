import Foundation
import CoreGraphics

enum AttachmentCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, free

    var title: String {
        switch self {
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        case .free: return "自由"
        }
    }
}

struct WindowChromeInsets {
    let top: CGFloat
    let bottom: CGFloat
}

enum WindowGeometry {
    static let panelSize = CGSize(width: 203, height: 117)

    static func appKitFrame(_ frame: CGRect, displayBounds: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + frame.minX - displayBounds.minX,
               y: screenFrame.maxY - (frame.minY - displayBounds.minY) - frame.height,
               width: frame.width, height: frame.height)
    }

    static func attachmentFrame(window: CGRect, visibleScreen: CGRect,
                                corner: AttachmentCorner, chrome: WindowChromeInsets,
                                size: CGSize = panelSize) -> CGRect? {
        guard corner != .free else { return nil }
        guard chrome.top.isFinite, chrome.bottom.isFinite,
              chrome.top >= 0, chrome.bottom >= 0 else { return nil }
        // The bar heights are measured; a 4pt visual gap preserves the accepted top alignment.
        let content = CGRect(x: window.minX + 14, y: window.minY + chrome.bottom + 4,
                             width: window.width - 28,
                             height: window.height - chrome.top - chrome.bottom - 8)
        let available = content.intersection(visibleScreen.insetBy(dx: 14, dy: 14))
        guard content.width > 0, content.height > 0, !available.isNull,
              available.width >= size.width, available.height >= size.height else { return nil }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? available.minX : available.maxX - size.width,
                      y: top ? available.maxY - size.height : available.minY,
                      width: size.width, height: size.height)
    }

    static func isTargetWindow(pid: Int32, targetPID: Int32, layer: Int,
                               alpha: Double, bounds: CGRect) -> Bool {
        pid == targetPID && layer == 0 && alpha > 0
            && bounds.width >= 300 && bounds.height >= 230
            && bounds.minX.isFinite && bounds.minY.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
    }
}
