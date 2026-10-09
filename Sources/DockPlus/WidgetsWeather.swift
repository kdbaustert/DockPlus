import Foundation

// MARK: - Weather (Open-Meteo: keyless, and fine with a request every 15 minutes)

extension WidgetsModel {
    func configureWeather() {
        weatherTimer?.invalidate()
        weatherTimer = nil
        weatherTask?.cancel()
        weatherRetry?.cancel()
        weatherRetry = nil
        guard settings.showsWeather, widgetsOnBar, !settings.weatherLocation.isEmpty else {
            // All of the reading: the temperature alone left the old city and its high and low.
            weatherTemperature = nil
            weatherPlace = ""
            weatherHighLow = ""
            weatherSymbol = "cloud.fill"
            weatherReadingKey = nil
            return
        }
        // Paused: nothing is fetched or timed now, and `resumeWeather` catches up on waking.
        guard !isPaused else { return }
        refreshWeather()
        armWeatherTimer()
    }

    private func armWeatherTimer() {
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWeather() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        weatherTimer = timer
    }

    func pauseWeather() {
        weatherTimer?.invalidate()
        weatherTimer = nil
        weatherRetry?.cancel()
        weatherRetry = nil
    }

    /// A reading under 15 minutes old for the same place and unit stands, with the timer started
    /// again; anything else, including a setting changed while paused, is fetched now.
    func resumeWeather() {
        guard settings.showsWeather, widgetsOnBar, !settings.weatherLocation.isEmpty else { return }
        let age = weatherFetchedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        guard weatherReadingKey == weatherKey, age < 15 * 60 else { return configureWeather() }
        weatherTimer?.invalidate()
        armWeatherTimer()
    }

    /// Everything a reading depends on, as one string to compare fetches and the shown reading by.
    private var weatherKey: String {
        "\(settings.weatherLocation)|\(settings.weatherFahrenheit)"
            + "|\(settings.weatherLatitude),\(settings.weatherLongitude)"
    }

