//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Active controller - Now Playing only
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // Memoize avg color by track identity so revisiting recent tracks skips
    // the GPU pass entirely. countLimit kept small — we only care about the
    // last few tracks the user actually cycles between.
    private let avgColorCache: NSCache<NSString, NSColor> = {
        let cache = NSCache<NSString, NSColor>()
        cache.countLimit = 8
        return cache
    }()

    // Cached mirror of Defaults[.coloredSpectrogram] so we don't hit
    // UserDefaults on every artwork emission. Kept in sync via the publisher
    // wired up in init().
    private var coloredSpectrogramEnabled: Bool = Defaults[.coloredSpectrogram]

    // MARK: - Initialization
    init() {
        // Directly initialize Now Playing controller
        guard let controller = NowPlayingController() else {
            fatalError("Failed to initialize Now Playing controller. Media Remote framework not available.")
        }
        
        self.activeController = controller
        
        controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.updateFromPlaybackState(state)
            }
            .store(in: &controllerCancellables)

        Defaults.publisher(.coloredSpectrogram)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.coloredSpectrogramEnabled = change.newValue
            }
            .store(in: &cancellables)

        // Update volume control support
        self.volumeControlSupported = controller.supportsVolumeControl
        self.canFavoriteTrack = controller.supportsFavorite
        
        // Initial update
        forceUpdate()
    }


    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Explicit, synchronous teardown of the controller's background
        // resources (e.g. the mediaremote-adapter Perl helper). Relying
        // on deinit alone leaked the helper as a launchd-reparented
        // zombie whenever any other strong reference outlived us, which
        // was every "Restart Boring Notch" and every Xcode-stop click.
        activeController?.teardown()
        activeController = nil
    }



    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes. `state.artwork` may legitimately be nil in
        // a diff event that simply doesn't carry artwork — we treat that as
        // "unchanged" rather than "removed" now that NowPlayingController
        // preserves the previous artwork across diffs.
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let trackIdentityChanged = titleChanged || artistChanged || albumChanged || bundleChanged
        let hasContentChange = trackIdentityChanged || artworkChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil && self.artworkData == nil && trackIdentityChanged {
                // Track changed and we genuinely have no artwork for it — fall
                // back to the source app's icon. (Previously this branch fired
                // on every metadata diff because the controller used to drop
                // artwork from diff payloads, causing repeated flicker between
                // the real album art and the app icon.)
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }

            if artworkChanged {
                self.artworkData = state.artwork
            }

            if artworkChanged || (state.artwork == nil && trackIdentityChanged) {
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }
        }

        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if state.currentTime != self.elapsedTime {
            self.elapsedTime = state.currentTime
        }

        if state.duration != self.songDuration {
            self.songDuration = state.duration
        }

        if state.playbackRate != self.playbackRate {
            self.playbackRate = state.playbackRate
        }

        if state.isShuffled != self.isShuffled {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if state.repeatMode != self.repeatMode {
            self.repeatMode = state.repeatMode
        }

        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }

        if state.volume != self.volume {
            self.volume = state.volume
        }

        // Only republish the timestamp when it actually advances. Previously
        // this was assigned on every event regardless, which by itself caused a
        // SwiftUI redraw cascade on every MediaRemote notification — multiple
        // times per second for some players — and dominated this app's idle
        // CPU/battery footprint.
        if state.lastUpdated != self.timestampDate {
            self.timestampDate = state.lastUpdated
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if coloredSpectrogramEnabled {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        let raw: TimeInterval
        if isPlaying && playbackRate > 0 {
            let timeDifference = max(0, date.timeIntervalSince(timestampDate))
            raw = elapsedTime + (timeDifference * playbackRate)
        } else {
            raw = elapsedTime
        }
        if songDuration > 0 {
            return min(max(0, raw), songDuration)
        }
        return max(0, raw)
    }

    func calculateAverageColor() {
        let cacheKey = "\(songTitle)|\(artistName)|\(album)" as NSString
        if let cached = avgColorCache.object(forKey: cacheKey) {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.avgColor = cached
            }
            return
        }
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    let resolved = color ?? .white
                    if let color = color {
                        self?.avgColorCache.setObject(color, forKey: cacheKey)
                    }
                    self?.avgColor = resolved
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Re‑anchor the cached elapsed time to "now" so that any consumer that
        // reads `elapsedTime` directly (rather than going through
        // `estimatedPlaybackPosition`) sees a fresh value immediately —
        // important when the notch is opened after a long idle period and no
        // new stream events have arrived in the interim.
        let now = Date()
        if isPlaying && playbackRate > 0 {
            let drift = max(0, now.timeIntervalSince(timestampDate)) * playbackRate
            let estimated = elapsedTime + drift
            let clamped = songDuration > 0 ? min(max(0, estimated), songDuration) : max(0, estimated)
            if clamped != elapsedTime {
                elapsedTime = clamped
            }
            if now != timestampDate {
                timestampDate = now
            }
        }

        // Refresh side‑channel state (e.g. favourite flag) from the active
        // controller. The playback position itself is delivered continuously
        // by the streaming MediaRemote pipe so there is no need to re‑request
        // it here.
        Task { [weak self] in
            await self?.activeController?.updatePlaybackInfo()
        }
    }
    
}
