//
//  LottieView.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-14.
//

import SwiftUI
import Lottie
import ObjectiveC

private final class LottieAnimationCache {
    static let shared = LottieAnimationCache()
    private let cache = NSCache<NSString, LottieAnimation>()
    private init() { cache.countLimit = 8 }
    func get(_ key: String) -> LottieAnimation? { cache.object(forKey: key as NSString) }
    func set(_ key: String, _ animation: LottieAnimation) { cache.setObject(animation, forKey: key as NSString) }
}

/// Container that pauses its child `LottieAnimationView` whenever it
/// detaches from a window (collapsed notch, hidden Space, etc.) and resumes
/// when re-attached. Implemented on the wrapper NSView (which we own)
/// because `Lottie.LottieAnimationView` is `public`, not `open`, so its
/// methods can't be overridden from outside the Lottie module.
private final class PausableLottieContainerView: NSView {
    private var wasPlaying = false

    private var lottieView: LottieAnimationView? {
        subviews.first as? LottieAnimationView
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let lottieView else { return }
        if window == nil {
            wasPlaying = lottieView.isAnimationPlaying
            lottieView.pause()
        } else if wasPlaying {
            lottieView.play()
            wasPlaying = false
        }
    }
}

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode

    private static var associatedURLKey: UInt8 = 0

    func makeNSView(context: Context) -> NSView {
        let animationView = LottieAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        let container = PausableLottieContainerView()
        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let animationView = nsView.subviews.first as? LottieAnimationView else { return }
        let urlKey = url.absoluteString
        let lastURLKey = objc_getAssociatedObject(animationView, &Self.associatedURLKey) as? NSString as String?
        if lastURLKey != urlKey {
            if let cached = LottieAnimationCache.shared.get(urlKey) {
                animationView.animation = cached
                animationView.loopMode = loopMode
                animationView.animationSpeed = CGFloat(speed)
                if !animationView.isAnimationPlaying {
                    animationView.play()
                }
                objc_setAssociatedObject(animationView, &Self.associatedURLKey, urlKey as NSString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return
            }
            LottieAnimation.loadedFrom(url: url) { animation in
                if let animation = animation {
                    LottieAnimationCache.shared.set(urlKey, animation)
                }
                animationView.animation = animation
                animationView.loopMode = loopMode
                animationView.animationSpeed = CGFloat(speed)
                animationView.play()
                objc_setAssociatedObject(animationView, &Self.associatedURLKey, urlKey as NSString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        } else {
            animationView.loopMode = loopMode
            animationView.animationSpeed = CGFloat(speed)
            if !animationView.isAnimationPlaying {
                animationView.play()
            }
        }
    }
}
