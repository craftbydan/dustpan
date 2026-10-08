import SwiftUI

/// The three first-run steps: what Dustpan does, why it needs Full Disk Access (with a
/// drawn mini guide), and done. Fills the window; never blocks — step 2 always offers
/// "Continue with limited scan".
struct OnboardingView: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepDashes(current: model.step)
            HStack(alignment: .center, spacing: Space.xxl) {
                IllustrationView(kind: illustration)
                    .frame(width: Metric.onboardingIllustration.width, height: Metric.onboardingIllustration.height)
                    .accessibilityHidden(true)
                    .id(model.step)
                    .transition(reduceMotion ? .identity : .opacity)
                VStack(alignment: .leading, spacing: Space.l) {
                    switch model.step {
                    case .welcome: WelcomeStep(model: model)
                    case .access: AccessStep(model: model)
                    case .done: DoneStep(model: model)
                    }
                }
                .frame(width: Metric.onboardingTextWidth, alignment: .leading)
                .id(model.step)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .animation(reduceMotion ? nil : Motion.fill, value: model.step)
        // Poll for access only while these steps are on screen; SwiftUI cancels on disappear.
        .task { await model.watchForAccess() }
    }

    private var illustration: Illustration {
        switch model.step {
        case .welcome: .welcome
        case .access: .accessGuide
        case .done: .accessDone
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        StepHeading("Dustpan finds the space your Mac fills up on its own")
        Text(
            "Caches, logs, old installers and build files pile up quietly. Dustpan finds them, says in plain words what each one is, and lets you choose what goes."
        )
        .textStyle(.body)
        .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                ToneGlyph(tone: .sweep)
                Text("Trash first, always").textStyle(.headline)
            }
            Text(
                "Nothing is deleted for good. What you clean goes to the Trash, so you can put any of it back."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkSurface(Palette.paper, radius: Radius.small)
        .accessibilityElement(children: .combine)
        InkButton("Next", systemImage: "arrow.right") { model.next() }
            .accessibilityHint("Shows why Dustpan asks for Full Disk Access")
            .padding(.top, Space.xs)
    }
}

private struct AccessStep: View {
    let model: OnboardingModel

    var body: some View {
        StepHeading("Let Dustpan look inside protected folders")
        Text(
            "macOS keeps some places, like the Trash, Downloads and other apps' folders, behind Full Disk Access. With it, Dustpan can see caches inside protected folders. It never reads your documents' contents."
        )
        .textStyle(.body)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: Space.s) {
            GuideLine(number: 1, text: "Click Open System Settings below.")
            GuideLine(number: 2, text: "Drag Dustpan into the Full Disk Access list, or click + and choose it.")
            GuideLine(number: 3, text: "Turn on the switch next to Dustpan.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How to turn on Full Disk Access")

        HStack(spacing: Space.m) {
            InkButton("Open System Settings", systemImage: "gearshape") { model.openSettings() }
                .accessibilityHint("Opens Privacy and Security, Full Disk Access")
            InkButton("Show Dustpan in Finder", kind: .secondary) { model.revealApp() }
                .accessibilityHint("Opens a Finder window with Dustpan selected, ready to drag")
        }
        .padding(.top, Space.xs)

        Text("This page moves on by itself once access is on.")
            .textStyle(.caption)

        Rectangle().fill(Palette.line).frame(height: Stroke.hairline)

        VStack(alignment: .leading, spacing: Space.xxs) {
            Button("Continue with limited scan") {
                Task { await model.continueWithLimitedScan() }
            }
            .buttonStyle(QuietLinkStyle())
            .accessibilityLabel("Continue with limited scan")
            .accessibilityHint("Skips Full Disk Access. You can turn it on later from the banner.")
            Text(limitedNote)
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitedNote: String {
        let count = model.accessCategories.count
        let skipped =
            count == 0
            ? "A few folders stay unchecked"
            : "\(count) \(count == 1 ? "category stays" : "categories stay") partly unchecked"
        return
            "Dustpan still scans the caches and logs in your Library folder and developer tool caches. \(skipped) until access is on."
    }
}

private struct DoneStep: View {
    let model: OnboardingModel

    var body: some View {
        StepHeading("Full Disk Access is on")
        Text(
            "Dustpan can now check every category, including the Trash, Downloads and Docker. Nothing moves until you pick it, and everything goes to the Trash first."
        )
        .textStyle(.body)
        .fixedSize(horizontal: false, vertical: true)
        InkButton("Start using Dustpan", systemImage: "arrow.right") {
            Task { await model.finish() }
        }
        .padding(.top, Space.xs)
    }
}

// MARK: - Pieces

private struct StepHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.title)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Step x of 3" as three short dashes; the current one is filled.
private struct StepDashes: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                let shape = Capsule()
                shape.fill(step.rawValue <= current.rawValue ? Palette.tomato : Palette.paper)
                    .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
                    .frame(width: Metric.stepDash.width, height: Metric.stepDash.height)
            }
            Text("Step \(current.rawValue) of \(OnboardingModel.Step.allCases.count)")
                .textStyle(.caption)
                .padding(.leading, Space.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue) of \(OnboardingModel.Step.allCases.count)")
    }
}

/// One numbered line of the access guide.
private struct GuideLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(number)")
                .font(Typo.label)
                .foregroundStyle(Palette.inkFixed)
                .frame(width: Metric.guideNumber, height: Metric.guideNumber)
                .background(Circle().fill(Palette.sun))
                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: Stroke.outline))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Space.xxs }
            Text(text)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Welcome") {
    OnboardingView(model: AppState.shared.onboarding)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
