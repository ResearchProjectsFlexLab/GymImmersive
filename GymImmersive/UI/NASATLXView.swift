import SwiftUI

/// Post-set workload rating: the six NASA-TLX subscales as 0–100 sliders (steps of 5).
struct NASATLXView: View {
    @Binding var rating: NASATLXRating
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How'd that set feel?")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ForEach(TLXScale.allCases) { scale in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(scale.title).font(.headline)
                        Spacer()
                        Text("\(Int(rating[scale]))").font(.headline.monospacedDigit())
                            .accessibilityHidden(true)
                    }
                    Text(scale.question).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Slider(value: $rating[scale], in: 0...100, step: 5) {
                        Text(scale.title)
                    } minimumValueLabel: {
                        Text(scale.anchors.low).font(.caption)
                    } maximumValueLabel: {
                        Text(scale.anchors.high).font(.caption)
                    }
                    .accessibilityValue("\(Int(rating[scale])) of 100")
                    .accessibilityHint(scale.question)
                }
            }
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Saves your ratings and continues")
        }
    }
}

#Preview {
    @Previewable @State var rating = NASATLXRating()
    NASATLXView(rating: $rating) {}
        .padding()
        .frame(width: 560)
        .glassBackgroundEffect()
}
