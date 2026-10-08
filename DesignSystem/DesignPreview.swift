import SwiftUI

/// Every token and component on one sheet, in light and dark side by side.
/// Open it in the Xcode canvas, or in a DEBUG build with the launch argument
/// `-designPreview YES` (or Debug ▸ Design Preview).
struct DesignPreview: View {
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 0) {
                DesignSheet().environment(\.colorScheme, .light)
                DesignSheet().environment(\.colorScheme, .dark)
            }
        }
        .background(Palette.paper)
    }
}

/// One appearance's worth of the design system.
struct DesignSheet: View {
    @State private var rowSelected = true
    @State private var rowTwoSelected = false
    @State private var progress = 0.62

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(scheme == .dark ? "Dark" : "Light").textStyle(.caption)
                Text("Dustpan").textStyle(.display)
            }

            section("Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: Space.m), count: 5), spacing: Space.m)
                {
                    ForEach(Palette.all, id: \.name) { swatch in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            // Swatch over paper so translucent tokens (line) show as they render.
                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                .fill(swatch.color)
                                .frame(height: Space.xxl)
                                .inkSurface(Palette.paper, radius: Radius.small)
                            Text(swatch.name).textStyle(.caption)
                        }
                    }
                }
                .fixedSize()
            }

            section("Category map") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: Space.m), count: 5), spacing: Space.m)
                {
                    ForEach(Tone.allCases, id: \.self) { tone in
                        HStack(spacing: Space.xs) {
                            RoundedRectangle(cornerRadius: Radius.small / 3)
                                .fill(tone.fill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.small / 3).strokeBorder(
                                        Palette.ink, lineWidth: Stroke.outline)
                                )
                                .frame(width: Metric.sidebarGlyph, height: Metric.sidebarGlyph)
                            Text(tone.rawValue).textStyle(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .fixedSize()
            }

            section("Type") {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("18.4 GB").textStyle(.bigNumber)
                    Text("Display 64 black").textStyle(.display)
                    Text("Title, Archivo 28 bold").textStyle(.title)
                    Text("Headline, 17 semibold").textStyle(.headline)
                    Text("Body, 14. 12,431 cache files from 38 apps — safe to remove, apps rebuild them.")
                        .textStyle(.body)
                    Text("Caption, 12. Modified 3 days ago").textStyle(.caption)
                }
            }

            section("Radius · spacing · outline") {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack(spacing: Space.l) {
                        ForEach([Radius.small, Radius.medium, Radius.large], id: \.self) { r in
                            Text("\(Int(r))").textStyle(.headline)
                                .frame(width: 88, height: 64)
                                .inkSurface(Palette.paper, radius: r)
                        }
                    }
                    HStack(alignment: .bottom, spacing: Space.s) {
                        ForEach(Space.scale, id: \.self) { step in
                            VStack(spacing: Space.xxs) {
                                Rectangle().fill(Palette.ink).frame(width: step, height: step)
                                Text("\(Int(step))").textStyle(.caption)
                            }
                        }
                    }
                }
            }

            section("Buttons") {
                HStack(spacing: Space.l) {
                    InkButton("Move 4.2 GB to Trash", systemImage: "trash") {}
                    InkButton("Review items", kind: .secondary) {}
                    InkButton("Disabled") {}.disabled(true)
                }
            }

            section("Tiles") {
                HStack(spacing: Space.l) {
                    Tile(tone: .userCache, bytes: 6_420_000_000, label: "App caches")
                    Tile(tone: .dev, bytes: 11_900_000_000, label: "Developer files")
                    Tile(tone: .logs, bytes: 412_000_000, label: "Logs")
                }
                .frame(width: 760)
            }

            section("Rows & pills") {
                VStack(spacing: 0) {
                    ExplainRow(
                        isSelected: $rowSelected, systemImage: "shippingbox", tone: .userCache,
                        name: "Safari cache", bytes: 1_240_000_000,
                        why: "Copies of web pages Safari saved to load them faster. Safari rebuilds them.", risk: .safe)
                    ExplainRow(
                        isSelected: $rowTwoSelected, systemImage: "hammer", tone: .xcode,
                        name: "Xcode DerivedData", bytes: 8_900_000_000,
                        why: "Build output from projects. Your next build will take longer once.", risk: .review)
                }
                .frame(width: 760)
                .inkSurface(Palette.paper, radius: Radius.medium)
                HStack(spacing: Space.s) {
                    ForEach(RiskLevel.allCases, id: \.self) { RiskPill(risk: $0) }
                }
            }

            section("Size bar") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    SizeBar(value: 280_000_000_000, total: 494_000_000_000)
                    Text("214 GB free of 494 GB").textStyle(.caption)
                    SizeBar(value: 120_000_000_000, total: 494_000_000_000, tone: .spaceMap)
                }
                .frame(width: 320)
            }

            section("Progress blob") {
                HStack(spacing: Space.xxl) {
                    ProgressBlob(progress: 0.0)
                    ProgressBlob(progress: progress, tone: .clutter)
                    ProgressBlob(progress: 1.0, tone: .apps)
                }
            }

            section("Illustrations") {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(180), spacing: Space.l), count: 4), spacing: Space.l
                ) {
                    ForEach(Illustration.allCases, id: \.self) { kind in
                        VStack(spacing: Space.xs) {
                            IllustrationView(kind: kind).frame(height: 135)
                            Text(kind.rawValue).textStyle(.caption)
                        }
                    }
                }
                .fixedSize()
            }

            section("Empty state") {
                EmptyState(
                    "Nothing swept yet.",
                    actionTitle: "Scan this Mac", actionSymbol: "magnifyingglass", action: {}
                ) {
                    IllustrationView(kind: .sweep)
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 880, alignment: .leading)
        .background(Palette.paper)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).textStyle(.title)
            Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
            content()
        }
    }
}

#Preview("Design — light") {
    DesignSheet()
        .environment(\.colorScheme, .light)
        .frame(height: 3200)
}

#Preview("Design — dark") {
    DesignSheet()
        .environment(\.colorScheme, .dark)
        .frame(height: 3200)
}

#Preview("Design — side by side") {
    DesignPreview()
        .frame(width: 1760, height: 1200)
}
