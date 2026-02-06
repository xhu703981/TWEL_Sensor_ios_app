//
//  UI.swift
//  nRFapp
//
//  Created by heartbrokenboy on 9/17/25.
//

import SwiftUI


struct ContentView: View {
    @StateObject var ble = BLEManager()
    @State private var outbound = ""

    var body: some View {
        VStack {
            HStack {
                Text(ble.isSwitchedOn ? "Bluetooth ON" : "Bluetooth OFF")
                Spacer()
                if ble.isConnected {
                    Button("Disconnect") { ble.disconnect() }
                } else {
                    Button("Scan") { ble.startScanning() }
                }
            }.padding()

            List(ble.peripherals) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name).font(.headline)
                        Text("RSSI: \(p.rssi)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Connect") { ble.connectPeripheral(p.peripheral) }
                }
            }

            HStack {
                TextField("Type text…", text: $outbound)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    ble.send(text: outbound)
                    outbound = ""
                }.disabled(!ble.isConnected)
            }.padding()

            List(ble.logLines.suffix(50), id: \.self) { line in
                Text(line).font(.caption.monospaced())
            }
        }
    }
}
