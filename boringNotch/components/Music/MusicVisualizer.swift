//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    private var barLayers: [CALayer] = []
    private var currentScales: [CGFloat] = []
    private var animationCallbacks: [BarAnimationCallback] = []
    private var isPlaying: Bool = false
    /// Bumped every time the animation state changes so stale completion
    /// callbacks from a previous run never re-arm new animations.
    private var animationGeneration: Int = 0

    private let barWidth: CGFloat = 2
    private let barCount: Int = 4
    private let totalHeight: CGFloat = 14
    private let minScale: CGFloat = 0.35
    private let maxScale: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.isOpaque = false
        setupBars()
    }

    private func setupBars() {
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let bar = CALayer()
            bar.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.transform = CATransform3DMakeScale(1, minScale, 1)
            CATransaction.commit()

            barLayers.append(bar)
            currentScales.append(minScale)
            animationCallbacks.append(BarAnimationCallback())
            layer?.addSublayer(bar)
        }
    }

    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        if playing {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        animationGeneration &+= 1
        let generation = animationGeneration

        for i in 0 ..< barLayers.count {
            // Stagger the first hop slightly so all four bars don't peak together.
            let initialDelay = Double(i) * 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
                guard let self,
                      self.isPlaying,
                      self.animationGeneration == generation else { return }
                self.animateBar(at: i, generation: generation)
            }
        }
    }

    private func stopAnimating() {
        animationGeneration &+= 1
        for (i, bar) in barLayers.enumerated() {
            let from = currentScales[i]
            bar.removeAllAnimations()

            let settle = CABasicAnimation(keyPath: "transform.scale.y")
            settle.fromValue = from
            settle.toValue = minScale
            settle.duration = 0.25
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.transform = CATransform3DMakeScale(1, minScale, 1)
            bar.add(settle, forKey: "settle")
            CATransaction.commit()

            currentScales[i] = minScale
        }
    }

    private func animateBar(at index: Int, generation: Int) {
        guard isPlaying,
              generation == animationGeneration,
              index < barLayers.count else { return }

        let bar = barLayers[index]
        let from = currentScales[index]
        let to = CGFloat.random(in: minScale ... maxScale)
        // Per-bar duration jitter prevents lockstep without ever leaving the
        // animation visibly mid-stride.
        let duration = Double.random(in: 0.32 ... 0.52)

        let callback = animationCallbacks[index]
        callback.onComplete = { [weak self] in
            guard let self else { return }
            self.animateBar(at: index, generation: generation)
        }

        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.delegate = callback

        // Commit the model value and the animation together inside a
        // transaction with implicit actions disabled, so the layer doesn't
        // try to fire its own animation for the transform change.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.transform = CATransform3DMakeScale(1, to, 1)
        bar.add(animation, forKey: "scaleY")
        CATransaction.commit()

        currentScales[index] = to
    }
}

/// Trampoline so each bar can chain into its next animation when the
/// current one finishes naturally. Manually-removed animations report
/// `finished: false` and are ignored, which keeps `stopAnimating()` from
/// re-arming the chain.
private final class BarAnimationCallback: NSObject, CAAnimationDelegate {
    var onComplete: (() -> Void)?

    func animationDidStop(_ anim: CAAnimation, finished: Bool) {
        guard finished else { return }
        onComplete?()
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
