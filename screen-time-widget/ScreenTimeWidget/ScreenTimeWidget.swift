import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Refresh Intent
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Screen Time"
    static var description = IntentDescription("Refreshes the screen time data")
    
    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "ScreenTimeWidget")
        return .result()
    }
}

// MARK: - Data Models
struct ScreenTimeData {
    let hours: Int
    let minutes: Int
    let screenBatteryPercent: Double
    let sleepBatteryPercent: Double
    let lastChargeTime: Date
    let lastChargeLevel: Int
}

// MARK: - Timeline Provider
struct ScreenTimeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScreenTimeEntry {
        ScreenTimeEntry(date: Date(), data: ScreenTimeData(
            hours: 0,
            minutes: 0,
            screenBatteryPercent: 0,
            sleepBatteryPercent: 0,
            lastChargeTime: Date(),
            lastChargeLevel: 100
        ))
    }
    
    func getSnapshot(in context: Context, completion: @escaping (ScreenTimeEntry) -> ()) {
        let entry = ScreenTimeEntry(date: Date(), data: fetchScreenTimeData())
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScreenTimeEntry>) -> ()) {
        let currentDate = Date()
        let entry = ScreenTimeEntry(date: currentDate, data: fetchScreenTimeData())
        
        // Update every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func fetchScreenTimeData() -> ScreenTimeData {
        print("🚀 ScreenTimeProvider: Fetching screen time data")
        let parser = PMSetLogParser()
        let data = parser.parse()
        print("🎯 ScreenTimeProvider: Got data - \(data.hours)h \(data.minutes)m")
        return data
    }
}

struct ScreenTimeEntry: TimelineEntry {
    let date: Date
    let data: ScreenTimeData
    let relevance: TimelineEntryRelevance? = nil
}

// MARK: - PMSet Log Parser
class PMSetLogParser {
    func parse() -> ScreenTimeData {
        print("🔍 PMSetLogParser: Starting parse")
        
        // Try different approaches to get pmset log
        var output: String = ""
        
        // Approach 1: Try with full path and shell
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "/usr/bin/pmset -g log | tail -n 5000"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let result = String(data: data, encoding: .utf8) {
                output = result
                print("📄 PMSetLogParser: Got output, length: \(output.count) characters")
                print("📄 PMSetLogParser: First 200 chars: \(String(output.prefix(200)))")
            }
        } catch {
            print("❌ PMSetLogParser: Error running pmset: \(error)")
        }
        
        if output.count < 200 {
            print("⚠️ PMSetLogParser: Output too short (\(output.count) chars), widget may need additional entitlements")
            print("⚠️ PMSetLogParser: Add com.apple.security.temporary-exception.mach-lookup.global-name")
            print("⚠️ PMSetLogParser: And com.apple.private.pmset to Info.plist")
        }
        