    private func refreshWeather(isRetry: Bool = false) {
        let place = settings.weatherLocation
        let fahrenheit = settings.weatherFahrenheit
        let key = weatherKey
        // Coordinates picked from the city search win over geocoding the typed name: the search
        // already disambiguated ("Springfield" names dozens of places).
        let pinned: Located? = settings.weatherLatitude != 0 || settings.weatherLongitude != 0
            ? Located(name: place, latitude: settings.weatherLatitude, longitude: settings.weatherLongitude)
            : nil
        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            // Not `??`: its right side is an autoclosure, which cannot await.
            let located: Located?
            var mayRetry = !isRetry
            if let pinned {
                located = pinned
            } else {
                switch await Self.geocode(place) {
                case .located(let found): located = found
                case .failed: located = nil
                case .noMatch:
                    // A definitive answer, which a minute would not change; the quarter-hour cycle
                    // still re-asks, so a geocoder hiccup misread as no match rights itself.
                    located = nil
                    mayRetry = false
                }
            }
            var current: Current?
            if let located {
                current = await Self.forecast(
                    latitude: located.latitude, longitude: located.longitude, fahrenheit: fahrenheit)
            }
            // A cancelled fetch was superseded or switched off; it neither shows nor retries.
            guard let self, !Task.isCancelled else { return }
            guard let located, let current else { return weatherFailed(for: key, mayRetry: mayRetry) }
            weatherReadingKey = key
            weatherFetchedAt = .now
            weatherSuccesses += 1
            weatherPlace = Self.abbreviatingState(located.name)
            weatherTemperature = "\(Int(current.temperature.rounded()))°"
            weatherHighLow = "↑\(Int(current.high.rounded())) ↓\(Int(current.low.rounded()))"
            weatherSymbol = Self.symbol(for: current.code, isDay: current.isDay)
        }
    }

    /// A reading for another key — place, unit or coordinates — is wrong, not stale, so it goes,
    /// icon included; "--°" is honest. Then one retry a minute on: a transient failure at launch, or right after
    /// a wake before the network is back, otherwise leaves the tile a whole cycle. Once: the retry
    /// itself schedules none (`isRetry`), so a network that stays down is left to the quarter-hour
    /// timer instead of a request a minute all day. It fires only if
    /// nothing has changed or succeeded since — gated on the success count, not on an empty tile:
    /// a kept stale reading is exactly the case that must still retry. Not for a place the geocoder
    /// knows no match for (`mayRetry: false`) — retrying a typo every minute hammered the geocoder
    /// forever.
    private func weatherFailed(for key: String, mayRetry: Bool) {
        if weatherReadingKey != key {
            weatherReadingKey = nil
            weatherTemperature = nil
            weatherPlace = ""
            weatherHighLow = ""
            weatherSymbol = "cloud.fill"
        }
        weatherRetry?.cancel()
        guard mayRetry else {
            weatherRetry = nil
            return
        }
        let successesAtFailure = weatherSuccesses
        weatherRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, settings.showsWeather, weatherKey == key, weatherSuccesses == successesAtFailure
            else { return }
            weatherRetry = nil
            refreshWeather(isRetry: true)
        }
    }

    private struct Located: Sendable { let name: String; let latitude: Double; let longitude: Double }

    /// One city-search hit, ready for a results list.
    struct City: Identifiable, Sendable {
        let name: String
        let region: String
        let country: String
        let latitude: Double
        let longitude: Double
        var id: String { "\(latitude),\(longitude)" }
        var label: String {
            [name, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        /// City and state — what the dock shows. The country only helps tell hits apart in the list.
        var placeName: String { Self.placeName(name, region: region, country: country) }

        nonisolated static func placeName(_ name: String, region: String, country: String) -> String {
            [name, region.isEmpty ? country : region].filter { !$0.isEmpty }.joined(separator: ", ")
        }

        /// One geocoder result. A hit without a name takes `fallbackName` when there is one; without
        /// either, or without coordinates, it is no place at all.
        nonisolated init?(hit: [String: Any], fallbackName: String? = nil) {
            guard let name = hit["name"] as? String ?? fallbackName,
                  let latitude = hit["latitude"] as? Double,
                  let longitude = hit["longitude"] as? Double
            else { return nil }
            self.name = name
            self.region = hit["admin1"] as? String ?? ""
            self.country = hit["country"] as? String ?? ""
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The geocoder's best matches for a partial name — what the Settings search list shows.
    nonisolated static func searchCities(_ query: String) async -> [City] {
        (await geocoderResults(query, count: 6) ?? []).compactMap { City(hit: $0) }
    }

    private struct Current: Sendable {
        let temperature: Double
        let high: Double
        let low: Double
        /// nil when the reading carries none, which is unknown rather than a clear sky.
        let code: Int?
        let isDay: Bool
    }

    /// `noMatch` and `failed` apart, because they retry differently: a name the geocoder does not
    /// know stays unknown a minute later, while a request that never got through may well get through.
    private enum Geocoded { case located(Located), noMatch, failed }

    private nonisolated static func geocode(_ place: String) async -> Geocoded {
        guard let hits = await geocoderResults(place, count: 1) else { return .failed }
        guard let city = hits.first.flatMap({ City(hit: $0, fallbackName: place) }) else { return .noMatch }
        return .located(Located(name: city.placeName, latitude: city.latitude, longitude: city.longitude))
    }

    /// The raw hits for a name — the request both the search list and the typed-name geocode make,
    /// differing only in how many they want. nil when the request or its parse failed; [] when the
    /// geocoder answered and knows no such place (it omits "results" then, and reports its own
    /// errors under "error").
    private nonisolated static func geocoderResults(_ name: String, count: Int) async -> [[String: Any]]? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: name), .init(name: "count", value: String(count))]
        guard let json = await openMeteoJSON(parts.url!, for: "the city search") else { return nil }
        return json["results"] as? [[String: Any]] ?? []
    }

    /// One Open-Meteo request, parsed. Every way it can fail is logged with its reason: the tile
    /// shows "--°" for all of them, so the log is the only place they differ. A cancelled request
    /// is a superseded one, not a failure, and stays quiet.
    private nonisolated static func openMeteoJSON(_ url: URL, for what: String) async -> [String: Any]? {
        let data: Data
        do {
            data = try await URLSession.shared.data(from: url).0
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                NSLog("DockPlus: \(what) failed: \(error.localizedDescription)")
            }
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("DockPlus: \(what) answered with something that is not a JSON object")
            return nil
        }
        if json["error"] as? Bool == true {
            NSLog("DockPlus: \(what) was refused: \(json["reason"] as? String ?? "no reason given")")
            return nil
        }
        return json
    }

    private nonisolated static func forecast(latitude: Double, longitude: Double, fahrenheit: Bool) async -> Current? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let json = await openMeteoJSON(parts.url!, for: "the forecast") else { return nil }
        guard let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double
        else {
            NSLog("DockPlus: the forecast has no current temperature")
            return nil
        }
        guard let daily = json["daily"] as? [String: Any],
              let high = (daily["temperature_2m_max"] as? [Double])?.first,
              let low = (daily["temperature_2m_min"] as? [Double])?.first
        else {
            NSLog("DockPlus: the forecast has no high and low for today (daily arrays missing or null)")
            return nil
        }
        return Current(temperature: temperature, high: high, low: low,
                       code: current["weather_code"] as? Int, isDay: current["is_day"] as? Int != 0)
    }

    /// WMO weather codes, coarsely. Open-Meteo's `is_day` swaps the sun for the moon on the
    /// clear and partly cloudy codes; a missing code is unknown, not a clear sky.
    nonisolated static func symbol(for code: Int?, isDay: Bool = true) -> String {
        guard let code else { return "cloud.fill" }
        return switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// The tile's place with a trailing US state as its postal code: "Cincinnati, Ohio" reads
    /// "Cincinnati, OH". Only on the tile — the setting and the Settings field keep the full name.
    ///
    /// Done to the finished string because a pinned place is only a string by the time it gets
    /// here: the setting stores `placeName`, not the geocoder's fields. Everywhere else is left as
    /// written: Open-Meteo returns no short form for any region (checked: `admin1` is "Ontario" for
    /// Toronto, with only a numeric `admin1_id` beside it), so there is nothing to shorten to. The
    /// one name that is both a state and a country is Georgia, and `placeName` shows a country only
    /// when the hit had no region — Georgian towns checked (Batumi, Kutaisi) all carry one.
    nonisolated static func abbreviatingState(_ place: String) -> String {
        guard let comma = place.range(of: ", ", options: .backwards),
              let code = usStateCodes[String(place[comma.upperBound...])]
        else { return place }
        return String(place[..<comma.upperBound]) + code
    }

    private nonisolated static let usStateCodes = [
        "Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA",
        "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "District of Columbia": "DC",
        "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID", "Illinois": "IL", "Indiana": "IN",
        "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA", "Maine": "ME", "Maryland": "MD",
        "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN", "Mississippi": "MS", "Missouri": "MO",
        "Montana": "MT", "Nebraska": "NE", "Nevada": "NV", "New Hampshire": "NH", "New Jersey": "NJ",
        "New Mexico": "NM", "New York": "NY", "North Carolina": "NC", "North Dakota": "ND", "Ohio": "OH",
        "Oklahoma": "OK", "Oregon": "OR", "Pennsylvania": "PA", "Rhode Island": "RI",
        "South Carolina": "SC", "South Dakota": "SD", "Tennessee": "TN", "Texas": "TX", "Utah": "UT",
        "Vermont": "VT", "Virginia": "VA", "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI",
        "Wyoming": "WY",
    ]
}
