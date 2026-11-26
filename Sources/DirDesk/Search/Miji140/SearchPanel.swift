import AppKit
import QuartzCore

@MainActor
class Miji140SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private struct SpringAxis {
        var value: CGFloat
        var target: CGFloat
        var velocity: CGFloat = 0

        mutating func step(dt: CGFloat, stiffness: CGFloat, damping: CGFloat) -> Bool {
            let displacement = value - target
            let accel = -stiffness * displacement - damping * velocity
            velocity += accel * dt
            value += velocity * dt
            if abs(value - target) < 0.15 && abs(velocity) < 1.5 {
                value = target
                velocity = 0
                return true
            }
            return false
        }
    }

    private struct SpringMotion {
        var midX: SpringAxis
        var maxY: SpringAxis
        var width: SpringAxis
        var height: SpringAxis
        var stiffness: CGFloat
        var damping: CGFloat

        init(from: NSRect, to: NSRect, response: CGFloat, dampingRatio: CGFloat, initialWidthVelocity: CGFloat = 0) {
            let omega = 2 * .pi / max(0.08, response)
            self.stiffness = omega * omega
            self.damping = 2 * dampingRatio * omega
            self.midX = SpringAxis(value: from.midX, target: to.midX)
            self.maxY = SpringAxis(value: from.maxY, target: to.maxY)
            self.width = SpringAxis(value: from.width, target: to.width, velocity: initialWidthVelocity)
            self.height = SpringAxis(value: from.height, target: to.height)
        }

        mutating func retarget(to: NSRect, response: CGFloat, dampingRatio: CGFloat) {
            let omega = 2 * .pi / max(0.08, response)
            stiffness = omega * omega
            damping = 2 * dampingRatio * omega
            midX.target = to.midX
            maxY.target = to.maxY
            width.target = to.width
            height.target = to.height
        }

        var targetRect: NSRect {
            NSRect(x: midX.target - width.target / 2,
                   y: maxY.target - height.target,
                   width: width.target,
                   height: height.target)
        }

        var currentRect: NSRect {
            let w = max(220, width.value)
            let h = max(PanelMetrics.searchHeight - 6, height.value)
            return NSRect(x: midX.value - w / 2, y: maxY.value - h, width: w, height: h)
        }

        mutating func step(dt: CGFloat) -> Bool {
            let s1 = midX.step(dt: dt, stiffness: stiffness, damping: damping)
            let s2 = maxY.step(dt: dt, stiffness: stiffness, damping: damping)
            let s3 = width.step(dt: dt, stiffness: stiffness, damping: damping)
            let s4 = height.step(dt: dt, stiffness: stiffness, damping: damping)
            return s1 && s2 && s3 && s4
        }
    }

    private struct ScalarMotion {
        var from: CGFloat
        var to: CGFloat
        var start = CACurrentMediaTime()
        var duration: TimeInterval

        func value(at time: CFTimeInterval) -> (value: CGFloat, done: Bool) {
            let t = CGFloat(min(1, max(0, (time - start) / duration)))
            let eased = 1 - pow(1 - t, 3)
            return (from + (to - from) * eased, t >= 1)
        }
    }

    private var animationLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var spring: SpringMotion?
    private var visibility: ScalarMotion?
    private var onDismiss: (() -> Void)?

    var isDismissing: Bool { onDismiss != nil }
    var destinationFrame: NSRect { spring?.targetRect ?? frame }

    private var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func prepareEntrance(at target: NSRect, compact: Bool) {
        stopMotion()
        if animates && compact {
            // Subtle horizontal spring pop matching Spotlight's entrance (640 -> ~652 -> 640).
            let start = target.insetBy(dx: target.width * 0.014, dy: 0)
            setFrame(start, display: false)
            alphaValue = 0.05
        } else {
            setFrame(target, display: false)
            alphaValue = animates ? 0.05 : 1
        }
    }

    func reveal(at target: NSRect, entering: Bool) {
        onDismiss = nil
        resize(to: target, entering: entering)
        guard animates, alphaValue < 1 else {
            visibility = nil
            alphaValue = 1
            return
        }
        visibility = ScalarMotion(from: alphaValue, to: 1, duration: 0.095)
        startDisplayLink()
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        if isDismissing && animated { return }
        guard isVisible, animated, animates else {
            stopMotion()
            orderOut(nil)
            completion()
            return
        }
        ignoresMouseEvents = true
        onDismiss = completion
        let current = frame
        let shrink = NSRect(x: current.minX + current.width * 0.01,
                            y: current.minY,
                            width: current.width * 0.98,
                            height: current.height)
        spring = SpringMotion(from: current, to: shrink, response: 0.16, dampingRatio: 1.0)
        visibility = ScalarMotion(from: alphaValue, to: 0, duration: 0.095)
        startDisplayLink()
    }

    func resize(to target: NSRect, entering: Bool = false) {
        guard !isDismissing else { return }
        if let spring, spring.targetRect == target { return }
        guard isVisible, animates, frame != target else {
            spring = nil
            if frame != target {
                setFrame(target, display: true)
                invalidateShadow()
            }
            return
        }
        let current = spring?.currentRect ?? frame
        let contracting = target.height < current.height || (target.height == current.height && target.width < current.width)
        let response: CGFloat = entering ? 0.24 : (contracting ? 0.25 : 0.28)
        let damping: CGFloat = entering ? 0.76 : (contracting ? 0.84 : 0.82)
        if spring != nil {
            spring?.retarget(to: target, response: response, dampingRatio: damping)
        } else {
            let boost: CGFloat = entering ? 240 : 0
            spring = SpringMotion(from: current, to: target, response: response, dampingRatio: damping, initialWidthVelocity: boost)
        }
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard animationLink == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let action = #selector(advanceMotion(_:))
        let link = (screen ?? NSScreen.main)?.displayLink(target: self, selector: action)
            ?? displayLink(target: self, selector: action)
        link.add(to: .main, forMode: .common)
        animationLink = link
    }

    @objc private func advanceMotion(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawDt = now - (lastFrameTime ?? now)
        lastFrameTime = now
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, rawDt)))

        if var activeSpring = spring {
            let done = activeSpring.step(dt: dt)
            let nextFrame = done ? activeSpring.targetRect : activeSpring.currentRect
            setFrame(nextFrame, display: done)
            if done {
                spring = nil
                invalidateShadow()
            } else {
                spring = activeSpring
            }
        }

        if let activeVisibility = visibility {
            let (value, done) = activeVisibility.value(at: now)
            alphaValue = value
            if done {
                visibility = nil
                if let finish = onDismiss {
                    stopMotion()
                    orderOut(nil)
                    finish()
                    return
                }
            }
        }

        if spring == nil && visibility == nil {
            stopMotion()
        }
    }

    private func stopMotion() {
        animationLink?.invalidate()
        animationLink = nil
        lastFrameTime = nil
        spring = nil
        visibility = nil
        onDismiss = nil
    }
}
