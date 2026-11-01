import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct AudioInputOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct AudioLevelMeters: View {
    enum Orientation { case vertical, horizontal }
    let levels: [Float]
    var height: CGFloat = 100
    var showsChannelLabels = true
    var orientation: Orientation = .vertical
    var body: some View {
        Group {
        if orientation == .vertical {
        HStack(alignment: .bottom, spacing: 5) {
            // Keep L and R visible. An unavailable channel is an empty gray
            // track—not a duplicated or synthetic audio signal.
            ForEach(Array(displayedTracks.enumerated()), id: \.offset) { index, level in
                VStack(spacing: 5) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.12))
                            if let level {
                                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red],
                                                               startPoint: .bottom, endPoint: .top))
                                    .frame(height: geometry.size.height * CGFloat((min(0, max(-60, level)) + 60) / 60))
                            }
                        }
                    }.frame(width: 7)
                    if showsChannelLabels {
                        Text(index == 0 ? "L" : "R").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
        }.frame(height: height)
        } else {
            // Compact horizontal tracks keep the left-side Audio control in
            // the same rectangle family as Ratio and Grid.
            VStack(spacing: 3) {
                ForEach(Array(displayedTracks.enumerated()), id: \.offset) { index, level in
                    HStack(spacing: 3) {
                        if showsChannelLabels {
                            Text(index == 0 ? "L" : "R")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 7, alignment: .leading)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                if let level {
                                    Capsule().fill(LinearGradient(colors: [.green, .yellow, .red],
                                                                   startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geometry.size.width * CGFloat((min(0, max(-60, level)) + 60) / 60))
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
            .frame(height: height)
        }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio input levels")
            .accessibilityValue(levels.isEmpty ? "Unavailable" : levels.map { String(format: "%.0f decibels", $0) }.joined(separator: ", "))
    }

    private var displayedTracks: [Float?] {
        [levels.indices.contains(0) ? levels[0] : nil,
         levels.indices.contains(1) ? levels[1] : nil]
    }
}

struct AudioControlsView: View {
    @EnvironmentObject private var camera: CameraController
    var body: some View {
        List {
            Section("Input meters") {
                HStack {
                    Spacer()
                    AudioLevelMeters(levels: camera.audioLevels)
                    VStack { Text("0"); Spacer(); Text("−30"); Spacer(); Text("−60") }
                        .font(.caption2).foregroundStyle(.secondary).frame(height: 85)
                    Spacer()
                }.padding(.vertical, 8)
                Text(camera.audioStatus).font(.caption).foregroundStyle(.secondary)
                LabeledContent("On-camera tracks", value: camera.audioLevels.count >= 2 ? "2 channels" : "1 channel")
                Text("The top-left meter automatically shows a second track only when the selected input supplies a second capture channel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio input") {
                if camera.audioInputs.isEmpty {
                    Text("No available input").foregroundStyle(.secondary)
                } else {
                    AudioDeviceDragSelector(title: "Input device", options: camera.audioInputs,
                                            selection: camera.audioInputID,
                                            onSelect: camera.selectAudioInput)
                        .disabled(camera.isRecording)
                }
                LabeledContent("Input gain", value: camera.audioGainSupported ? String(format: "%.0f%%", camera.audioGain * 100) : "Hardware controlled")
                if camera.audioGainSupported {
                    Slider(value: Binding(get: { camera.audioGain }, set: { camera.setAudioGain($0) }), in: 0...1)
                        .accessibilityLabel("Microphone input gain")
                }
                Text("Gain adjustment is available only when the connected microphone supports it. Input changes are disabled during recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Channel layout") {
                Picker("Capture channels", selection: Binding(get: { camera.audioChannelMode }, set: { camera.setAudioChannelMode($0) })) {
                    ForEach(AudioChannelMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(camera.isRecording)
                Text("Stereo requests two channels from the selected microphone. A mono microphone leaves R empty instead of duplicating L.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output route") {
                Picker("Output", selection: Binding(get: { camera.audioOutputMode }, set: { camera.setAudioOutputMode($0) })) {
                    ForEach(AudioOutputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Current route", value: camera.audioOutputName)
                Text("System follows headphones/Bluetooth automatically; Speaker requests the phone speaker. This does not alter the recorded audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Audio").tint(InCamTheme.ivory)
    }
}

/// A compact drag selector matches the camera's ruler-style controls. Output
/// remains display-only because iOS chooses the physical output route.
private struct AudioDeviceDragSelector: View {
    let title: String
    let options: [AudioInputOption]
    let selection: String
    let onSelect: (String) -> Void
    @State private var originIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            GeometryReader { proxy in
                let selectedIndex = options.firstIndex { $0.id == selection } ?? 0
                let index = min(options.count - 1, max(0, originIndex ?? selectedIndex))
                Text(options.isEmpty ? "Unavailable" : options[index].name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            guard !options.isEmpty else { return }
                            let start = originIndex ?? selectedIndex
                            originIndex = start
                            let step = Int((drag.translation.width / max(36, proxy.size.width / 3)).rounded())
                            let target = min(options.count - 1, max(0, start + step))
                            onSelect(options[target].id)
                        }
                        .onEnded { _ in originIndex = nil })
            }
            .frame(height: 36)
            Text("Drag left or right to choose an available input.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A private in-app gallery. It displays only copies created by InCam and
/// never asks to browse the user's existing Photos library.
struct SavedMediaGallery: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SavedMediaGalleryModel()
    @State private var selected: SavedMediaSelection?
    @State private var displayedMonth = Date()
    @State private var scope: CalendarGalleryScope = .month
    @State private var focusedDate = Date()

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            Group {
                if model.media.isEmpty {
                    ContentUnavailableView("No Saved Media", systemImage: "photo",
                                           description: Text("Photos and videos captured with InCam will appear here."))
                } else {
                    calendarContent
                }
            }
            .background(.black)
            .navigationTitle("Gallery")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                model.load()
                if let newest = model.media.first?.createdAt {
                    displayedMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: newest)) ?? newest
                    focusedDate = newest
                }
            }
            .sheet(item: $selected) { selection in SavedMediaDetail(media: selection.media) }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var calendarContent: some View {
        switch scope {
        case .month:
            CalendarMonthAlbumGrid(month: $displayedMonth, media: model.media) { date in
                focusedDate = date
                withAnimation(.snappy) { scope = .week }
            }
        case .week:
            CalendarWeekGallery(date: focusedDate, media: model.media,
                                onOpenDay: { date in
                                    focusedDate = date
                                    withAnimation(.snappy) { scope = .day }
                                },
                                onZoomOut: {
                                    displayedMonth = monthContaining(focusedDate)
                                    withAnimation(.snappy) { scope = .month }
                                })
        case .day:
            CalendarDayGallery(date: focusedDate, media: model.media, onSelect: select) {
                withAnimation(.snappy) { scope = .week }
            }
        }
    }

    private func select(_ media: InCamSavedMedia) {
        selected = SavedMediaSelection(media: media)
    }

    private func monthContaining(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}

private enum CalendarGalleryScope { case month, week, day }

/// Album-style month view. A square represents a week and uses the first
/// captured day in that week for its cover. Entering a week reveals the seven
/// individual day squares; entering a day reveals that day's media.
private struct CalendarMonthAlbumGrid: View {
    @Binding var month: Date
    let media: [InCamSavedMedia]
    let onOpenWeek: (Date) -> Void
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 3)
    @State private var gridWidth: CGFloat = 1
    @State private var lastTouch = CGPoint(x: -1, y: -1)

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }

    private var weekStarts: [Date] {
        guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart),
              var week = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start else { return [] }
        var values: [Date] = []
        while week < monthEnd {
            values.append(week)
            guard let next = calendar.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return values
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(monthStart.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                }
                .padding(.horizontal, 14)

                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(weekStarts, id: \.self) { week in
                        CalendarWeekTile(weekStart: week, captures: captures(in: week)) {
                            onOpenWeek(week)
                        }
                    }
                }
                .contentShape(Rectangle())
                .background(widthReader)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { lastTouch = $0.location }
                )
                .simultaneousGesture(
                    MagnifyGesture().onEnded { value in
                        guard value.magnification > 1.12 else { return }
                        onOpenWeek(weekAtPinch)
                    }
                )
                // Five points on every edge and between every square.
                .padding(5)
                .background(.white.opacity(0.42))
            }
        }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { gridWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in gridWidth = width }
        }
    }

    private var weekAtPinch: Date {
        guard gridWidth > 1, lastTouch.x >= 0, lastTouch.y >= 0, !weekStarts.isEmpty else {
            return weekStarts.first ?? monthStart
        }
        let cell = (gridWidth - 20) / 3
        let column = max(0, min(2, Int(lastTouch.x / (cell + 5))))
        let row = max(0, Int(lastTouch.y / (cell + 5)))
        let index = min(weekStarts.count - 1, row * 3 + column)
        return weekStarts[index]
    }

    private func captures(in weekStart: Date) -> [InCamSavedMedia] {
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
        return media.filter { $0.createdAt >= weekStart && $0.createdAt < weekEnd }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func changeMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: monthStart) ?? monthStart
    }
}

private struct CalendarWeekTile: View {
    let weekStart: Date
    let captures: [InCamSavedMedia]
    let action: () -> Void
    private let calendar = Calendar.current

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let cover = captures.first {
                    SavedMediaThumbnail(media: cover).clipped()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.055))
                }
                LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Week of \(weekStart.formatted(.dateTime.month(.abbreviated).day()))")
                    Text(captures.isEmpty ? "No captures" : "\(captures.count) capture\(captures.count == 1 ? "" : "s")")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(7)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Week of \(weekStart.formatted(.dateTime.month(.wide).day()))")
    }
}

