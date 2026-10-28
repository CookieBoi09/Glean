import SwiftUI
import WidgetKit

private struct ModelEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

private struct ModelProvider: TimelineProvider {
    func placeholder(in context: Context) -> ModelEntry {
        ModelEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ModelEntry) -> Void) {
        completion(ModelEntry(date: Date(), snapshot: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ModelEntry>) -> Void) {
        let entry = ModelEntry(date: Date(), snapshot: WidgetStore.load())
        // The host app explicitly requests a reload after saving a new view.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct ModelWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ModelEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                savedView(snapshot)
            } else {
                emptyView
            }
        }
        .containerBackground(for: .widget) {
            Color(red: 0.07, green: 0.09, blue: 0.12)
        }
        .widgetURL(URL(string: "glean://viewer"))
    }

    private func savedView(_ snapshot: WidgetSnapshot) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if family == .systemMedium {
                    // A square render must fit the wide family: cropping it
                    // would remove the model's head and feet. Extend the photo
                    // softly into the side margins while retaining the view.
                    ZStack {
                        Image(uiImage: snapshot.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 18)
                            .overlay(.black.opacity(0.22))
                        Image(uiImage: snapshot.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                } else {
                    Image(uiImage: snapshot.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.05), .black.opacity(0.65)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.modelName)
                        .font(.system(family == .systemSmall ? .caption : .subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    if family != .systemSmall {
                        Label("Open to explore", systemImage: "cube.transparent")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved 3D view: \(snapshot.modelName)")
        .accessibilityHint("Opens Glean to rotate the model with your iPad.")
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: family == .systemSmall ? 27 : 38, weight: .light))
                .foregroundStyle(Color(red: 0.64, green: 0.87, blue: 0.91))
            Spacer(minLength: 0)
            Text("Your world,\nin a widget.")
                .font(.system(family == .systemSmall ? .headline : .title2, design: .rounded, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Open Glean and save a view.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(family == .systemSmall ? 16 : 22)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the 3D viewer and widget editor.")
    }
}

struct GleanModelWidget: Widget {
    let kind = "GleanModelWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ModelProvider()) { entry in
            ModelWidgetView(entry: entry)
        }
        .configurationDisplayName("Glean 3D")
        .description("A saved view of your favorite 3D model and photo background. Tap to explore in Glean.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct GleanWidgets: WidgetBundle {
    var body: some Widget {
        GleanModelWidget()
    }
}
