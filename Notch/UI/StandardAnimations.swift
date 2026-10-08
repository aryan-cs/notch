//
//  StandardAnimations.swift
//  Notch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Defaults
import Foundation
import SwiftUI

/// Centralized animation definitions for consistent UI behavior across the app.
enum StandardAnimations {
    /// Interactive spring for responsive UI (used for notch interactions)
    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    /// Spring animation for opening the notch
    static var open: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.42 / Defaults[.animationSpeedMultiplier], dampingFraction: 0.8, blendDuration: 0)
    }

    /// Spring animation for closing the notch
    static var close: Animation {
        guard Defaults[.enableOpeningAnimation] else {
            return Animation.linear(duration: 0)
        }
        return Animation.spring(response: 0.45 / Defaults[.animationSpeedMultiplier], dampingFraction: 1.0, blendDuration: 0)
    }

    /// Bouncy spring for playful animations
    static var bouncy: Animation {
        Animation.spring(.bouncy(duration: 0.4))
    }
}
