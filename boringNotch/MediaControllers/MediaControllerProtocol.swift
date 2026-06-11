//
//  MediaControllerProtocol.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import AppKit
import Combine

protocol MediaControllerProtocol: ObservableObject {
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var supportsVolumeControl: Bool { get }
    var supportsFavorite: Bool { get }
    
    func setFavorite(_ favorite: Bool) async
    func play() async
    func pause() async
    func seek(to time: Double) async
    func nextTrack() async
    func previousTrack() async
    func togglePlay() async
    func toggleShuffle() async
    func toggleRepeat() async
    func setVolume(_ level: Double) async
    func isActive() -> Bool
    func updatePlaybackInfo() async

    /// Synchronously stop all background work owned by this controller —
    /// timers, Tasks, helper processes, file handles, etc. Must complete
    /// promptly (well under one second) because callers run during
    /// `applicationWillTerminate`, where the system gives the app ~5s
    /// before SIGKILL. Idempotent and safe to call multiple times.
    func teardown()
}

extension MediaControllerProtocol {
    /// Default no-op so controllers without background resources don't
    /// have to implement anything.
    func teardown() {}
}
