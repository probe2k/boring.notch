//
//  LottieAnimationContainer.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    private static let defaultVisualizerURL: URL = URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!

    @Default(.selectedVisualizer) var selectedVisualizer
    var body: some View {
        if selectedVisualizer == nil {
            LottieView(url: Self.defaultVisualizerURL, speed: 1.0, loopMode: .loop)
        } else {
            LottieView(url: selectedVisualizer!.url, speed: selectedVisualizer!.speed, loopMode: .loop)
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
