import SwiftUI
import UIKit

// MARK: - GalleryBackgroundView

struct GalleryBackgroundView: View {
    @EnvironmentObject var bg: BackgroundService
    @AppStorage("app_reduce_motion") private var reduceMotion = false
    @AppStorage(GalleryBackgroundSource.storageKey) private var backgroundSource = GalleryBackgroundSource.photos.rawValue

    var body: some View {
        switch backgroundSource {
        case GalleryBackgroundSource.sonic.rawValue:
            SonicWallpaperView()
        case GalleryBackgroundSource.reactive.rawValue:
            ReactiveAuraBackgroundView()
        default:
            photoBackground
        }
    }

    private var photoBackground: some View {
        // GeometryReader gives an exact screen-sized canvas so scaledToFill can't
        // push outside the ZStack and stretch the parent layout.
        GeometryReader { geo in
            ZStack {
                if InterfaceEdition.isLumen {
                    // Lumen's lit ground replaces the flat fill; a user's
                    // own gallery photos still draw over it.
                    LumenBackdrop()
                } else {
                    AppTheme.background
                }

                // Read directly from the service — no intermediate @State needed.
                // The gallery engine (Rust) picks what's on screen; the service
                // hands over the decoded image and its entry id, and a change
                // of id drives the transition.
                if bg.isEnabled, let image = bg.currentImage, let id = bg.currentEntryID {
                    // Driving the swap through a single-element ForEach (rather
                    // than a bare `.id()` on one conditional Image) is what makes
                    // the crossfade actually overlap: ForEach tracks the leaving
                    // image (index N) and the entering image (index N+1) as two
                    // distinct elements, so the outgoing view runs its *removal*
                    // transition on top of the incoming one instead of being
                    // yanked instantly — which is why every animation previously
                    // blanked to the background before the next image faded in.
                    ZStack {
                        // Keyed on the gallery entry (from the Rust gallery
                        // engine), so each change runs the transition.
                        ForEach([id], id: \.self) { _ in
                            AnimatedImageView(image: image, contentMode: .scaleAspectFill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .modifier(KenBurnsModifier(isActive: bg.kenBurnsEnabled && !reduceMotion))
                                .blur(radius: bg.blurRadius, opaque: true)
                                .opacity(bg.opacity)
                                // WAS `.drawingGroup()` — found via a live view-hierarchy
                                // dump (recursiveDescription) captured while the reported
                                // "large system-icon-looking image stuck in gallery
                                // background" was on screen: the dump showed BackgroundService's
                                // own state as completely healthy (enabled, 66 valid images,
                                // rotation actively advancing) yet contained no full-screen
                                // UIImageView anywhere in the tree — only two unrelated 4pt-tall
                                // separator-line images. `drawingGroup()` forces SwiftUI to
                                // rasterize its subtree into an offscreen Metal texture, which
                                // is well-defined for pure SwiftUI drawing primitives (Shape,
                                // Image, Text) but `AnimatedImageView` here is a
                                // `UIViewRepresentable`-backed REAL UIKit `UIImageView`, not a
                                // SwiftUI-drawn primitive — asking Metal to snapshot a live
                                // embedded UIView's content into a texture is a much less
                                // reliable operation, and evidently was failing outright rather
                                // than falling back to just drawing the photo, explaining why no
                                // amount of resetting the data/cache/device ever helped: the bug
                                // was structural, not something a good state could route around.
                                // `.compositingGroup()` gets the same "apply opacity/blur to the
                                // whole KenBurns+blur+opacity chain as one unit rather than each
                                // modifier separately" grouping semantics WITHOUT forcing that
                                // texture rasterization, and is Apple's documented choice for
                                // exactly this "group for compositing, don't force a bitmap"
                                // case — the safer option once real UIKit content is involved.
                                .compositingGroup()
                                // Reduce Motion drops every transition to a plain
                                // cross-fade — the simplest, least motion-heavy
                                // option — regardless of the chosen animation.
                                .transition(reduceMotion ? .opacity : transitionForAnimation(bg.animation))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Transition Factory

    func transitionForAnimation(_ anim: BackgroundAnimation) -> AnyTransition {
        switch anim {
        case .fade:      return .opacity
        case .slideLeft: return .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        case .slideRight: return .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        case .slideUp:   return .asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top))
        case .slideDown: return .asymmetric(insertion: .move(edge: .top), removal: .move(edge: .bottom))
        case .zoomIn:    return .scale(scale: 0.8).combined(with: .opacity)
        case .zoomOut:   return .scale(scale: 1.2).combined(with: .opacity)
        // Zoom Blur — the incoming image rushes in from larger-than-screen while
        // sharpening from a blur.
        case .zoomBlur:  return .scale(scale: 1.4)
            .combined(with: .modifier(active: BlurTransitionModifier(radius: 24),
                                      identity: BlurTransitionModifier(radius: 0)))
            .combined(with: .opacity)
        case .flip:      return .asymmetric(
            insertion: .scale(scale: 0.01, anchor: .center).combined(with: .opacity),
            removal:   .scale(scale: 0.01, anchor: .center).combined(with: .opacity)
        )
        // Twist — images rotate + scale as they swap.
        case .twist:     return .asymmetric(
            insertion: .modifier(active: TwistTransitionModifier(angle: -25, scale: 0.7),
                                 identity: TwistTransitionModifier(angle: 0, scale: 1)).combined(with: .opacity),
            removal:   .modifier(active: TwistTransitionModifier(angle: 25, scale: 0.7),
                                 identity: TwistTransitionModifier(angle: 0, scale: 1)).combined(with: .opacity)
        )
        // "Blur In brings the next image into focus" (per the Help screen) — the
        // incoming image should visibly sharpen from a blur, not just crossfade
        // like .fade does. A bare .opacity here made "Blur In" indistinguishable
        // from "Fade", silently dropping the feature its own label promises.
        case .blur:  return .modifier(
            active:   BlurTransitionModifier(radius: 28),
            identity: BlurTransitionModifier(radius: 0)
        ).combined(with: .opacity)
        case .none:  return .identity
        }
    }
}

// MARK: - Ken Burns Modifier

/// Slow, continuous zoom/drift applied to the currently-displayed background
/// image — independent of the crossfade/slide transition between images.
/// Scales up slightly beyond the transition's own scale so the pan never
/// exposes an edge (the image is already `.scaledToFill()` + `.clipped()`).
private struct KenBurnsModifier: ViewModifier {
    let isActive: Bool
    /// Heat governor: no motion when hot, in Low Power Mode or backgrounded.
    @ObservedObject private var governor = HeatGovernor.shared
    /// Every tab keeps its background mounted; only the visible one moves.
    @State private var visible = false

    func body(content: Content) -> some View {
        moving(content)
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }

    @ViewBuilder
    private func moving(_ content: Content) -> some View {
        if isActive && visible && governor.policy.backgroundMotion {
            // `.periodic` at ~12fps instead of `.animation` (which drives at
            // the display's full 60/120Hz) — `GalleryBackgroundView` is
            // instantiated once per tab and `TabView` keeps every tab's
            // hierarchy mounted simultaneously, so with Ken Burns on this
            // driver runs continuously in up to 6 places at once, most of
            // them off-screen. The pan/zoom itself is a slow 30-second leg
            // (see `legDuration` below), so a much lower update rate is
            // visually indistinguishable while cutting the redundant-instance
            // cost by roughly an order of magnitude.
            TimelineView(.periodic(from: .now, by: 1.0 / max(governor.policy.motionFps, 1))) { timeline in
                let phase = CGFloat(ArtworkClock.pingPong(timeline.date, legDuration: 30))
                let scale: CGFloat = 1.08 + 0.05 * phase
                let dx: CGFloat = 14 * (phase - 0.5)
                let dy: CGFloat = 10 * (0.5 - phase)
                content
                    .scaleEffect(scale)
                    .offset(x: dx, y: dy)
            }
        } else if isActive {
            // Held at the start of the pan so pausing doesn't jump the framing.
            content.scaleEffect(1.08)
        } else {
            content
        }
    }
}

// MARK: - Blur Transition Modifier

/// Drives `.blur(radius:)` as an interpolated transition: the incoming image
/// sharpens from `radius` down to 0, the outgoing image blurs from 0 up to `radius`.
private struct BlurTransitionModifier: ViewModifier, Animatable {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

// MARK: - Twist Transition Modifier

/// Interpolates rotation + scale together for the "Twist" transition.
private struct TwistTransitionModifier: ViewModifier, Animatable {
    var angle: CGFloat
    var scale: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(angle, scale) }
        set { angle = newValue.first; scale = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(Double(angle)))
            .scaleEffect(scale)
    }
}
