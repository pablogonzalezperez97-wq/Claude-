import Foundation
import HealthKit

/// Cuerpo que espera la función healthkit-sync (mismas columnas que daily_metrics).
struct HealthPayload: Encodable {
    struct Day: Encodable { var date: String; var metrics: [String: Double] }
    struct Night: Encodable {
        var date: String
        var deepMin, remMin, coreMin, awakeMin, inBedMin, asleepMin: Double
        var sleepStart, sleepEnd: String?
        enum CodingKeys: String, CodingKey {
            case date, deepMin = "deep_min", remMin = "rem_min", coreMin = "core_min", awakeMin = "awake_min",
                 inBedMin = "in_bed_min", asleepMin = "asleep_min", sleepStart = "sleep_start", sleepEnd = "sleep_end"
        }
    }
    struct Workout: Encodable {
        var id: String; var start: String; var end: String; var name: String
        var durationMin: Double; var avgHr, maxHr, activeKcal, distanceKm, elevationM: Double?; var isIndoor: Bool?
        enum CodingKeys: String, CodingKey {
            case id, start, end, name, durationMin = "duration_min", avgHr = "avg_hr", maxHr = "max_hr",
                 activeKcal = "active_kcal", distanceKm = "distance_km", elevationM = "elevation_m", isIndoor = "is_indoor"
        }
    }
    var days: [Day]
    var sleep: [Night]
    var workouts: [Workout]
}

