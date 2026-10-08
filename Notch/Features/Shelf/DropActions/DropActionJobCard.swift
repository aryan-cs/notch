//
//  DropActionJobCard.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Stands in on the shelf for a drop action's result while it's being
//  made: a spinner, then the finished item takes its place. A failure
//  shows a warning (the reason is in the tooltip) until it clears itself
//  or is clicked away. Same footprint as `ShelfItemView`.
//

import SwiftUI

struct DropActionJobCard: View {
    let job: DropActionRunner.Job

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 56, height: 56)
                .overlay { status }

            Text(job.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(job.failure == nil ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
        .frame(width: 105)
        .padding(.vertical, 10)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if job.failure != nil {
                DropActionRunner.shared.dismiss(job)
            }
        }
        .help(job.failure ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(job.failure.map { "\(job.name): \($0)" } ?? job.name)
    }

    @ViewBuilder
    private var status: some View {
        if job.failure != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.orange)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
