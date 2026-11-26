import AppKit
import QuartzCore
import SwiftUI

/// Centralized Apple macOS 26/27 Liquid Glass & fluid spring motion tokens shared across Wumi,
/// harmonized with Miji's Spotlight design language.
enum WumiMotion {
    /// Fast hover, press, hairline, and small state indicator transitions (120 ms).
    static let micro = Animation.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.12)
    /// Crisp Apple ease-out for small disclosures, fades, and bar state changes (180 ms).
    static let quick = Animation.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.18)
    /// Critically damped spring for structural UI transitions (inspector, sections, capsules).
    static let snappy = Animation.spring(duration: 0.28, bounce: 0.0)
    /// Slightly calmer critically damped spring for larger panels and overlays.
    static let gentle = Animation.spring(duration: 0.34, bounce: 0.0)
    /// Spotlight-matched organic spring for Liquid Glass morphing (floating orb, dock pills).
    static let morph = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// Subtle momentum spring reserved for physical / floating micro-interactions.
    static let buoyant = Animation.spring(duration: 0.32, bounce: 0.14)
    /// Gentle non-vestibular cross-fade used when Reduce Motion is enabled.
    static let reduced = Animation.easeOut(duration: 0.15)

    /// Strong Apple-style ease-out curve for AppKit animations.
    static let easeOutCurve = CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)
    /// Smooth sheet/drawer curve for AppKit panel transitions.
    static let drawerCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.0, 1.0)

    @MainActor
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor
    static var systemReduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func resolve(_ preferred: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : preferred
    }

    static func withPreferredAnimation(_ preferred: Animation, reduceMotion: Bool, _ body: () -> Void) {
        withAnimation(resolve(preferred, reduceMotion: reduceMotion), body)
    }

    /// Runs an AppKit animation group with Apple-style easing and automatic Reduce Motion adaptation.
    @MainActor
    static func runAppKit(
        duration: TimeInterval = 0.22,
        timingFunction: CAMediaTimingFunction = easeOutCurve,
        allowsImplicit: Bool = true,
        _ changes: () -> Void,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let effectiveDuration = systemReduceMotion ? min(duration, 0.12) : duration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = effectiveDuration
            context.timingFunction = timingFunction
            context.allowsImplicitAnimation = allowsImplicit
            changes()
        }, completionHandler: completion)
    }

    /// Creates a physical CASpringAnimation parameterized by Apple's response (seconds) and dampingRatio.
    static func springLayerAnimation(
        keyPath: String,
        from: Any? = nil,
        to: Any? = nil,
        response: CFTimeInterval = 0.28,
        dampingRatio: CGFloat = 1.0
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let clampedResponse = max(response, 0.08)
        let omega = 2.0 * .pi / clampedResponse
        animation.mass = 1.0
        animation.stiffness = CGFloat(omega * omega)
        animation.damping = CGFloat(2.0 * Double(dampingRatio) * omega)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.isRemovedOnCompletion = true
        return animation
    }

    /// Finder-style double blink telegraphing that a spring-loaded folder or tab is about to open.
    @MainActor
    static func pulseSpringLoadFeedback(on view: NSView) {
        guard !systemReduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "wumi.springLoadPulse")
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1.0, 0.35, 1.0, 0.35, 1.0]
        pulse.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        pulse.duration = 0.28
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "wumi.springLoadPulse")
    }
}

// MARK: - Display-Synced Per-Axis Spring Window Physics (Aligned with Miji SearchPanel)

/// Drives an NSWindow/NSPanel with real second-order spring physics synced to the display refresh rate
/// via CADisplayLink. Supports velocity-preserving mid-flight retargeting and interruption.
@MainActor
final class WumiWindowSpringAnimator: NSObject {
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

    private struct FrameSpring {
        var midX: SpringAxis
        var maxY: SpringAxis
        var width: SpringAxis
        var height: SpringAxis
        var stiffness: CGFloat
        var damping: CGFloat

