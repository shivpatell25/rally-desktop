import RallyCore
import SwiftUI

/// First-run onboarding. Mirrors OnboardingScreen: three setup cards plus the
/// no-service disclaimer, then Continue hands to Settings for the validated
/// Save that marks setup complete.
struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let img = tvArt("rally_wordmark") {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 280, height: 96)
            } else {
                Text("RALLY").font(.system(size: 44, weight: .black)).foregroundStyle(.white)
            }
            Text("Sports, kept simple.")
                .font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
            Text("Live games, verified sources, highlights, and the teams you follow — built for the biggest screen in your home.")
                .font(.system(size: 14)).foregroundStyle(RallyTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 640)
            HStack(spacing: 12) {
                onboardingCard("01", "Choose your sports", "Arrange leagues and favorite teams so Rally promotes the games that matter to you.")
                onboardingCard("02", "Connect sources", "Add your IPTV subscription and Stremio addons. Rally includes no television service of its own.")
                onboardingCard("03", "Watch your way", "Verified streams, live scores, highlights, and Multi-View — all in one cinematic hub.")
            }
            .padding(.horizontal, 40)
            Button("Continue to setup") { onContinue() }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(RallyTheme.offWhite).clipShape(RoundedRectangle(cornerRadius: 18))
                .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AmbientBackground() }
    }

    private func onboardingCard(_ num: String, _ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(num).font(.system(size: 12, weight: .bold)).foregroundStyle(RallyTheme.rallyCyan)
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            Text(desc).font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }
}