/// Lee HealthKit directamente y lo envía a Supabase. Sustituye a Health Auto Export.
actor HealthSync {
    static let shared = HealthSync()
    private let store = HKHealthStore()

    private enum Agg { case sum, avg }
    private struct Metric { let col: String; let id: HKQuantityTypeIdentifier; let unit: HKUnit; let agg: Agg; var scale = 1.0 }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let metrics: [Metric] = [
        .init(col: "hrv", id: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), agg: .avg),
        .init(col: "rhr", id: .restingHeartRate, unit: bpm, agg: .avg),
        .init(col: "walking_hr_avg", id: .walkingHeartRateAverage, unit: bpm, agg: .avg),
        .init(col: "cardio_recovery", id: .heartRateRecoveryOneMinute, unit: bpm, agg: .avg),
        .init(col: "respiratory_rate", id: .respiratoryRate, unit: bpm, agg: .avg),
        .init(col: "spo2", id: .oxygenSaturation, unit: .percent(), agg: .avg, scale: 100),
        .init(col: "vo2max", id: .vo2Max, unit: HKUnit(from: "ml/kg*min"), agg: .avg),
        .init(col: "weight_kg", id: .bodyMass, unit: .gramUnit(with: .kilo), agg: .avg),
        .init(col: "body_fat_pct", id: .bodyFatPercentage, unit: .percent(), agg: .avg, scale: 100),
        .init(col: "lean_mass_kg", id: .leanBodyMass, unit: .gramUnit(with: .kilo), agg: .avg),
        .init(col: "physical_effort", id: .physicalEffort, unit: HKUnit(from: "kcal/hr*kg"), agg: .avg),
        .init(col: "steps", id: .stepCount, unit: .count(), agg: .sum),
        .init(col: "active_kcal", id: .activeEnergyBurned, unit: .kilocalorie(), agg: .sum),
        .init(col: "basal_kcal", id: .basalEnergyBurned, unit: .kilocalorie(), agg: .sum),
        .init(col: "exercise_min", id: .appleExerciseTime, unit: .minute(), agg: .sum),
        .init(col: "distance_km", id: .distanceWalkingRunning, unit: .meterUnit(with: .kilo), agg: .sum),
        .init(col: "flights", id: .flightsClimbed, unit: .count(), agg: .sum),
        .init(col: "daylight_min", id: .timeInDaylight, unit: .minute(), agg: .sum),
        .init(col: "dietary_kcal", id: .dietaryEnergyConsumed, unit: .kilocalorie(), agg: .sum),
        .init(col: "protein_g", id: .dietaryProtein, unit: .gram(), agg: .sum),
        .init(col: "carbs_g", id: .dietaryCarbohydrates, unit: .gram(), agg: .sum),
        .init(col: "fat_g", id: .dietaryFatTotal, unit: .gram(), agg: .sum),
        .init(col: "water_ml", id: .dietaryWater, unit: .literUnit(with: .milli), agg: .sum),
        .init(col: "caffeine_mg", id: .dietaryCaffeine, unit: .gramUnit(with: .milli), agg: .sum),
    ]

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(Self.metrics.map { HKQuantityType($0.id) })
        s.insert(HKQuantityType(.heartRate))
        s.insert(HKQuantityType(.appleSleepingWristTemperature))
        s.insert(HKCategoryType(.sleepAnalysis))
        s.insert(HKObjectType.workoutType())
        return s
    }

    private let cal = Calendar.current
    private let dayFmt: DateFormatter = {
        let cal = Calendar.current
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private let iso = ISO8601DateFormatter()

    // MARK: Permisos y segundo plano

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// iOS despierta la app cuando hay datos nuevos de estos tipos.
    func enableBackgroundDelivery() async {
        let watched: [HKSampleType] = [
            HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(), HKQuantityType(.dietaryEnergyConsumed),
        ]
        for type in watched {
            try? await store.enableBackgroundDelivery(for: type, frequency: .hourly)
            let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await HealthSync.shared.syncAndUpload(days: 3)
                    completion()
                }
            }
            store.execute(q)
        }
    }

    // MARK: Sincronización

    @discardableResult
    func syncAndUpload(days: Int) async -> Bool {
        do {
            let payload = try await collect(days: days)
            try await Backend.shared.uploadHealth(payload)
            await Backend.shared.refreshToday()
            return true
        } catch {
            return false
        }
    }

    func collect(days: Int) async throws -> HealthPayload {
        let end = Date()
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: end)!)
        var byDay: [String: [String: Double]] = [:]

        for m in Self.metrics {
            let values = try await daily(m.id, unit: m.unit, agg: m.agg, from: start, to: end)
            for (day, v) in values { byDay[day, default: [:]][m.col] = v * m.scale }
        }
        for (day, hr) in try await heartRate(from: start, to: end) {
            byDay[day, default: [:]].merge(hr) { _, new in new }
        }
        for (day, t) in try await wristTemperature(from: start, to: end) {
            byDay[day, default: [:]]["wrist_temp_c"] = t
        }

        return HealthPayload(
            days: byDay.map { .init(date: $0.key, metrics: $0.value) }.sorted { $0.date < $1.date },
            sleep: try await nights(from: start.addingTimeInterval(-12 * 3600), to: end),
            workouts: try await workouts(from: start, to: end)
        )
    }

    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, agg: Agg, from: Date, to: Date) async throws -> [String: Double] {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        let q = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: agg == .sum ? .cumulativeSum : .discreteAverage,
            anchorDate: from, intervalComponents: DateComponents(day: 1))
        let coll = try await q.result(for: store)
        var out: [String: Double] = [:]
        coll.enumerateStatistics(from: from, to: to) { st, _ in
            let qty = agg == .sum ? st.sumQuantity() : st.averageQuantity()
            if let qty { out[self.dayFmt.string(from: st.startDate)] = qty.doubleValue(for: unit) }
        }
        return out
    }

    private func heartRate(from: Date, to: Date) async throws -> [String: [String: Double]] {
        let q = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: from, end: to)),
            options: [.discreteAverage, .discreteMin, .discreteMax],
            anchorDate: from, intervalComponents: DateComponents(day: 1))
        let coll = try await q.result(for: store)
        var out: [String: [String: Double]] = [:]
        coll.enumerateStatistics(from: from, to: to) { st, _ in
            var r: [String: Double] = [:]
            if let v = st.averageQuantity() { r["hr_avg"] = v.doubleValue(for: Self.bpm) }
            if let v = st.minimumQuantity() { r["hr_min"] = v.doubleValue(for: Self.bpm) }
            if let v = st.maximumQuantity() { r["hr_max"] = v.doubleValue(for: Self.bpm) }
            if !r.isEmpty { out[self.dayFmt.string(from: st.startDate)] = r }
        }
        return out
    }

    /// La temperatura nocturna se asigna al día en que te despiertas.
    private func wristTemperature(from: Date, to: Date) async throws -> [String: Double] {
        let q = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.appleSleepingWristTemperature),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: to))],
            sortDescriptors: [SortDescriptor(\.endDate)])
        var acc: [String: [Double]] = [:]
        for s in try await q.result(for: store) {
            acc[dayFmt.string(from: s.endDate), default: []].append(s.quantity.doubleValue(for: .degreeCelsius()))
        }
        return acc.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    /// Noches agrupadas por el día del despertar. Si hay varias fuentes (Watch y
    /// otra app), se queda la que más fases registra para no sumar dos veces.
    private func nights(from: Date, to: Date) async throws -> [HealthPayload.Night] {
        let q = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: from, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = try await q.result(for: store)

        struct Acc { var deep = 0.0, rem = 0.0, core = 0.0, awake = 0.0, inBed = 0.0, asleep = 0.0; var start: Date?; var end: Date? }
        var bySourceNight: [String: [String: Acc]] = [:]   // noche -> fuente -> acumulado
        for s in samples {
            let night = dayFmt.string(from: s.endDate)
            let src = s.sourceRevision.source.bundleIdentifier
            var a = bySourceNight[night]?[src] ?? Acc()
            let mins = s.endDate.timeIntervalSince(s.startDate) / 60
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .asleepDeep: a.deep += mins
            case .asleepREM: a.rem += mins
            case .asleepCore: a.core += mins
            case .asleepUnspecified: a.asleep += mins
            case .awake: a.awake += mins
            case .inBed: a.inBed += mins
            default: break
            }
            if s.value != HKCategoryValueSleepAnalysis.inBed.rawValue, s.value != HKCategoryValueSleepAnalysis.awake.rawValue {
                a.start = min(a.start ?? s.startDate, s.startDate)
                a.end = max(a.end ?? s.endDate, s.endDate)
            }
            bySourceNight[night, default: [:]][src] = a
        }
        return bySourceNight.compactMap { night, sources in
            guard let best = sources.values.max(by: { ($0.deep + $0.rem + $0.core + $0.asleep) < ($1.deep + $1.rem + $1.core + $1.asleep) }),
                  best.deep + best.rem + best.core + best.asleep > 60 else { return nil }   // ignora siestas sueltas
            return .init(date: night, deepMin: best.deep, remMin: best.rem, coreMin: best.core, awakeMin: best.awake,
                         inBedMin: best.inBed, asleepMin: best.asleep,
                         sleepStart: best.start.map(iso.string(from:)), sleepEnd: best.end.map(iso.string(from:)))
        }.sorted { $0.date < $1.date }
    }

    private func workouts(from: Date, to: Date) async throws -> [HealthPayload.Workout] {
        let q = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: to))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await q.result(for: store).map { w in
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            return .init(
                id: w.uuid.uuidString,
                start: iso.string(from: w.startDate), end: iso.string(from: w.endDate),
                name: w.workoutActivityType.spanishName,
                durationMin: w.duration / 60,
                avgHr: hr?.averageQuantity()?.doubleValue(for: Self.bpm),
                maxHr: hr?.maximumQuantity()?.doubleValue(for: Self.bpm),
                activeKcal: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                distanceKm: w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
                elevationM: (w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
                isIndoor: w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool)
        }
    }
}

extension HKWorkoutActivityType {
    /// Nombres que entiende la clasificación del servidor (carrera, fuerza, caminata, ciclismo).
    var spanishName: String {
        switch self {
        case .running: return "Carrera"
        case .walking: return "Caminata"
        case .hiking: return "Caminata (montaña)"
        case .cycling: return "Ciclismo"
        case .traditionalStrengthTraining: return "Fuerza tradicional"
        case .functionalStrengthTraining: return "Fuerza funcional"
        case .soccer: return "Fútbol"
        case .highIntensityIntervalTraining: return "HIIT"
        case .swimming: return "Natación"
        case .yoga: return "Yoga"
        case .coreTraining: return "Core"
        case .flexibility: return "Movilidad"
        default: return "Otro"
        }
    }
}
