//
//  LockScreenClockPreview.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A miniature lock screen in Settings, so the clock's glass and size can be
//  seen while they're changed: the wallpaper, the account picture, name and
//  prompt where macOS puts them, and the clock cut out around them as on the
//  real lock screen. It's laid out at the main display's full size and
//  scaled down, so the glass looks as it will there.
//

import AppKit
import CoreText
import SwiftUI

struct LockScreenClockPreview: View {
    let showsClock: Bool
    let style: LockScreenClockStyle
    let height: Double
    /// System Settings → Lock Screen → Show user name and photo.
    let showsNameAndPhoto: Bool
    /// It fills the width it's given, up to this.
    var maxWidth: CGFloat = 560

    @State private var wallpaper: NSImage?
    private let screenSize = NSScreen.screens.first?.frame.size ?? CGSize(width: 1512, height: 982)

    var body: some View {
        // The screen's shape, as wide as there's room for; the lock screen is
        // drawn at full size inside it and scaled to fit, so it never asks
        // the page for more width than it has.
        Color.clear
            .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    lockScreen.scaleEffect(geometry.size.width / screenSize.width, anchor: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .task {
                wallpaper = await NotchHelperClient.shared.lockScreenWallpaper(maxWidth: Int(maxWidth * 3))
            }
    }

    private var lockScreen: some View {
        let prompt = PromptLayout(screenSize: screenSize, showsNameAndPhoto: showsNameAndPhoto)
        return ZStack {
            background
            prompt.view
            if showsClock {
                TimelineView(.everyMinute) { context in
                    LockScreenClockFace(date: context.date, screenSize: screenSize, controls: prompt.controls,
                                        showsPicture: showsNameAndPhoto, style: style, height: height)
                }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    @ViewBuilder
    private var background: some View {
        if let wallpaper {
            Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                .frame(width: screenSize.width, height: screenSize.height).clipped()
        } else {
            LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The account picture, name and "Touch ID or Enter Password", placed as the
/// lock screen places them (measured from the bottom of the screen), and the
/// same controls as the clock's cutouts see them on the real lock screen.
private struct PromptLayout {
    let screenSize: CGSize
    let showsNameAndPhoto: Bool
    private let name = NSFullUserName()
    private let hint = "Touch ID or Enter Password"
    private let nameFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private var nameFrame: CGRect { line(name, font: nameFont, top: screenSize.height - 105) }
    private var hintFrame: CGRect { line(hint, font: hintFont, top: screenSize.height - 72) }
    private var pictureFrame: CGRect {
        let d = LockScreenClockCutouts.pictureDiameter
        return CGRect(x: hintFrame.midX - d / 2, y: hintFrame.minY - LockScreenClockCutouts.pictureCenterAboveHint - d / 2, width: d, height: d)
    }

    var controls: [LockScreenControl] {
        var controls = [LockScreenControl(kind: .text, frame: hintFrame, text: hint)]
        if showsNameAndPhoto { controls.append(LockScreenControl(kind: .text, frame: nameFrame, text: name)) }
        return controls
    }

    var view: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsNameAndPhoto {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .top, endPoint: .bottom))
                    .overlay(Text(name.prefix(1)).font(.system(size: 22, weight: .medium)).foregroundStyle(.white))
                    .frame(width: pictureFrame.width, height: pictureFrame.height)
                    .offset(x: pictureFrame.minX, y: pictureFrame.minY)
                label(name, font: nameFont, frame: nameFrame)
            }
            label(hint, font: hintFont, frame: hintFrame)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func label(_ text: String, font: NSFont, frame: CGRect) -> some View {
        Text(text).font(Font(font)).foregroundStyle(.white).fixedSize()
            .offset(x: frame.minX, y: frame.minY)
    }

    /// A line of `text` centered on the screen with its top at `top`.
    private func line(_ text: String, font: NSFont, top: CGFloat) -> CGRect {
        let size = NSAttributedString(string: text, attributes: [.font: font]).size()
        return CGRect(x: (screenSize.width - size.width) / 2, y: top, width: size.width, height: size.height)
    }
}
