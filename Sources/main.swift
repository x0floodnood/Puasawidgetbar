import AppKit
import SwiftUI

struct DailySchedule {
    let imsak: String
    let sahur: String
    let maghrib: String

    static let surabaya = DailySchedule(imsak: "04:04", sahur: "04:14", maghrib: "17:52")
}

enum PuasaState {
    case beforeImsak
    case fasting
    case afterMaghrib

    var title: String {
        switch self {
        case .beforeImsak: return "Belum Mulai Puasa"
        case .fasting: return "Sedang Berpuasa"
        case .afterMaghrib: return "Sudah Berbuka"
        }
    }

    var targetLabel: String {
        switch self {
        case .beforeImsak: return "menuju imsak"
        case .fasting: return "lagi"
        case .afterMaghrib: return "menuju imsak"
        }
    }
}

@MainActor
final class PuasaViewModel: ObservableObject {
    @Published var now = Date()
    @Published var schedule = DailySchedule.surabaya

    private var timer: Timer?
    private let calendar = Calendar.current

    init() {
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        now = Date()
    }

    var cityText: String {
        "Surabaya, Indonesia"
    }

    var gregorianAndHijriDate: String {
        let gregorian = DateFormatter()
        gregorian.locale = Locale(identifier: "id_ID")
        gregorian.dateFormat = "d MMM yyyy"

        let hijri = DateFormatter()
        hijri.locale = Locale(identifier: "id_ID")
        hijri.calendar = Calendar(identifier: .islamicUmmAlQura)
        hijri.dateFormat = "d MMMM yyyy"

        return "\(gregorian.string(from: now)) / \(hijri.string(from: now))"
    }

    var maghribLabel: String {
        schedule.maghrib
    }

    var puasaState: PuasaState {
        let imsakDate = dateToday(for: schedule.imsak)
        let maghribDate = dateToday(for: schedule.maghrib)

        if now < imsakDate { return .beforeImsak }
        if now < maghribDate { return .fasting }
        return .afterMaghrib
    }

    var countdownText: String {
        let target: Date
        switch puasaState {
        case .beforeImsak:
            target = dateToday(for: schedule.imsak)
        case .fasting:
            target = dateToday(for: schedule.maghrib)
        case .afterMaghrib:
            target = calendar.date(byAdding: .day, value: 1, to: dateToday(for: schedule.imsak)) ?? now
        }

        let seconds = max(0, Int(target.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours)j \(minutes)m \(puasaState.targetLabel)"
    }

    var menuBarTime: String {
        schedule.maghrib
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
            }
        }
    }

    private func dateToday(for time: String) -> Date {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
        else {
            return now
        }
        return date
    }
}

struct PuasaMenuView: View {
    @ObservedObject var viewModel: PuasaViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.green)
                Text("Puasa")
                    .font(.title3.weight(.bold))
            }

            Divider()

            row(icon: "location.fill", label: viewModel.cityText)
            row(icon: "calendar", label: viewModel.gregorianAndHijriDate)

            Divider()

            prayerRow(icon: "moon.zzz.fill", title: "Imsak", time: viewModel.schedule.imsak)
            prayerRow(icon: "sunrise.fill", title: "Sahur (Subuh)", time: viewModel.schedule.sahur)
            prayerRow(icon: "sunset.fill", title: "Berbuka (Maghrib)", time: viewModel.schedule.maghrib)

            Divider()

            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                    Text(viewModel.puasaState.title)
                        .font(.headline)
                }
                Spacer()
                Text(viewModel.countdownText)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    viewModel.refresh()
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.title3.weight(.semibold))
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 430)
    }

    private func row(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func prayerRow(icon: String, title: String, time: String) -> some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            Spacer()
            Text(time)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct PuasaWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = PuasaViewModel()

    var body: some Scene {
        MenuBarExtra {
            PuasaMenuView(viewModel: viewModel)
        } label: {
            Label("B:\(viewModel.menuBarTime)", systemImage: "moon.stars.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
