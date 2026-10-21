//
//  GlassTextMaterial.swift
//  Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The glass macOS draws its own lock screen clock with. LoginUIKit's
//  LUI2GlassTextSwiftUIView fills the time with
//  `Material._glassy(Material._GlassVariant.text)`. Both are exported from
//  SwiftUI but aren't in its public interface, so they're looked up at
//  runtime: if a macOS update removes them, `material(_:)` returns nil and
//  the clock falls back, rather than Notch failing to launch.
//
//  Calling them: `_GlassVariant` is a resilient struct whose layout isn't
//  known here. Its static getters return it indirectly, writing it to the
//  address in x8, and `_glassy` takes it by address and returns the Material
//  the same way. A C function returning a struct too big for registers also
//  gets its result address in x8, so a C function type returning a large C
//  struct (utsname, 1280 bytes) calls them correctly. The Material is then
//  moved out of that buffer. Both types' sizes are checked first.
//

import Darwin
import SwiftUI

@MainActor
enum GlassTextMaterial {
    private typealias MetadataAccessor = @convention(c) (Int) -> UnsafeRawPointer
    private typealias VariantGetter = @convention(c) () -> utsname
    private typealias Glassy = @convention(c) (UnsafeRawPointer) -> utsname

    private static var cache: [String: Material?] = [:]

    /// `variant` names a `Material._GlassVariant` static, e.g. "text" (the
    /// lock screen clock's), "monogram" or "controlCenter".
    static func material(_ variant: String) -> Material? {
        if let cached = cache[variant] { return cached }
        let material = load(variant)
        if material == nil { Log.app.error("Glass variant \(variant, privacy: .public) isn't available") }
        cache[variant] = material
        return material
    }

    private static func load(_ variant: String) -> Material? {
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let accessor = dlsym(anyImage, "$s7SwiftUI8MaterialV13_GlassVariantVMa"),
              let getter = dlsym(anyImage, "$s7SwiftUI8MaterialV13_GlassVariantV\(variant.count)\(variant)AEvgZ"),
              let glassy = dlsym(anyImage, "$s7SwiftUI8MaterialV6_glassyA2C13_GlassVariantVFZ")
        else { return nil }

        // The value witness table is just before the metadata; its size field
        // follows eight function pointers.
        let metadata = unsafeBitCast(accessor, to: MetadataAccessor.self)(0)
        let variantSize = metadata.load(fromByteOffset: -8, as: UnsafeRawPointer.self).load(fromByteOffset: 64, as: Int.self)
        let bufferSize = MemoryLayout<utsname>.size
        guard variantSize <= bufferSize, MemoryLayout<Material>.size <= bufferSize else { return nil }

        // The variant is left in its buffer, never destroyed: one per style, for the life of the app.
        var variantBuffer = unsafeBitCast(getter, to: VariantGetter.self)()
        var materialBuffer = withUnsafeBytes(of: &variantBuffer) { unsafeBitCast(glassy, to: Glassy.self)($0.baseAddress!) }
        return withUnsafeMutableBytes(of: &materialBuffer) { $0.baseAddress!.assumingMemoryBound(to: Material.self).move() }
    }
}