        init(from: NSRect, to: NSRect, response: CGFloat, dampingRatio: CGFloat) {
            let omega = 2 * .pi / max(0.08, response)
            self.stiffness = omega * omega
            self.damping = 2 * dampingRatio * omega
            self.midX = SpringAxis(value: from.midX, target: to.midX)
            self.maxY = SpringAxis(value: from.maxY, target: to.maxY)
            self.width = SpringAxis(value: from.width, target: to.width)
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
            let w = max(80, width.value)
            let h = max(44, height.value)
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

    private struct AlphaRamp {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval = CACurrentMediaTime()
        var duration: TimeInterval

        func value(at now: CFTimeInterval) -> (value: CGFloat, done: Bool) {
            let t = CGFloat(min(1, max(0, (now - start) / max(0.01, duration))))
            let eased = 1 - pow(1 - t, 3)
            return (from + (to - from) * eased, t >= 1)
        }
    }

    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var frameSpring: FrameSpring?
    private var alphaRamp: AlphaRamp?
    private var onComplete: (() -> Void)?

    var isAnimating: Bool { displayLink != nil }

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    func animate(
        from startFrame: NSRect? = nil,
        to targetFrame: NSRect,
        alpha targetAlpha: CGFloat,
        alphaDuration: TimeInterval = 0.11,
        response: CGFloat = 0.26,
        dampingRatio: CGFloat = 0.86,
        completion: (() -> Void)? = nil
    ) {
        guard let window else {
            completion?()
            return
        }
        if WumiMotion.systemReduceMotion {
            stop()
            window.setFrame(targetFrame, display: true)
            if abs(window.alphaValue - targetAlpha) > 0.01 {
                alphaRamp = AlphaRamp(from: window.alphaValue, to: targetAlpha, duration: min(alphaDuration, 0.12))
                onComplete = completion
                startLink(for: window)
            } else {
                window.alphaValue = targetAlpha
                completion?()
            }
            return
        }

        onComplete = completion
        let originFrame = startFrame ?? frameSpring?.currentRect ?? window.frame
        if let startFrame {
            window.setFrame(startFrame, display: false)
        }
        if frameSpring != nil && startFrame == nil {
            frameSpring?.retarget(to: targetFrame, response: response, dampingRatio: dampingRatio)
        } else if originFrame != targetFrame {
            frameSpring = FrameSpring(from: originFrame, to: targetFrame, response: response, dampingRatio: dampingRatio)
        } else {
            frameSpring = nil
        }

        if abs(window.alphaValue - targetAlpha) > 0.005 {
            alphaRamp = AlphaRamp(from: window.alphaValue, to: targetAlpha, duration: alphaDuration)
        } else {
            window.alphaValue = targetAlpha
            alphaRamp = nil
        }

        if frameSpring == nil && alphaRamp == nil {
            let finish = onComplete
            onComplete = nil
            finish?()
            return
        }
        startLink(for: window)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
        frameSpring = nil
        alphaRamp = nil
        onComplete = nil
    }

    private func startLink(for window: NSWindow) {
        guard displayLink == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let action = #selector(step(_:))
        let link = (window.screen ?? NSScreen.main)?.displayLink(target: self, selector: action)
            ?? window.displayLink(target: self, selector: action)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else {
            stop()
            return
        }
        let now = CACurrentMediaTime()
        let rawDt = now - (lastFrameTime ?? now)
        lastFrameTime = now
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, rawDt)))

        if var activeSpring = frameSpring {
            let done = activeSpring.step(dt: dt)
            let nextFrame = done ? activeSpring.targetRect : activeSpring.currentRect
            window.setFrame(nextFrame, display: done)
            if done {
                frameSpring = nil
                window.invalidateShadow()
            } else {
                frameSpring = activeSpring
            }
        }

        if let ramp = alphaRamp {
            let (value, done) = ramp.value(at: now)
            window.alphaValue = value
            if done { alphaRamp = nil }
        }

        if frameSpring == nil && alphaRamp == nil {
            let finish = onComplete
            stop()
            finish?()
        }
    }
}

// MARK: - Native macOS 26/27 Liquid Glass & Vibrancy Surfaces

/// Bridges AppKit's NSVisualEffectView for genuine macOS sidebar and legacy floating vibrancy.
struct WumiVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState
    var appearance: NSAppearance.Name? = nil
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.appearance = appearance.flatMap(NSAppearance.init(named:))
    }
}

