//
//  WelcomeView.swift
//  Notch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI
import SwiftUIIntrospect

struct WelcomeView: View {
    var onGetStarted: (() -> Void)?
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Image("spotlight")
                    .resizable().scaledToFit()
                    .padding(.bottom)
                    .blur(radius: 3)
                    .offset(y: -5)
                    .background(SparkleView().opacity(0.6))
                VStack(spacing: 8) {
                    Image("logo2")
                        .resizable().scaledToFit()
                        .frame(width: 100, height: 100)
                        .padding(.bottom, 8)
                    Text("Notch")
                        .font(.system(.largeTitle, design: .default))
                        .fontWeight(.semibold)
                    Text("Welcome")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 30)

                    Button {
                        onGetStarted?()
                    } label: {
                        Text("Get started")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding(.top)
            }

            Image("theboringteam")
                .resizable().scaledToFit()
                .frame(height: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .padding(.bottom, 36)
                .blendMode(.overlay)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
}
