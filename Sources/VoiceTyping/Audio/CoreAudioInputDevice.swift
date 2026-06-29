import CoreAudio
import Foundation

enum CoreAudioInputDevice {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
        let inputChannels: UInt32

        var hasInput: Bool { inputChannels > 0 }
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    static func preferredBuiltInInput(devices: [Device]) -> Device? {
        devices.first { $0.hasInput && $0.isBuiltIn }
    }

    static func preferredBuiltInInput() -> Device? {
        preferredBuiltInInput(devices: allInputDevices())
    }

    static func nominalSampleRate(for id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &sampleRate)
        return status == noErr && sampleRate > 0 ? sampleRate : nil
    }

    private static func allInputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        )
        guard status == noErr else { return [] }
        return ids.compactMap(deviceInfo)
    }

    private static func deviceInfo(id: AudioDeviceID) -> Device? {
        let channels = inputChannelCount(for: id)
        guard channels > 0 else { return nil }
        return Device(
            id: id,
            name: deviceName(for: id) ?? "AudioDevice-\(id)",
            transport: transportType(for: id),
            inputChannels: channels
        )
    }

    private static func inputChannelCount(for id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(list)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private static func transportType(for id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(kAudioDeviceTransportTypeUnknown)
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }

    private static func deviceName(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}