/// Pinching in on a month enters this seven-day slice; pinching a second time
/// enters the day beneath the gesture. Pinching back out reverses that path.
private struct CalendarWeekGallery: View {
    let date: Date
    let media: [InCamSavedMedia]
    let onOpenDay: (Date) -> Void
    let onZoomOut: () -> Void
    private let calendar = Calendar.current
    @State private var stripWidth: CGFloat = 1
    @State private var lastTouch = CGPoint(x: -1, y: -1)

    private var weekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private var dayMedia: [Date: [InCamSavedMedia]] {
        Dictionary(grouping: media, by: { calendar.startOfDay(for: $0.createdAt) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Week of \(weekStart.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .padding(.top, 8)
                HStack(spacing: 5) {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
                        VStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            CalendarDayTile(date: day, captures: dayMedia[calendar.startOfDay(for: day)] ?? []) {
                                onOpenDay(day)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { stripWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in stripWidth = width }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { lastTouch = $0.location })
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    if value.magnification > 1.12 {
                        onOpenDay(dayAtPinch)
                    } else if value.magnification < 0.88 {
                        onZoomOut()
                    }
                })
                .padding(5)
                .background(.white.opacity(0.42))
                Text("Pinch in for a day · pinch out for the month")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dayAtPinch: Date {
        guard stripWidth > 1, lastTouch.x >= 0 else { return weekStart }
        let width = (stripWidth - 30) / 7
        let index = max(0, min(6, Int(lastTouch.x / (width + 5))))
        return calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
    }
}

private struct CalendarDayGallery: View {
    let date: Date
    let media: [InCamSavedMedia]
    let onSelect: (InCamSavedMedia) -> Void
    let onZoomOut: () -> Void
    private let calendar = Calendar.current
    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 5)]

    private var captures: [InCamSavedMedia] {
        media.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .padding(.top, 8)
                if captures.isEmpty {
                    ContentUnavailableView("No InCam captures", systemImage: "photo", description: Text("Pinch out to return to the week."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(captures) { media in
                            Button { onSelect(media) } label: {
                                SavedMediaThumbnail(media: media)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(.white.opacity(0.42))
                }
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            if value.magnification < 0.88 { onZoomOut() }
        })
    }
}

private struct CalendarDayTile: View {
    let date: Date
    let captures: [InCamSavedMedia]
    let onOpen: () -> Void
    private let calendar = Calendar.current

    var body: some View {
        Button {
            onOpen()
        } label: {
            ZStack(alignment: .topLeading) {
                if let media = captures.first {
                    SavedMediaThumbnail(media: media).clipped()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.055))
                }
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(4)
                    .background {
                        if calendar.isDateInToday(date) {
                            Circle().stroke(.red, lineWidth: 2)
                        }
                    }
                    .shadow(color: .black, radius: 2)
                if captures.count > 1 {
                    Text("\(captures.count)").font(.system(size: 8, weight: .bold))
                        .padding(4).background(.black.opacity(0.58), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(3)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }
}

private struct SavedMediaSelection: Identifiable {
    let media: InCamSavedMedia
    var id: UUID { media.id }
}

@MainActor
private final class SavedMediaGalleryModel: ObservableObject {
    @Published var media: [InCamSavedMedia] = []
    private static let mediaKey = "incam.private-media.v1"

    func load() {
        let data = UserDefaults.standard.data(forKey: Self.mediaKey) ?? Data()
        let saved = (try? JSONDecoder().decode([InCamSavedMedia].self, from: data)) ?? []
        media = saved
            .filter { FileManager.default.fileExists(atPath: mediaURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

private struct SavedMediaThumbnail: View {
    let media: InCamSavedMedia
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color(white: 0.12) }
            if media.kind == .video {
                Image(systemName: "video.fill").font(.caption).padding(5)
                    .background(.black.opacity(0.55), in: Circle()).padding(5)
            }
        }
        .task(id: media.id) {
            image = mediaThumbnail(media, size: CGSize(width: 300, height: 300))
        }
    }
}

private struct SavedMediaDetail: View {
    @Environment(\.dismiss) private var dismiss
    let media: InCamSavedMedia
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if media.kind == .video, let player { VideoPlayer(player: player).onAppear { player.play() } }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView() }
        }
        .task {
            if media.kind == .video { player = AVPlayer(url: mediaURL(for: media)) }
            else { image = UIImage(contentsOfFile: mediaURL(for: media).path) }
        }
        .overlay(alignment: .topTrailing) { Button("Done") { dismiss() }.padding() }
    }
}

/// Both capture and gallery use this app-private directory. Nothing here is
/// fetched from, or gives browsing access to, the user's Photos library.
private func mediaURL(for media: InCamSavedMedia) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InCam Media", isDirectory: true)
        .appendingPathComponent(media.filename)
}

private func mediaThumbnail(_ media: InCamSavedMedia, size: CGSize) -> UIImage? {
    let url = mediaURL(for: media)
    if media.kind == .photo { return UIImage(contentsOfFile: url.path) }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = size
    guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return UIImage(cgImage: image)
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var colors: CameraColorStore
    @EnvironmentObject private var preferences: CameraScreenPreferences
    @AppStorage("incam.controls.layout") private var controlLayout = CameraControlLayout.floating
    @AppStorage("incam.capture.photoEnabled") private var photoEnabled = false
    @AppStorage("incam.settings.favorite.zoom") private var favoriteZoom = true
    @AppStorage("incam.settings.favorite.composition") private var favoriteComposition = true
    @AppStorage("incam.settings.favorite.looks") private var favoriteLooks = true
    @AppStorage("incam.settings.favorite.screen") private var favoriteScreen = false
    @ObservedObject private var orientation = CameraOrientation.shared
    /// `nil` is the V1.4 Settings Home. Keeping the page index in this view
    /// means a back action from any submenu returns to the same swipe page.
    @State private var category: SettingsCategory?
    @State private var settingsHomePage = 0

    var body: some View {
        NavigationStack {
            Group {
                if let category {
                    settingsDetail(for: category)
                } else {
                    settingsHome
                }
            }
            .background(InCamTheme.graphite)
            .tint(InCamTheme.ivory)
        }
    }

    /// The V1.4 home is deliberately just the requested paged 3 × 2 grid.
    /// Descriptions belong to detail pages, not to the category tiles.
    private var settingsHome: some View {
        TabView(selection: $settingsHomePage) {
            settingsHomePageGrid(SettingsCategory.firstPage)
                .tag(0)
            settingsHomePageGrid(SettingsCategory.secondPage)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .navigationTitle("Camera Settings")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .accessibilityIdentifier("settings.home")
    }

    private func settingsHomePageGrid(_ categories: [SettingsCategory]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
            ForEach(categories) { category in
                Button { self.category = category } label: {
                    VStack(spacing: 14) {
                        Image(systemName: category.icon)
                            .font(.system(size: 29, weight: .medium))
                            .frame(height: 32)
                        Text(category.rawValue)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(InCamTheme.ivory)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color(red: 0.15, green: 0.17, blue: 0.20), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Open \(category.rawValue) settings")
                .accessibilityIdentifier("settings.category.\(category.id)")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 32)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func settingsDetail(for category: SettingsCategory) -> some View {
        List {
            switch category {
            case .myMenu: favoritesSettings
            case .video: videoSettings
            case .audio: audioSettings
            case .photo: photoSettings
            case .monitoring: monitoringSettings
            case .color: colorSettings
            case .recording: recordingSettings
            case .focus: focusSettings
            case .exposure: exposureSettings
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { self.category = nil } label: {
                    Label("Camera Settings", systemImage: "chevron.left")
                }
            }
        }
        .accessibilityIdentifier("settings.detail.\(category.id)")
    }

    /// Favorites is a small personal menu, not a duplicate settings screen.
    /// People choose which commonly-used groups appear here, and each control
    /// edits the same underlying camera preference as its category tab.
    @ViewBuilder private var favoritesSettings: some View {
        Section("Choose favorites") {
            Toggle("Zoom cap", isOn: $favoriteZoom)
            Toggle("Composition", isOn: $favoriteComposition)
            Toggle("Camera Colors", isOn: $favoriteLooks)
            Toggle("Camera screen", isOn: $favoriteScreen)
        }
        if favoriteZoom { zoomSection }
        if favoriteComposition { compositionSection }
        if favoriteLooks {
            Section("Camera Colors") {
                NavigationLink { CameraColorLibraryView() } label: { settingsLabel("Camera Colors", "camera.filters") }
            }
        }
        if favoriteScreen { screenSection }
    }

    @ViewBuilder private var videoSettings: some View {
        Section("Video format") {
            Picker("Resolution", selection: Binding(get: { camera.videoResolution }, set: { camera.setVideoResolution($0) })) {
                ForEach(camera.availableVideoResolutions) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording)
            Picker("Frame rate", selection: Binding(get: { camera.frameRate }, set: { camera.setFrameRate($0) })) {
                ForEach(camera.capabilities.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .disabled(camera.isRecording)
            Picker("Codec", selection: Binding(get: { camera.videoCodec }, set: { camera.setVideoCodec($0) })) {
                ForEach(camera.availableVideoCodecs) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording)
            Picker("Stabilization", selection: Binding(get: { camera.videoStabilization }, set: { camera.setVideoStabilization($0) })) {
                ForEach(camera.availableVideoStabilizations) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording || camera.availableVideoStabilizations.count < 2)
            Text(camera.availableVideoStabilizations.count < 2
                 ? "This lens and format do not offer video stabilization."
                 : "Modes are shown only when the active lens and format support them. Stabilization can add a little capture latency.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Capture file naming") {
                TextField("Folder (4–5 letters/numbers)", text: Binding(
                    get: { camera.recordingFolderName },
                    set: { camera.setRecordingFolderName($0) }))
                    .textInputAutocapitalization(.characters)
                    .disabled(camera.recordingNamingMode == .date || camera.isRecording)
                TextField("App prefix", text: Binding(
                    get: { camera.recordingPrefix },
                    set: { camera.setRecordingPrefix($0) }))
                    .textInputAutocapitalization(.characters)
                    .disabled(camera.recordingNamingMode == .date || camera.isRecording)
                Picker("Folder style", selection: Binding(get: { camera.recordingNamingMode }, set: { camera.setRecordingNamingMode($0) })) {
                    ForEach(RecordingNamingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(camera.isRecording)
                Text(camera.recordingNamingMode == .date
                     ? "Example: 2026-10-25/2026-10-25_0001.mov"
                     : "Example: \(camera.recordingFolderName)/\(camera.recordingPrefix)_\(camera.recordingFolderName)_0001.mov")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Log recipe mode", isOn: Binding(get: { camera.logModeEnabled }, set: { camera.setLogModeEnabled($0) }))
                .disabled(camera.isRecording)
            if camera.videoHDRSupported {
                Toggle("HDR", isOn: Binding(get: { camera.videoHDREnabled }, set: { camera.setVideoHDREnabled($0) }))
                    .disabled(camera.isRecording)
            }
        }
        screenSection
        zoomSection
        compositionSection
    }

    @ViewBuilder private var photoSettings: some View {
        Section("Photo capture") {
            Toggle("Enable Photo mode", isOn: $photoEnabled)
                .disabled(camera.isRecording)
                .accessibilityIdentifier("settings.photoEnabled")
            Picker("Photo format", selection: Binding(get: { camera.photoFormat }, set: { camera.setPhotoFormat($0) })) {
                ForEach(camera.capabilities.photoFormats, id: \.self) { Text($0).tag($0) }
            }
            .disabled(camera.isRecording)
            LabeledContent("RAW", value: camera.rawPhotoSupported ? "Supported" : "Unavailable on this format")
            Picker("Photo responsiveness", selection: Binding(get: { camera.photoSpeedMode }, set: { camera.setPhotoSpeedMode($0) })) {
                Text(PhotoSpeedMode.standard.rawValue).tag(PhotoSpeedMode.standard)
                if camera.responsivePhotoCaptureSupported {
                    Text(PhotoSpeedMode.responsive.rawValue).tag(PhotoSpeedMode.responsive)
                }
            }
            .disabled(camera.isRecording || !camera.responsivePhotoCaptureSupported)
            Text(camera.responsivePhotoCaptureSupported
                 ? "Responsive uses supported Zero Shutter Lag buffers for quicker stills. It may use more memory and battery while selected."
                 : "Responsive capture is unavailable on this camera format. Deferred photo delivery stays off so captures remain in InCam’s private gallery.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Photos from InCam") {
            Text("The in-app gallery contains only media saved by InCam. It does not browse your full Photos library.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var audioSettings: some View {
        Section("Audio") {
            NavigationLink { AudioControlsView() } label: { settingsLabel("Audio input & meters", "waveform") }
            LabeledContent("Current input", value: camera.audioStatus)
        }
        Section {
            Text("Input selection and gain are unavailable while recording, and unavailable hardware is shown as empty meters rather than simulated audio.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var monitoringSettings: some View {
        Section("Monitoring") {
            Toggle("Leveler", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "incam.composition.level.enabled") },
                set: { UserDefaults.standard.set($0, forKey: "incam.composition.level.enabled") }
            ))
            Toggle("Show audio meters", isOn: .constant(true))
                .disabled(true)
            Text("Level, grid and meter overlays affect the viewfinder only; they are never recorded into media.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var colorSettings: some View {
        Section("Camera Color") {
            NavigationLink { CameraColorLibraryView() } label: {
                settingsLabel("Camera Color Studio", "camera.filters")
            }
            Text("Color Styles are edited here. The viewfinder only selects None or assigned C1–C9 profiles.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recordingSettings: some View {
        Section("File naming") {
            TextField("Folder (4–5 letters/numbers)", text: Binding(
                get: { camera.recordingFolderName },
                set: { camera.setRecordingFolderName($0) }))
                .textInputAutocapitalization(.characters)
                .disabled(camera.recordingNamingMode == .date || camera.isRecording)
            TextField("App prefix", text: Binding(
                get: { camera.recordingPrefix },
                set: { camera.setRecordingPrefix($0) }))
                .textInputAutocapitalization(.characters)
                .disabled(camera.recordingNamingMode == .date || camera.isRecording)
            Picker("Folder style", selection: Binding(get: { camera.recordingNamingMode }, set: { camera.setRecordingNamingMode($0) })) {
                ForEach(RecordingNamingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording)
        }
        Section("Capture status") {
            Text("Storage estimates and recording recovery are device- and destination-dependent.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var focusSettings: some View {
        Section("Autofocus") {
            LabeledContent("Current mode", value: camera.focusAuto ? "AF" : "MF")
            Text("The compact viewfinder AF/MF button remains the only mode switch. Focus behavior is stored per capture mode as support is added.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var exposureSettings: some View {
        Section("Exposure") {
            LabeledContent("Shutter display", value: camera.shutterAngleMode ? "Angle" : "Speed")
            Text("Double-tap the shutter value to switch between Speed and Angle without changing the actual duration.")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Exposure compensation", value: String(format: "%+.1f EV", camera.exposureBias))
        }
    }

    private var zoomSection: some View {
        Section("Zoom") {
            Picker("Maximum zoom", selection: Binding(get: { Double(camera.zoomCap) }, set: { camera.setZoomCap(CGFloat($0)) })) {
                ForEach([2.0, 3.0, 5.0, 7.0, 10.0], id: \.self) { cap in Text(String(format: "%.0f×", cap)).tag(cap) }
            }
            .disabled(camera.isRecording)
            Text("Caps camcorder drag zoom and the +/− controls. The selected lens may have a lower hardware maximum.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var screenSection: some View {
        Section("Camera screen") {
            Toggle("Show four grouped controls", isOn: $preferences.showQuickRow)
                .accessibilityIdentifier("settings.quickRow")
            Picker("Control layout", selection: $controlLayout) {
                ForEach(CameraControlLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
            }
            Picker("Orientation lock", selection: Binding(get: { orientation.selection }, set: { orientation.select($0) })) {
                ForEach(CameraOrientationLock.allCases.filter { $0 != .portrait }) { option in
                    Text(option == .unlocked ? "Either landscape side" : option.rawValue).tag(option)
                }
            }
            .disabled(camera.isRecording)
        }
    }

    private var compositionSection: some View {
        Section {
            Toggle("Save output in selected ratio", isOn: $preferences.saveFramedOutput)
                .disabled(camera.isRecording)
            ForEach(CompositionRatio.catalog + preferences.ratioShortcuts.filter { !CompositionRatio.catalog.contains($0) }) { ratio in
                let selected = preferences.ratioShortcuts.contains(ratio)
                Button { preferences.toggleRatio(ratio) } label: {
                    HStack {
                        Image(systemName: selected ? "minus.circle.fill" : "plus.circle.fill").foregroundStyle(selected ? .red : .green)
                        Text(ratio.rawValue).foregroundStyle(InCamTheme.ivory)
                        Spacer()
                        if selected { Text("Added").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityLabel("\(selected ? "Remove" : "Add") \(ratio.rawValue) ratio")
            }
        } header: {
            Text("Ratios")
        } footer: {
            Text(preferences.saveFramedOutput
                 ? "InCam center-crops saved photos and exports completed videos to the selected ratio. Changing the guide while recording does not alter the clip already in progress."
                 : "Ratios and grids are composition guides. Turn on Save output in selected ratio to crop saved photos and videos.")
        }
    }

    private func settingsRow(_ title: String, _ icon: String) -> some View {
        Button {} label: { settingsLabel(title, icon) }
            .foregroundStyle(InCamTheme.ivory)
    }

    private func settingsLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(InCamTheme.ivory)
    }
}

private enum SettingsCategory: String, Identifiable {
    case myMenu = "My Menu"
    case video = "Video"
    case audio = "Audio"
    case photo = "Photo"
    case monitoring = "Monitoring"
    case color = "Color"
    case recording = "Recording"
    case focus = "Focus"
    case exposure = "Exposure"

    static let firstPage: [SettingsCategory] = [.myMenu, .video, .audio, .photo, .monitoring, .color]
    static let secondPage: [SettingsCategory] = [.recording, .focus, .exposure]

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .myMenu: return "star"
        case .video: return "video"
        case .audio: return "mic"
        case .photo: return "camera"
        case .monitoring: return "chart.bar"
        case .color: return "paintpalette"
        case .recording: return "record.circle"
        case .focus: return "viewfinder"
        case .exposure: return "sun.max"
        }
    }
}

private struct ShortcutSettingsView: View {
    @EnvironmentObject private var shortcuts: ShortcutStore
    @EnvironmentObject private var preferences: CameraScreenPreferences
    @Environment(\.editMode) private var editMode

    var body: some View {
        List {
            Section {
                Toggle("Add Custom Button 1", isOn: $preferences.showCustom1)
                    .accessibilityIdentifier("settings.custom1")
                Toggle("Add Custom Button 2", isOn: $preferences.showCustom2)
                    .accessibilityIdentifier("settings.custom2")
            } footer: { Text("Custom buttons are optional. Enable a button and assign at least one action to show it. Turning it off keeps your assignments.") }
            if preferences.showCustom1 { shortcutSection("C1", name: $shortcuts.c1Name, values: $shortcuts.c1) }
            if preferences.showCustom2 { shortcutSection("C2", name: $shortcuts.c2Name, values: $shortcuts.c2) }
        }
        .navigationTitle("Thumb Controls")
        .toolbar { EditButton() }
    }

    private func shortcutSection(
        _ title: String,
        name: Binding<String>,
        values: Binding<[ShortcutAction]>
    ) -> some View {
        Section(title) {
            let assigned = values.wrappedValue.filter { $0 != .unassigned }
            if assigned.count > 1 {
                TextField("Custom group name", text: name)
                    .textInputAutocapitalization(.words)
            } else if let onlyAction = assigned.first {
                LabeledContent("Button name", value: onlyAction.rawValue)
            }
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                if editMode?.wrappedValue.isEditing == true {
                    Picker("Custom Button \(index + 1)", selection: values[index]) {
                        ForEach(ShortcutAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                } else {
                    LabeledContent(
                        "Custom Button \(index + 1)",
                        value: values.wrappedValue[index].rawValue)
                }
            }
            .onMove { source, destination in
                var reordered = values.wrappedValue
                reordered.move(fromOffsets: source, toOffset: destination)
                values.wrappedValue = reordered
            }
        }
    }
}

struct CameraColorLibraryView: View {
    @EnvironmentObject private var colors: CameraColorStore

    var body: some View {
        List {
            ForEach(Array(colors.slots.enumerated()), id: \.element.id) { index, recipe in
                NavigationLink {
                    CameraColorEditorView(recipe: recipe, sourceSlot: index)
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [.brown.opacity(0.8), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 54, height: 42)
                            .overlay(Text("\(index + 1)").font(.caption.bold()))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.name)
                            Text("Camera Color slot \(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink {
                CameraColorEditorView(recipe: CameraColorRecipe(name: "New Look"), sourceSlot: nil)
            } label: {
                Label("Create Camera Color", systemImage: "plus")
            }
            Section {
                Text("Camera Colors appear in the live preview and are applied to saved photos and videos. Videos finish rendering after you stop recording; their original audio is kept. RAW capture is not offered by this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Camera Colors")
    }
}
