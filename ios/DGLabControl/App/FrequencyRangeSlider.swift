import SwiftUI

/// A single 1–100 Hz rail with two independent, 44-point accessible drag handles.
/// The handles cannot cross; fixed-frequency choices remain in the preset grid.
struct FrequencyRangeSlider: View {
    @Binding var lower: Int
    @Binding var upper: Int
    let onCommit: () -> Void

    private let trackInset: CGFloat = 22
    private let bounds = 1...100

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("最低 \(lower) Hz").foregroundStyle(.cyan)
                Spacer()
                Text("最高 \(upper) Hz").foregroundStyle(.cyan)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - trackInset * 2)
                let start = trackInset + width * fraction(lower)
                let end = trackInset + width * fraction(upper)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                        .frame(width: width, height: 7)
                        .position(x: trackInset + width/2, y: 25)
                    Capsule().fill(Color.cyan)
                        .frame(width: max(2, end-start), height: 7)
                        .position(x: (start + end)/2, y: 25)
                    handle("最低频率", at: start, value: lower, width: width, isLower: true)
                    handle("最高频率", at: end, value: upper, width: width, isLower: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "FrequencyRail")
            }
            .frame(height: 50)
            HStack {
                Text("1 Hz")
                Spacer()
                Text("100 Hz")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func fraction(_ value: Int) -> CGFloat {
        CGFloat(value - bounds.lowerBound) / CGFloat(bounds.upperBound - bounds.lowerBound)
    }

    @ViewBuilder private func handle(_ title: String, at location: CGFloat,
                                     value: Int, width: CGFloat, isLower: Bool) -> some View {
        Circle()
            .fill(Color(.systemBackground))
            .frame(width: 29, height: 29)
            .overlay(Circle().strokeBorder(Color.cyan, lineWidth: 3))
            .shadow(color: .black.opacity(0.20), radius: 3, y: 2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: location, y: 25)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("FrequencyRail"))
                .onChanged { gesture in
                    let fraction = (gesture.location.x - trackInset) / width
                    let value = Int((1 + fraction * 99).rounded())
                    update(isLower: isLower, rawValue: value)
                }
                .onEnded { _ in onCommit() })
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(value) 赫兹")
            .accessibilityHint("上下滑动调整频率，范围 1 至 100 赫兹")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: update(isLower: isLower, rawValue: value + 1)
                case .decrement: update(isLower: isLower, rawValue: value - 1)
                @unknown default: return
                }
                onCommit()
            }
    }

    private func update(isLower: Bool, rawValue: Int) {
        if isLower { lower = max(1, min(upper - 1, rawValue)) }
        else { upper = min(100, max(lower + 1, rawValue)) }
    }
}