        let result = parseLog(output)
        print("✅ PMSetLogParser: Parsed result - Hours: \(result.hours), Minutes: \(result.minutes)")
        print("🔋 PMSetLogParser: Screen battery: \(result.screenBatteryPercent)%/h, Sleep: \(result.sleepBatteryPercent)%/h")
        print("⚡ PMSetLogParser: Last charge: \(result.lastChargeTime) at \(result.lastChargeLevel)%")
        return result
    }
    
    private func parseLog(_ log: String) -> ScreenTimeData {
        print("📊 parseLog: Starting to parse log")
        let lines = log.components(separatedBy: .newlines)
        print("📊 parseLog: Total lines: \(lines.count)")
        var lastChargeTime: Date?
        var lastChargeLevel = 100
        var screenOnIntervals: [(start: Date, end: Date?, batteryStart: Int, batteryEnd: Int?)] = []
        var sleepIntervals: [(start: Date, end: Date?, batteryStart: Int, batteryEnd: Int?)] = []
        var currentBatteryLevel = 100
        var isInDarkWake = false
        var lastBatteryLevel = 100
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        
        for (index, line) in lines.enumerated() {
            // Parse timestamp and battery level
            if let timestamp = extractTimestamp(from: line, formatter: dateFormatter) {
                if let battery = extractBatteryLevel(from: line) {
                    // Detect charging: battery level increased significantly
                    if battery > lastBatteryLevel + 5 {
                        lastChargeTime = timestamp
                        lastChargeLevel = battery
                        print("🔌 parseLog: Detected charge at \(timestamp) to \(battery)%")
                    }
                    lastBatteryLevel = battery
                    currentBatteryLevel = battery
                }
                
                // Detect charge events - look for battery going up significantly or "Using AC"
                if line.contains("Using AC") || line.contains("AC Power") {
                    lastChargeTime = timestamp
                    lastChargeLevel = currentBatteryLevel
                    print("🔌 parseLog: Detected AC connection at \(timestamp)")
                }
                
                // Detect DarkWake (system wake, not user wake)
                if line.contains("DarkWake") {
                    isInDarkWake = true
                } else if line.contains("Wake from") && !line.contains("DarkWake") {
                    isInDarkWake = false
                }
                
                // Detect display on/off (only count non-DarkWake display events)
                if line.contains("Display is turned on") && !isInDarkWake {
                    screenOnIntervals.append((start: timestamp, end: nil, batteryStart: currentBatteryLevel, batteryEnd: nil))
                    print("🖥️ parseLog: Display ON at \(timestamp), battery: \(currentBatteryLevel)%")
                } else if line.contains("Display is turned off") {
                    if screenOnIntervals.indices.contains(screenOnIntervals.count - 1),
                       screenOnIntervals[screenOnIntervals.count - 1].end == nil {
                        screenOnIntervals[screenOnIntervals.count - 1].end = timestamp
                        screenOnIntervals[screenOnIntervals.count - 1].batteryEnd = currentBatteryLevel
                        print("🖥️ parseLog: Display OFF at \(timestamp), battery: \(currentBatteryLevel)%")
                    }
                }
                
                // Detect sleep/wake
                if line.contains("Wake from") && !line.contains("DarkWake") {
                    if sleepIntervals.indices.contains(sleepIntervals.count - 1),
                       sleepIntervals[sleepIntervals.count - 1].end == nil {
                        sleepIntervals[sleepIntervals.count - 1].end = timestamp
                        sleepIntervals[sleepIntervals.count - 1].batteryEnd = currentBatteryLevel
                    }
                } else if line.contains("Entering Sleep state due to") {
                    sleepIntervals.append((start: timestamp, end: nil, batteryStart: currentBatteryLevel, batteryEnd: nil))
                }
            }
        }
        
        print("📊 parseLog: Found \(screenOnIntervals.count) screen intervals")
        print("📊 parseLog: Found \(sleepIntervals.count) sleep intervals")
        
        // Calculate totals since last charge
        // If no charge detected, look back 24 hours
        let chargeTime = lastChargeTime ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        print("⚡ parseLog: Using charge time: \(chargeTime)")
        
        var totalScreenSeconds = 0.0
        var totalBatteryDrain = 0.0
        
        for interval in screenOnIntervals {
            if interval.start > chargeTime {
                let end = interval.end ?? Date()
                let duration = end.timeIntervalSince(interval.start)
                totalScreenSeconds += duration
                
                if let batteryEnd = interval.batteryEnd {
                    let drain = Double(interval.batteryStart - batteryEnd)
                    totalBatteryDrain += drain
                    print("📊 parseLog: Screen interval: \(duration/60) mins, drain: \(drain)%")
                }
            }
        }
        
        print("📊 parseLog: Total screen seconds: \(totalScreenSeconds), total drain: \(totalBatteryDrain)%")
        
        var totalSleepSeconds = 0.0
        var sleepBatteryDrain = 0.0
        
        for interval in sleepIntervals {
            if interval.start > chargeTime {
                let end = interval.end ?? Date()
                totalSleepSeconds += end.timeIntervalSince(interval.start)
                
                if let batteryEnd = interval.batteryEnd {
                    let drain = Double(interval.batteryStart - batteryEnd)
                    sleepBatteryDrain += drain
                }
            }
        }
        
        let hours = Int(totalScreenSeconds / 3600)
        let minutes = Int((totalScreenSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        
        print("📊 parseLog: Calculated: \(hours)h \(minutes)m")
        
        // Calculate battery per hour for screen and sleep
        let screenHours = totalScreenSeconds / 3600
        let sleepHours = totalSleepSeconds / 3600
        
        let screenBatteryPerHour = screenHours > 0 ? totalBatteryDrain / screenHours : 0
        let sleepBatteryPerHour = sleepHours > 0 ? sleepBatteryDrain / sleepHours : 0
        
        return ScreenTimeData(
            hours: hours,
            minutes: minutes,
            screenBatteryPercent: screenBatteryPerHour,
            sleepBatteryPercent: sleepBatteryPerHour,
            lastChargeTime: chargeTime,
            lastChargeLevel: lastChargeLevel
        )
    }
    
    private func extractTimestamp(from line: String, formatter: DateFormatter) -> Date? {
        // Format: 2024-01-15 14:30:45 +0000
        let pattern = "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} [+-]\\d{4}"
        if let range = line.range(of: pattern, options: .regularExpression) {
            let dateString = String(line[range])
            return formatter.date(from: dateString)
        }
        return nil
    }
    
    private func extractBatteryLevel(from line: String) -> Int? {
        // Look for patterns like "Using Batt(Charge: 67)" or "Using BATT (Charge:67%)"
        let patterns = [
            "Charge:\\s*(\\d+)",
            "Charge: (\\d+)",
            "(\\d+)%"
        ]
        
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                let match = String(line[range])
                // Extract just the number
                if let number = match.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .compactMap({ Int($0) })
                    .first {
                    return number
                }
            }
        }
        return nil
    }
}

// MARK: - Widget View
struct ScreenTimeWidgetView: View {
    let entry: ScreenTimeEntry
    @Environment(\.widgetFamily) var widgetFamily
    
    var body: some View {
        ZStack {
            // Purple-black gradient background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.15, green: 0.10, blue: 0.25),
                    Color(red: 0.08, green: 0.05, blue: 0.15)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    Button(intent: RefreshIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
                
                Spacer()
                
                // Main time display
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(entry.data.hours)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("h")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("\(entry.data.minutes)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("m")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Battery usage
                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text("Screen")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Text(String(format: "%.1f%%/h", entry.data.screenBatteryPercent))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    
                    VStack(spacing: 2) {
                        Text("Sleep")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Text(String(format: "%.1f%%/h", entry.data.sleepBatteryPercent))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                
                // Last charge info
                VStack(spacing: 2) {
                    Text("Last charge")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(formatTime(entry.data.lastChargeTime)) · \(entry.data.lastChargeLevel)%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return "Today, " + formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday, " + formatter.string(from: date)
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Widget Configuration
struct ScreenTimeWidget: Widget {
    let kind: String = "ScreenTimeWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScreenTimeProvider()) { entry in
            ScreenTimeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Screen Time")
        .description("Shows hours of screen on time on battery since last charge")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