/// Groups sibling Liquid Glass surfaces on macOS 26+ so adjacent capsules and circles morph organically.
struct WumiGlassContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// Native macOS 26+ Liquid Glass panel/capsule/circle surface with crisp macOS 15 blur and Reduce Transparency fallbacks.
struct WumiGlassSurface<S: InsettableShape>: View {
    let shape: S
    var interactive: Bool = false
    var tint: Color? = nil
    var fallbackMaterial: NSVisualEffectView.Material = .hudWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = colorScheme == .dark
        let strongerRim = reduceTransparency || contrast == .increased
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(shape.strokeBorder(Color.primary.opacity(strongerRim ? 0.36 : 0.18), lineWidth: 1))
            } else if #available(macOS 26.0, *) {
                let base: Glass = interactive ? .regular.interactive() : .regular
                let glass: Glass = tint.map { base.tint($0) } ?? base
                shape
                    .fill(.clear)
                    .glassEffect(glass, in: shape)
                    .overlay {
                        if strongerRim {
                            shape.strokeBorder(Color.white.opacity(dark ? 0.32 : 0.55), lineWidth: 1)
                        }
                    }
            } else {
                ZStack {
                    WumiVisualEffectView(material: fallbackMaterial, blendingMode: .behindWindow, state: .active)
                        .clipShape(shape)
                    shape.fill(tint ?? (dark ? Color.white.opacity(0.055) : Color.white.opacity(0.22)))
                    shape.strokeBorder(
                        LinearGradient(colors: [
                            Color.white.opacity(strongerRim ? 0.52 : (dark ? 0.20 : 0.62)),
                            (dark ? Color.white : Color.black).opacity(strongerRim ? 0.28 : 0.12)
                        ], startPoint: .top, endPoint: .bottom),
                        lineWidth: strongerRim ? 1 : 0.75
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Applies native macOS 26+ Liquid Glass directly to a view, with crisp fallback on macOS 15 or Reduce Transparency.
    @ViewBuilder
    func wumiGlass<S: InsettableShape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(WumiGlassViewModifier(shape: shape, interactive: interactive, tint: tint))
    }

    /// Assigns a Liquid Glass morphing identity on macOS 26+.
    @ViewBuilder
    func wumiGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

private struct WumiGlassViewModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        if reduceTransparency {
            content
                .background(shape.fill(Theme.elevatedSurface(dark: dark)))
                .overlay(shape.strokeBorder(Theme.subtleBorder(dark: dark), lineWidth: 0.75))
        } else if #available(macOS 26.0, *) {
            let base: Glass = interactive ? .regular.interactive() : .regular
            let glass: Glass = tint.map { base.tint($0) } ?? base
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(WumiGlassSurface(shape: shape, interactive: interactive, tint: tint))
        }
    }
}

// MARK: - Interactive Native Button Styles

/// Immediate pointer-down press feedback and soft continuous-corner hover surface.
struct WumiInteractiveButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var horizontalPadding: CGFloat = 0
    var verticalPadding: CGFloat = 0
    var restingFill: Color = .clear
    var hoverOpacity: Double = 0.07
    var pressOpacity: Double = 0.14
    var pressScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        WumiInteractiveButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            restingFill: restingFill,
            hoverOpacity: hoverOpacity,
            pressOpacity: pressOpacity,
            pressScale: pressScale
        )
    }
}

private struct WumiInteractiveButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let restingFill: Color
    let hoverOpacity: Double
    let pressOpacity: Double
    let pressScale: CGFloat

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var backgroundFill: Color {
        guard isEnabled else { return restingFill }
        if configuration.isPressed { return Color.primary.opacity(pressOpacity) }
        if hovering { return Color.primary.opacity(hoverOpacity) }
        return restingFill
    }

    var body: some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            )
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? pressScale : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(WumiMotion.micro, value: hovering)
            .animation(WumiMotion.micro, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Spotlight/Miji-harmonized translucent capsule chip for bookmarks, tabs, and filter pills.
struct WumiCapsuleChipStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 10
    var pressScale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        WumiCapsuleChipBody(
            configuration: configuration,
            selected: selected,
            height: height,
            horizontalPadding: horizontalPadding,
            pressScale: pressScale
        )
    }
}

private struct WumiCapsuleChipBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let height: CGFloat
    let horizontalPadding: CGFloat
    let pressScale: CGFloat

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = colorScheme == .dark
        let fill = Theme.chipFill(dark: dark, hovered: hovered || configuration.isPressed, selected: selected)
        let foreground: Color = selected
            ? (dark ? .white : Color(nsColor: .controlAccentColor))
            : Color.primary.opacity(hovered ? 0.96 : 0.84)
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .overlay {
                if selected && dark {
                    Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                }
            }
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? pressScale : 1.0)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .animation(WumiMotion.micro, value: hovered)
            .animation(WumiMotion.micro, value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}

/// Elevated soft-capsule button style for Inspector actions, Super Preview headers, and Floating Shelf toolbars.
struct WumiPillButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    var pressScale: CGFloat = 0.965
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        WumiPillButtonBody(configuration: configuration, cornerRadius: cornerRadius, pressScale: pressScale, emphasized: emphasized)
    }
}

private struct WumiPillButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let pressScale: CGFloat
    let emphasized: Bool

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fillColor: Color {
        if emphasized {
            return Color.accentColor.opacity(configuration.isPressed ? 1.0 : (hovering ? 0.94 : 0.85))
        }
        let dark = colorScheme == .dark
        guard isEnabled else { return Color.primary.opacity(0.045) }
        if configuration.isPressed { return Color.primary.opacity(dark ? 0.20 : 0.15) }
        if hovering { return Color.primary.opacity(dark ? 0.145 : 0.105) }
        return Color.primary.opacity(dark ? 0.095 : 0.07)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(0.90))
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(emphasized ? Color.white.opacity(0.18) : Theme.hairline(dark: colorScheme == .dark), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? pressScale : 1.0)
            .opacity(isEnabled ? 1.0 : 0.45)
            .contentShape(shape)
            .animation(WumiMotion.micro, value: hovering)
            .animation(WumiMotion.micro, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
