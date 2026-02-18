import Foundation

// MARK: - Models matching backend schemas.py exactly

struct ExperimentSessionCreate: Codable {
    let subject_id: String?
    let body_site: String?
    let condition_label: String?
    let note: String?
    let start_time: String? // ISO8601
}

struct ExperimentSessionOut: Codable {
    let session_id: String
    let subject_id: String?
    let body_site: String?
    let condition_label: String?
    let note: String?
    let start_time: String?
    let end_time: String?
}

struct SensorReadingCreate: Codable {
    let session_id: String
    let time: String       // ISO8601
    let humidity: Double
    let temperature: Double
    let pressure: Double
}

struct SensorReadingBatchCreate: Codable {
    let readings: [SensorReadingCreate]
}

// MARK: - API Client

final class SensorAPIClient {

    static let shared = SensorAPIClient()

    private let baseURL = "http://ec2-18-222-252-75.us-east-2.compute.amazonaws.com"

    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Offline buffer for failed readings
    private var pendingReadings: [SensorReadingCreate] = []
    private let bufferQueue = DispatchQueue(label: "com.tewl.buffer", qos: .utility)

    private init() {}

    // MARK: - Session Management

    func createExperimentSession(
        subjectId: String?,
        bodySite: String?,
        conditionLabel: String?,
        note: String?,
        completion: @escaping (Result<ExperimentSessionOut, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/experiment-sessions") else {
            completion(.failure(APIError.invalidURL)); return
        }

        let nowISO = iso8601Formatter.string(from: Date())
        let payload = ExperimentSessionCreate(
            subject_id: subjectId,
            body_site: bodySite,
            condition_label: conditionLabel,
            note: note,
            start_time: nowISO
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        do {
            req.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error)); return
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else {
                completion(.failure(APIError.noData)); return
            }
            do {
                let session = try JSONDecoder().decode(ExperimentSessionOut.self, from: data)
                completion(.success(session))
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("[API] createSession decode error: \(error)\nBody: \(body)")
                completion(.failure(error))
            }
        }.resume()
    }

    func endExperimentSession(sessionId: String) {
        // Marks end_time by patching session — extend backend if needed.
        // For now, just logs locally.
        print("[API] Session \(sessionId) ended at \(iso8601Formatter.string(from: Date()))")
    }

    // MARK: - Sensor Reading Upload

    /// Primary upload path. Falls back to offline buffer on failure.
    func sendSensorReading(
        sessionId: String,
        tempC: Double,
        humPct: Double,
        presHpa: Double
    ) {
        let reading = SensorReadingCreate(
            session_id: sessionId,
            time: iso8601Formatter.string(from: Date()),
            humidity: humPct,
            temperature: tempC,
            pressure: presHpa
        )

        uploadReading(reading) { [weak self] success in
            guard let self = self else { return }
            if !success {
                // Buffer locally and retry on next successful upload
                self.bufferQueue.async {
                    self.pendingReadings.append(reading)
                    print("[API] Buffered reading. Buffer size: \(self.pendingReadings.count)")
                }
            } else {
                self.flushPendingReadings(sessionId: sessionId)
            }
        }
    }

    private func uploadReading(_ reading: SensorReadingCreate, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/sensor-readings") else {
            completion(false); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8

        do {
            req.httpBody = try JSONEncoder().encode(reading)
        } catch {
            print("[API] Encode error: \(error)")
            completion(false); return
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                print("[API] Upload failed: \(err.localizedDescription)")
                completion(false); return
            }
            if let http = resp as? HTTPURLResponse {
                print("[API] Status: \(http.statusCode)")
                completion(http.statusCode == 200 || http.statusCode == 201)
            } else {
                completion(false)
            }
        }.resume()
    }

    /// Flush buffered readings using batch endpoint
    private func flushPendingReadings(sessionId: String) {
        bufferQueue.async { [weak self] in
            guard let self = self, !self.pendingReadings.isEmpty else { return }

            let toFlush = self.pendingReadings
            self.pendingReadings.removeAll()

            guard let url = URL(string: "\(self.baseURL)/sensor-readings/batch") else { return }

            let batch = SensorReadingBatchCreate(readings: toFlush)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15

            guard let body = try? JSONEncoder().encode(batch) else { return }
            req.httpBody = body

            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    print("[API] Batch flush failed: \(err.localizedDescription)")
                    // Re-buffer on failure
                    self.bufferQueue.async { self.pendingReadings.append(contentsOf: toFlush) }
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    print("[API] Batch flush status: \(http.statusCode), count: \(toFlush.count)")
                }
            }.resume()
        }
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .noData:     return "No data received from server"
        }
    }
}

