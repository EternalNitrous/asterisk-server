//
//  ProtonUI.swift
//  AsteriskServer
//
//  Design system ported from Proton: hex colors, JetBrains Mono typography, the
//  dark animated-grid backdrop, and the glassy press-drag button. The iOS 26
//  `.glassEffect` liquid glass is simulated with `.ultraThinMaterial` + gradient
//  strokes so it renders on older iOS.
//

import SwiftUI
import UIKit

// MARK: - Color(hex:)

extension Color {
  init(hex: String, opacity overrideOpacity: Double? = nil) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)

    let red: UInt64, green: UInt64, blue: UInt64, opacity: UInt64
    switch hex.count {
    case 3:
      red = (int >> 8) * 17
      green = (int >> 4 & 0xF) * 17
      blue = (int & 0xF) * 17
      opacity = 255
    case 6:
      red = int >> 16
      green = int >> 8 & 0xFF
      blue = int & 0xFF
      opacity = 255
    case 8:
      red = int >> 24
      green = int >> 16 & 0xFF
      blue = int >> 8 & 0xFF
      opacity = int & 0xFF
    default:
      red = 0; green = 0; blue = 0; opacity = 255
    }

    self.init(
      .sRGB,
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255,
      opacity: overrideOpacity ?? Double(opacity) / 255)
  }
}

// MARK: - Typography

enum ProtonTypography {
  static let fontName = "JetBrainsMono-Regular"
}

extension Font {
  static func protonMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(ProtonTypography.fontName, size: size).weight(weight)
  }

  static var protonBody: Font {
    .custom(ProtonTypography.fontName, size: 17)
  }
}

// MARK: - Backdrop

struct ControllerBackdrop: View {
  var body: some View {
    ZStack {
      Color(hex: "#0b0b0c")
      AnimatedWarpedGrid()
        .mask { ReverseRadialVignetteMask() }
    }
    .ignoresSafeArea()
  }
}

struct ReverseRadialVignetteMask: View {
  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let cellSize: CGFloat = 6
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let halfWidth = max(size.width / 2, 1)
      let halfHeight = max(size.height / 2, 1)

      var y: CGFloat = 0
      while y < size.height {
        var x: CGFloat = 0
        while x < size.width {
          let normalizedX = (x + cellSize / 2 - center.x) / halfWidth
          let normalizedY = (y + cellSize / 2 - center.y) / halfHeight
          let radius = min(sqrt(normalizedX * normalizedX + normalizedY * normalizedY), 1)
          let smoothRadius = radius * radius * (3 - 2 * radius)
          let opacity = 0.10 + smoothRadius * 0.90
          context.fill(
            Path(CGRect(x: x, y: y,
                        width: min(cellSize, size.width - x),
                        height: min(cellSize, size.height - y))),
            with: .color(Color.white.opacity(opacity)))
          x += cellSize
        }
        y += cellSize
      }
    }
  }
}

struct AnimatedWarpedGrid: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
      Canvas { context, size in
        let time = timeline.date.timeIntervalSinceReferenceDate
        let spacing: CGFloat = 28
        let overscan: CGFloat = 40
        let amplitude: CGFloat = 1.25
        let phase = CGFloat(time * 0.22)
        let lineColor = Color(hex: "#ffffff", opacity: 0.05)

        var verticalPath = Path()
        var x = -overscan
        while x <= size.width + overscan {
          var firstPoint = true
          var y = -overscan
          while y <= size.height + overscan {
            let warpedX = x
              + sin((y * 0.017) + phase) * amplitude
              + sin((y * 0.006) - phase * 0.7) * amplitude * 0.55
            let point = CGPoint(x: warpedX, y: y)
            if firstPoint { verticalPath.move(to: point); firstPoint = false }
            else { verticalPath.addLine(to: point) }
            y += 14
          }
          x += spacing
        }

        var horizontalPath = Path()
        var y = -overscan
        while y <= size.height + overscan {
          var firstPoint = true
          var x = -overscan
          while x <= size.width + overscan {
            let warpedY = y
              + sin((x * 0.014) - phase * 0.85) * amplitude
              + sin((x * 0.005) + phase * 0.45) * amplitude * 0.5
            let point = CGPoint(x: x, y: warpedY)
            if firstPoint { horizontalPath.move(to: point); firstPoint = false }
            else { horizontalPath.addLine(to: point) }
            x += 14
          }
          y += spacing
        }

        context.stroke(verticalPath, with: .color(lineColor), lineWidth: 0.8)
        context.stroke(horizontalPath, with: .color(lineColor), lineWidth: 0.8)
      }
    }
  }
}

