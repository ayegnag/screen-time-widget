//
//  ScreenTimeWidget.swift
//  ScreenTimeWidget
//
//  Created by Gangeya Upadhyaya on 26/10/25.
//

//import WidgetKit
//import SwiftUI
//
//struct Provider: TimelineProvider {
//    func placeholder(in context: Context) -> SimpleEntry {
//        SimpleEntry(date: Date(), emoji: "😀")
//    }
//
//    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
//        let entry = SimpleEntry(date: Date(), emoji: "😀")
//        completion(entry)
//    }
//
//    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
//        var entries: [SimpleEntry] = []
//
//        // Generate a timeline consisting of five entries an hour apart, starting from the current date.
//        let currentDate = Date()
//        for hourOffset in 0 ..< 5 {
//            let entryDate = Calendar.current.date(byAdding: .hour, value: hourOffset, to: currentDate)!
//            let entry = SimpleEntry(date: entryDate, emoji: "😀")
//            entries.append(entry)
//        }
//
//        let timeline = Timeline(entries: entries, policy: .atEnd)
//        completion(timeline)
//    }
//
////    func relevances() async -> WidgetRelevances<Void> {
////        // Generate a list containing the contexts this widget is relevant in.
////    }
//}
//
//struct SimpleEntry: TimelineEntry {
//    let date: Date
//    let emoji: String
//}
//
//struct ScreenTimeWidgetEntryView : View {
//    var entry: Provider.Entry
//
//    var body: some View {
//        VStack {
//            HStack {
//                Text("Time:")
//                Text(entry.date, style: .time)
//            }
//
//            Text("Emoji:")
//            Text(entry.emoji)
//        }
//    }
//}
//
//struct ScreenTimeWidget: Widget {
//    let kind: String = "ScreenTimeWidget"
//
//    var body: some WidgetConfiguration {
//        StaticConfiguration(kind: kind, provider: Provider()) { entry in
//            if #available(macOS 14.0, *) {
//                ScreenTimeWidgetEntryView(entry: entry)
//                    .containerBackground(.fill.tertiary, for: .widget)
//            } else {
//                ScreenTimeWidgetEntryView(entry: entry)
//                    .padding()
//                    .background()
//            }
//        }
//        .configurationDisplayName("My Widget")
//        .description("This is an example widget.")
//    }
//}

import WidgetKit
import SwiftUI

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
        let parser = PMSetLogParser()
        return parser.parse()
    }
}

struct ScreenTimeEntry: TimelineEntry {
    let date: Date
    let data: ScreenTimeData
}

