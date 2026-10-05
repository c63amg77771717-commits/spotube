#if DEBUG
import SwiftUI
import UIKit

/// CI-only observation of real window hit testing; creates no touches or AX elements.
struct NativeHitProbe: UIViewRepresentable {
    let name: String
    func makeUIView(context: Context) -> NativeHitProbeView {
        let view = NativeHitProbeView()
        view.name = name
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: NativeHitProbeView, context: Context) { view.name = name }
}

final class NativeHitProbeView: UIView {
    var name = ""
    private var scheduled = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !scheduled else { return }
        scheduled = true
        for delay in [1.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.report() }
        }
    }
    private func report() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let rect = convert(bounds, to: window)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard point.x.isFinite, point.y.isFinite else { return }
        let hit = window.hitTest(point, with: nil)
        var chain: [[String: Any]] = []
        var current = hit
        while let view = current, chain.count < 16 {
            chain.append(["class": NSStringFromClass(type(of: view)), "frame": NSStringFromCGRect(view.frame),
                "hidden": view.isHidden, "alpha": view.alpha, "interaction": view.isUserInteractionEnabled,
                "axHidden": view.accessibilityElementsHidden, "axModal": view.accessibilityViewIsModal])
            current = view.superview
        }
        let root = window.rootViewController
        var presented = root
        while let next = presented?.presentedViewController { presented = next }
        let belongsToPresented: Bool
        if let hit, let presentedView = presented?.view {
            belongsToPresented = hit.isDescendant(of: presentedView)
        } else { belongsToPresented = false }
        let value: [String: Any] = ["name": name, "time": Date().timeIntervalSince1970,
            "frame": NSStringFromCGRect(rect), "point": NSStringFromCGPoint(point),
            "window": NSStringFromClass(type(of: window)), "keyWindow": window.isKeyWindow,
            "hitExists": hit != nil, "hitIsProbe": hit === self,
            "hitBelongsToPresented": belongsToPresented,
            "rootController": root.map { NSStringFromClass(type(of: $0)) } ?? "none",
            "presentedController": presented.map { NSStringFromClass(type(of: $0)) } ?? "none",
            "hitChain": chain]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8) else { return }
        print("EVANTUBE_NATIVE_HIT " + text)
    }
}
#endif
