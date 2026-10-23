import SwiftUI
import UIKit

enum AppAnimations {
    static var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static var standard: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.82)
    }

    static var smooth: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.88)
    }

    static var quick: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9)
    }

    static var list: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85)
    }

    static var chart: Animation {
        reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.45)
    }

    static let insertionTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .opacity.combined(with: .scale(scale: 0.96))
    )

    static let cardTransition: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.94).combined(with: .opacity),
        removal: .opacity
    )

    static func run(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(standard, body)
        }
    }
}

extension View {
    func staggeredAppear(index: Int, baseDelay: Double = 0.04) -> some View {
        modifier(StaggeredAppearModifier(index: index, baseDelay: baseDelay))
    }

    func pressableButtonStyle() -> some View {
        buttonStyle(PressableButtonStyle())
    }

    func animatedCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .transition(AppAnimations.cardTransition)
    }
}

private struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    let baseDelay: Double
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : (AppAnimations.reduceMotion ? 0 : 12))
            .onAppear {
                let delay = AppAnimations.reduceMotion ? 0 : Double(index) * baseDelay
                withAnimation(AppAnimations.smooth.delay(delay)) {
                    isVisible = true
                }
            }
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(AppAnimations.quick, value: configuration.isPressed)
    }
}
