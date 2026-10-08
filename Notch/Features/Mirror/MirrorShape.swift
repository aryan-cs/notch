//
//  MirrorShape.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The mirror preview's shape (Settings → Mirror).
//

import Defaults

enum MirrorShape: String, Defaults.Serializable {
    case rectangle = "Rectangular"
    case circle = "Circular"
}
