import Foundation

struct SensorReadingWithTime: Codable {
    let temperature_c: Double
    let humidity_pct:  Double
    let pressure_hpa:  Double
}

func sendSensorReadingWithTime(tempC: Double, humPct: Double, presHpa: Double) {
    guard let url = URL(string: "http://ec2-18-222-252-75.us-east-2.compute.amazonaws.com/ingest/sensor") else {
        print("Invalid URL"); return
    }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    
    
    
     
    var enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601   // IMPORTANT so server can parse

    let payload = SensorReadingWithTime(temperature_c: tempC, humidity_pct: humPct, pressure_hpa: presHpa)
    do { req.httpBody = try enc.encode(payload) }
    catch { print("Failed to encode JSON:", error); return }

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { print("Request failed:", err); return }
        if let http = resp as? HTTPURLResponse { print("Status code:", http.statusCode) }
        if let data = data, let body = String(data: data, encoding: .utf8) { print("Response body:", body) }
    }.resume()
}

