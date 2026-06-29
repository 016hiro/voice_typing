import AVFoundation
import XCTest
@testable import VoiceTyping

final class AudioCaptureTests: XCTestCase {
    func testPrepareSessionStoresInputFormatForHALCallback() throws {
        let capture = AudioCapture()
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 48_000,
                                        channels: 2,
                                        interleaved: false)!
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))

        _ = capture.prepareSession(inputFormat: inputFormat, converter: converter, maxDuration: 1)

        XCTAssertEqual(capture.preparedInputFormatSampleRate, 48_000)
        XCTAssertTrue(capture.stop().samples.isEmpty)
    }

    func testMakeRenderBufferPreparesWritableAudioBufferList() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000,
                                   channels: 2,
                                   interleaved: false)!

        let buffer = try XCTUnwrap(AudioCapture.makeRenderBuffer(format: format, numberFrames: 512))
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        XCTAssertEqual(buffer.frameLength, 512)
        XCTAssertEqual(buffers.count, 2)
        XCTAssertEqual(buffers[0].mDataByteSize, 512 * UInt32(MemoryLayout<Float>.size))
        XCTAssertEqual(buffers[1].mDataByteSize, 512 * UInt32(MemoryLayout<Float>.size))
    }
}
