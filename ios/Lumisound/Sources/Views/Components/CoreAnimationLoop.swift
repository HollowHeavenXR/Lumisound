import SwiftUI
import UIKit

/// Plays a looping motion (a spin, or a vertical drift) on SwiftUI content
/// using a Core Animation layer animation instead of a `TimelineView`.
///
/// A `TimelineView(.animation(minimumInterval: LumiMotion.frame))` re-runs its closure on the main thread every
/// frame. That is the wrong tool for a loading screen: the screen is up
/// precisely while the main thread is busiest (the snapshot restore, the first
/// scan, the account sync), so every main-thread stall froze the animation and
/// made the app look hung even when it was only busy. It also costs a body
/// evaluation per frame for as long as the screen shows. A `CABasicAnimation`
/// is run by the system render server out of process: it keeps moving through
/// a main-thread stall and costs the app nothing per frame.
///
/// The content is rendered once and moved as a layer, so this suits content
/// that does not itself change every frame. Set `rasterize` for content with
/// expensive effects (a blur) so the render server moves a cached bitmap
/// instead of re-applying the effect each frame.
struct CoreAnimationLoop<Content: View>: UIViewRepresentable {
    enum Motion: Equatable {
        /// One full clockwise turn per `period`.
        case spin(period: TimeInterval)
        /// Moves up by `distance` points per `period`, then jumps back. Seamless
        /// when the content repeats every `distance` points.
        case driftUp(distance: CGFloat, period: TimeInterval)
    }

    let motion: Motion
    let isRunning: Bool
    let rasterize: Bool
    let content: Content

    init(_ motion: Motion, isRunning: Bool = true, rasterize: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.isRunning = isRunning
        self.rasterize = rasterize
        self.content = content()
    }

    func makeUIView(context: Context) -> LoopView {
        let view = LoopView(rootView: content)
        view.configure(motion: motion, isRunning: isRunning, rasterize: rasterize)
        return view
    }

    func updateUIView(_ view: LoopView, context: Context) {
        view.update(rootView: content)
        view.configure(motion: motion, isRunning: isRunning, rasterize: rasterize)
    }

    final class LoopView: UIView {
        private let stage = UIView()
        private let hosting: UIHostingController<Content>
        private var motion: Motion?
        private var isRunning = false
        private var foregroundObserver: NSObjectProtocol?

        init(rootView: Content) {
            hosting = UIHostingController(rootView: rootView)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            hosting.view.backgroundColor = .clear
            stage.backgroundColor = .clear
            stage.addSubview(hosting.view)
            addSubview(stage)
            // Layer animations are removed when the app is backgrounded;
            // put the loop back on the way in.
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAnimation(force: true) }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        }

        func update(rootView: Content) {
            hosting.rootView = rootView
        }

        func configure(motion: Motion, isRunning: Bool, rasterize: Bool) {
            stage.layer.shouldRasterize = rasterize
            stage.layer.rasterizationScale = traitCollection.displayScale
            let changed = motion != self.motion || isRunning != self.isRunning
            self.motion = motion
            self.isRunning = isRunning
            if changed { applyAnimation(force: true) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // `bounds`/`center` rather than `frame`: the stage carries a
            // transform while animating, and `frame` is undefined under one.
            stage.bounds = CGRect(origin: .zero, size: bounds.size)
            stage.center = CGPoint(x: bounds.midX, y: bounds.midY)
            hosting.view.frame = stage.bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stage.layer.rasterizationScale = traitCollection.displayScale
            applyAnimation(force: false)
        }

        private static var animationKey: String { "lumisound.loop" }

        private func applyAnimation(force: Bool) {
            let layer = stage.layer
            guard isRunning, window != nil, let motion else {
                layer.removeAnimation(forKey: Self.animationKey)
                return
            }
            if !force, layer.animation(forKey: Self.animationKey) != nil { return }
            let animation: CABasicAnimation
            switch motion {
            case .spin(let period):
                animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0
                animation.toValue = 2 * Double.pi
                animation.duration = period
            case .driftUp(let distance, let period):
                animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.fromValue = 0
                animation.toValue = -distance
                animation.duration = period
            }
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: Self.animationKey)
        }
    }
}
