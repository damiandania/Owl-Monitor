import SwiftUI

/// Owl Monitor's motion identity: every duration and curve in one place, so the whole app moves with
/// one consistent personality instead of a dozen hand-picked timings.
///
/// Personality: a precise instrument panel. Short durations, one decisive fast-settling curve, and no
/// playful overshoot — except the brief "pop" that confirms a success. Motion here exists to make a
/// STATE CHANGE legible (what just started, stopped, appeared or failed), never to decorate.
///
/// Reduce Motion is decided HERE rather than re-derived in every view: spatial movement (slides,
/// scales, shakes, rotations) collapses to a plain cross-fade, springs become short ease-outs, and
/// nothing loops.
enum Motion {
    // MARK: Duration palette

    /// Micro-feedback: hover, a value ticking over.
    static let quick: Double = 0.15
    /// State changes: a pill going orange → green, a tab selection moving.
    static let standard: Double = 0.28
    /// Whole regions: a panel appearing, a project's dashboard swapping in.
    static let slow: Double = 0.4

    // MARK: Curves

    /// The signature curve (most of the app): fast start, settles with no overshoot.
    static let snappy = Animation.snappy(duration: standard)
    /// Larger regions — the same character, a touch longer and softer.
    static let smooth = Animation.smooth(duration: slow)
    /// Hover and other instant feedback.
    static let feedback = Animation.easeOut(duration: quick)

    // No curve for live, resampling values (meters, CPU %, uptime) — on purpose. Animating something
    // that updates every couple of seconds means rendering frames for a large share of ALL wall time;
    // on macOS SwiftUI does that on the CPU. The meters' glide once cost ~17 % of a core while idle.
    // Animate EVENTS (a server starting, a tab changing), never a steady stream of samples.

    /// A state-change animation, or its Reduce Motion stand-in: a short fade, never a spring.
    static func state(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: quick) : snappy
    }

    /// A whole region arriving or leaving (a panel, an accordion) — `smooth`, or the same short
    /// fade under Reduce Motion.
    static func region(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: quick) : smooth
    }

    /// A spatial animation (a sliding indicator, a growing bar, a rolling digit) — dropped entirely
    /// under Reduce Motion, which asks for things to change in place rather than travel.
    static func spatial(_ reduceMotion: Bool, _ animation: Animation = snappy) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension AnyTransition {
    /// The house entrance: rises 6 pt and settles from 98 % while fading in, and leaves quicker —
    /// fading and easing IN, since exits should get out of the way. Fade-only under Reduce Motion.
    static func rise(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 6))
                .combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98))
                .animation(.easeIn(duration: Motion.quick)))
    }

    /// Small elements (counters, chips, badges): pop in from 60 %. Fade-only under Reduce Motion.
    static func pop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }
}

extension View {
    /// Shake once, horizontally, each time `condition` turns true — the "something went wrong" cue
    /// (a server crashing). Three decaying oscillations that settle firmly at rest. Skipped under
    /// Reduce Motion, where the red colour already carries the message.
    func shake(when condition: Bool) -> some View { modifier(ShakeOnce(active: condition)) }

    /// Swell once to 106 % and settle, each time `condition` turns true — the "that worked" cue (a
    /// build completing, a server coming up). Skipped under Reduce Motion.
    func pop(when condition: Bool) -> some View { modifier(PopOnce(active: condition)) }
}

/// Keyframe-driven so it runs exactly once per trigger. The trigger ALSO changes when `active` flips
/// back to false (recovery), which must not shake — so the offset is applied only while `active`.
/// It never plays on first appearance either: a view that shows up already-failed stays still.
private struct ShakeOnce: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Resolved here, on the main actor: the animator's closure is nonisolated, so it can't read
        // the environment itself.
        let moves = active && !reduceMotion
        return content.keyframeAnimator(initialValue: CGFloat(0), trigger: active) { view, x in
            view.offset(x: moves ? x : 0)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-6, duration: 0.06)
                CubicKeyframe(6, duration: 0.08)
                CubicKeyframe(-4, duration: 0.07)
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(-2, duration: 0.05)
                CubicKeyframe(0, duration: 0.05)
            }
        }
    }
}

/// Same one-shot, trigger-only mechanics as `ShakeOnce`.
private struct PopOnce: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moves = active && !reduceMotion   // see ShakeOnce: resolved on the main actor
        return content.keyframeAnimator(initialValue: CGFloat(1), trigger: active) { view, scale in
            view.scaleEffect(moves ? scale : 1)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.06, duration: 0.12, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.24, spring: .smooth)
            }
        }
    }
}
