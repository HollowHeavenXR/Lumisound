import SwiftUI
import UIKit

/// Shows a whole piece of artwork in a frame of any shape: the image fills
/// the frame, and whatever doesn't fit (the sides of a 16:9 video thumbnail
/// in a square card, the top and bottom of a tall poster) is revealed by a
/// slow, eased slide back and forth across it. Square art in a square frame
/// sits still.
///
/// The slide is a Core Animation animation on the image layer, so it runs in
/// the render server: a screen full of panning thumbnails costs the app no
/// per-frame work (a SwiftUI animation would redraw every visible cell at
/// 60-120 Hz and heat the phone). Off when Reduce Motion is on: centered.
struct PanningArtwork: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PanningImageView {
        let v = PanningImageView()
        v.image = image
        return v
    }

    func updateUIView(_ view: PanningImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PanningImageView, context: Context) -> CGSize? {
        // Take exactly the frame SwiftUI offers (the caller sets it).
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class PanningImageView: UIView {
    private let imageLayer = CALayer()
    private static let panKey = "lumisound.pan"
    private var laidOutFor: (CGSize, ObjectIdentifier)?

    var image: UIImage? {
        didSet {
            imageLayer.contents = image?.cgImage
            imageLayer.contentsScale = image?.scale ?? 1
            laidOutFor = nil
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(restart), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(restart), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restart() }
    }

    @objc private func restart() {
        laidOutFor = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image, bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
        let key = (bounds.size, ObjectIdentifier(image))
        if let done = laidOutFor, done.0 == key.0, done.1 == key.1, imageLayer.animation(forKey: Self.panKey) != nil || !wantsPan {
            return
        }
        laidOutFor = key

        // Fill: scale so the image covers the frame on both axes.
        let b = bounds.size
        let aspect = image.size.width / image.size.height
        let fill: CGSize = aspect > b.width / b.height
            ? CGSize(width: b.height * aspect, height: b.height)
            : CGSize(width: b.width, height: b.width / aspect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAnimation(forKey: Self.panKey)
        imageLayer.bounds = CGRect(origin: .zero, size: fill)
        imageLayer.position = CGPoint(x: b.width / 2, y: b.height / 2)
        CATransaction.commit()

        let overflowX = fill.width - b.width
        let overflowY = fill.height - b.height
        let horizontal = overflowX >= overflowY
        let travel = max(overflowX, overflowY)
        // Under a couple of points there's nothing worth revealing.
        guard travel > 2, wantsPan else { return }

        let center = horizontal ? b.width / 2 : b.height / 2
        let anim = CABasicAnimation(keyPath: horizontal ? "position.x" : "position.y")
        anim.fromValue = center + travel / 2
        anim.toValue = center - travel / 2
        // Same visual pace at every size: cross ~6% of the frame per second,
        // never faster than a 5 s sweep.
        let frameExtent = horizontal ? b.width : b.height
        anim.duration = max(5, Double(travel / (frameExtent * 0.06)))
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        // Random phase, so a grid of covers doesn't slide in lockstep.
        anim.timeOffset = Double.random(in: 0..<(anim.duration * 2))
        imageLayer.add(anim, forKey: Self.panKey)
    }

    private var wantsPan: Bool { !UIAccessibility.isReduceMotionEnabled }
}