// MARK: - Simulated liquid glass (works pre-iOS 26)

struct SimulatedGlass: ViewModifier {
  var cornerRadius: CGFloat = 12
  var tint: Color = Color(hex: "#ffffff", opacity: 0.05)
  var highlightOpacity: Double = 0.16

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: "#0f0f12", opacity: 0.78))
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .opacity(0.5)
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [
                Color(hex: "#ffffff", opacity: highlightOpacity),
                Color(hex: "#ffffff", opacity: 0.03),
              ],
              startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color(hex: "#000000", opacity: 0.34), lineWidth: 1)
          .blur(radius: 1.5)
          .offset(y: 2)
          .padding(2)
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .shadow(color: Color(hex: "#000000", opacity: 0.7), radius: 10, y: 5)
  }
}

extension View {
  func simulatedGlass(cornerRadius: CGFloat = 12,
                      tint: Color = Color(hex: "#ffffff", opacity: 0.05),
                      highlightOpacity: Double = 0.16) -> some View {
    modifier(SimulatedGlass(cornerRadius: cornerRadius, tint: tint, highlightOpacity: highlightOpacity))
  }
}

// MARK: - Glassy press-drag button (ported from Proton)

struct LiquidGlassButtonStyle: PrimitiveButtonStyle {
  var maxOffset: CGFloat = 5

  func makeBody(configuration: Configuration) -> some View {
    LiquidGlassButtonBody(configuration: configuration, maxOffset: maxOffset)
  }
}

private struct LiquidGlassButtonBody: View {
  let configuration: PrimitiveButtonStyle.Configuration
  let maxOffset: CGFloat
  @GestureState private var dragState = LiquidGlassButtonDragState()
  @State private var buttonFrame: CGRect = .zero

  private var offset: CGSize { scaledOffset(in: buttonFrame) }

  var body: some View {
    configuration.label
      .background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: LiquidGlassButtonFramePreferenceKey.self,
            value: proxy.frame(in: .global))
        }
      }
      .onPreferenceChange(LiquidGlassButtonFramePreferenceKey.self) { frame in
        buttonFrame = frame
      }
      .scaleEffect(dragState.isPressed ? 1.035 : 1)
      .offset(x: offset.width, y: offset.height + (dragState.isPressed ? -2 : 0))
      .shadow(
        color: Color(hex: "#000000", opacity: dragState.isPressed ? 0.36 : 0.20),
        radius: dragState.isPressed ? 8 : 4,
        y: dragState.isPressed ? 5 : 2)
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($dragState) { value, state, _ in
            state = LiquidGlassButtonDragState(isPressed: true, translation: value.translation)
          }
          .onEnded { value in
            guard abs(value.translation.width) <= 44,
                  abs(value.translation.height) <= 44 else { return }
            configuration.trigger()
          })
      .accessibilityAction { configuration.trigger() }
      .animation(.liquidGlassButtonSpring, value: dragState)
  }

  private func scaledOffset(in frame: CGRect) -> CGSize {
    let screenBounds = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
      .first ?? CGRect(x: 0, y: 0, width: max(frame.maxX * 2, 1), height: max(frame.maxY * 2, 1))
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return CGSize(
      width: scaledAxisOffset(dragState.translation.width,
                              negativeDistance: max(center.x - screenBounds.minX, 1),
                              positiveDistance: max(screenBounds.maxX - center.x, 1)),
      height: scaledAxisOffset(dragState.translation.height,
                               negativeDistance: max(center.y - screenBounds.minY, 1),
                               positiveDistance: max(screenBounds.maxY - center.y, 1)))
  }

  private func scaledAxisOffset(_ translation: CGFloat,
                                negativeDistance: CGFloat,
                                positiveDistance: CGFloat) -> CGFloat {
    guard translation != 0 else { return 0 }
    let direction: CGFloat = translation > 0 ? 1 : -1
    let availableDistance = translation > 0 ? positiveDistance : negativeDistance
    let progress = min(abs(translation) / availableDistance, 1)
    return direction * progress * maxOffset
  }
}

private struct LiquidGlassButtonDragState: Equatable {
  var isPressed = false
  var translation: CGSize = .zero
}

private struct LiquidGlassButtonFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

extension Animation {
  static var liquidGlassButtonSpring: Animation {
    .spring(response: 0.22, dampingFraction: 0.72)
  }
}