// MARK: - PMSet Log Parser
class PMSetLogParser {
    func parse() -> ScreenTimeData {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return parseLog(output)
            }
        } catch {
            print("Error running pmset: \(error)")
        }
        
        return ScreenTimeData(
            hours: 0,
            minutes: 0,
            screenBatteryPercent: 0,
            sleepBatteryPercent: 0,
            lastChargeTime: Date(),
            lastChargeLevel: 100
        )
    }
    
    private func parseLog(_ log: String) -> ScreenTimeData {
        let lines = log.components(separatedBy: .newlines)
        
        var lastChargeTime: Date?
        var lastChargeLevel = 100
        var screenOnIntervals: [(start: Date, end: Date?, batteryStart: Int, batteryEnd: Int?)] = []
        var sleepIntervals: [(start: Date, end: Date?, batteryStart: Int, batteryEnd: Int?)] = []
        var currentBatteryLevel = 100
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        
        for line in lines {
            // Parse timestamp and battery level
            if let timestamp = extractTimestamp(from: line, formatter: dateFormatter) {
                if let battery = extractBatteryLevel(from: line) {
                    currentBatteryLevel = battery
                }
                
                // Detect charge events
                if line.contains("Using AC") || line.contains("Connected to AC") {
                    lastChargeTime = timestamp
                    lastChargeLevel = currentBatteryLevel
                }
                
                // Detect display on/off
                if line.contains("Display is turned on") || line.contains("BacklightStateChange=1") {
                    screenOnIntervals.append((start: timestamp, end: nil, batteryStart: currentBatteryLevel, batteryEnd: nil))
                } else if line.contains("Display is turned off") || line.contains("BacklightStateChange=0") {
                    if var lastInterval = screenOnIntervals.last, lastInterval.end == nil {
                        screenOnIntervals[screenOnIntervals.count - 1].end = timestamp
                        screenOnIntervals[screenOnIntervals.count - 1].batteryEnd = currentBatteryLevel
                    }
                }
                
                // Detect sleep/wake
                if line.contains("Wake from") || line.contains("DarkWake") {
                    if var lastInterval = sleepIntervals.last, lastInterval.end == nil {
                        sleepIntervals[sleepIntervals.count - 1].end = timestamp
                        sleepIntervals[sleepIntervals.count - 1].batteryEnd = currentBatteryLevel
                    }
                } else if line.contains("Sleep") && !line.contains("Notification") {
                    sleepIntervals.append((start: timestamp, end: nil, batteryStart: currentBatteryLevel, batteryEnd: nil))
                }
            }
        }
        
        // Calculate totals since last charge
        let chargeTime = lastChargeTime ?? Date().addingTimeInterval(-86400)
        
        var totalScreenSeconds = 0.0
        var screenBatteryDrain = 0.0
        var screenEventCount = 0
        
        for interval in screenOnIntervals {
            if interval.start > chargeTime {
                let end = interval.end ?? Date()
                totalScreenSeconds += end.timeIntervalSince(interval.start)
                
                if let batteryEnd = interval.batteryEnd {
                    screenBatteryDrain += Double(interval.batteryStart - batteryEnd)
                    screenEventCount += 1
                }
            }
        }
        
        var totalSleepSeconds = 0.0
        var sleepBatteryDrain = 0.0
        var sleepEventCount = 0
        
        for interval in sleepIntervals {
            if interval.start > chargeTime {
                let end = interval.end ?? Date()
                totalSleepSeconds += end.timeIntervalSince(interval.start)
                
                if let batteryEnd = interval.batteryEnd {
                    sleepBatteryDrain += Double(interval.batteryStart - batteryEnd)
                    sleepEventCount += 1
                }
            }
        }
        
        let hours = Int(totalScreenSeconds / 3600)
        let minutes = Int((totalScreenSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        
        let avgScreenDrain = screenEventCount > 0 ? screenBatteryDrain / Double(screenEventCount) : 0
        let avgSleepDrain = sleepEventCount > 0 ? sleepBatteryDrain / Double(sleepEventCount) : 0
        
        return ScreenTimeData(
            hours: hours,
            minutes: minutes,
            screenBatteryPercent: avgScreenDrain,
            sleepBatteryPercent: avgSleepDrain,
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
        // Look for patterns like "Battery at 85%"
        let pattern = "(\\d+)%"
        if let range = line.range(of: pattern, options: .regularExpression) {
            let match = String(line[range])
            return Int(match.dropLast())
        }
        return nil
    }
}

// MARK: - Widget View
struct ScreenTimeWidgetView: View {
    let entry: ScreenTimeEntry
    
    var body: some View {
        VStack(spacing: 8) {
            // Main time display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.data.hours)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("h")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text("\(entry.data.minutes)")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("m")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            // Battery usage
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("Screen")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f%%", entry.data.screenBatteryPercent))
                        .font(.system(size: 12, weight: .semibold))
                }
                
                VStack(spacing: 2) {
                    Text("Sleep")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f%%", entry.data.sleepBatteryPercent))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            
            // Last charge info
            VStack(spacing: 2) {
                Text("Last charge")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\(formatTime(entry.data.lastChargeTime)) · \(entry.data.lastChargeLevel)%")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding()
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Widget Configuration
struct ScreenTimeWidget: Widget {
    let kind: String = "ScreenTimeWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScreenTimeProvider()) { entry in
            ScreenTimeWidgetView(entry: entry)
        }
        .configurationDisplayName("Screen Time")
        .description("Shows hours of screen on time on battery since last charge")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
