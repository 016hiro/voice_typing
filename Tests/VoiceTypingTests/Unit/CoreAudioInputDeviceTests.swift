import CoreAudio
import XCTest
@testable import VoiceTyping

final class CoreAudioInputDeviceTests: XCTestCase {
    func testPreferredBuiltInInput_IgnoresBluetoothDefaultShape() {
        let devices = [
            device(1, transport: kAudioDeviceTransportTypeBluetooth),
            device(2, transport: kAudioDeviceTransportTypeBuiltIn)
        ]

        XCTAssertEqual(CoreAudioInputDevice.preferredBuiltInInput(devices: devices)?.id, 2)
    }

    func testPreferredBuiltInInput_IgnoresOutputOnlyBuiltInDevice() {
        let devices = [
            device(1, transport: kAudioDeviceTransportTypeBluetooth),
            device(2, transport: kAudioDeviceTransportTypeBuiltIn, inputChannels: 0)
        ]

        XCTAssertNil(CoreAudioInputDevice.preferredBuiltInInput(devices: devices))
    }

    func testPreferredBuiltInInput_ReturnsNilWhenNoBuiltInInputExists() {
        let devices = [
            device(1, transport: kAudioDeviceTransportTypeBluetooth),
            device(2, transport: kAudioDeviceTransportTypeUSB)
        ]

        XCTAssertNil(CoreAudioInputDevice.preferredBuiltInInput(devices: devices))
    }

    private func device(_ id: AudioDeviceID,
                        transport: UInt32,
                        inputChannels: UInt32 = 1) -> CoreAudioInputDevice.Device {
        CoreAudioInputDevice.Device(
            id: id,
            name: "device-\(id)",
            transport: transport,
            inputChannels: inputChannels
        )
    }
}
