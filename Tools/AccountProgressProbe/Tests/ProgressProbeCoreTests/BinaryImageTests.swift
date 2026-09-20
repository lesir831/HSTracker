import Foundation
import XCTest
@testable import ProgressProbeCore

final class BinaryImageTests: XCTestCase {
    func testCurrentARM64RootSequence() throws {
        let instructions = Data([0x88, 0x0f, 0x00, 0xd0, 0x00, 0x41, 0x47, 0xf9, 0xc0, 0x03, 0x5f, 0xd6])
        XCTAssertEqual(try BinaryImage.rootPointerAddress(instructions: instructions, pc: 0x11853c), 0x30ae80)
    }

    func testNegativePageDisplacement() throws {
        // adrp x8, previous page; ldr x0, [x8]; ret
        let instructions = Data([0xe8, 0xff, 0xff, 0xf0, 0x00, 0x01, 0x40, 0xf9, 0xc0, 0x03, 0x5f, 0xd6])
        XCTAssertEqual(try BinaryImage.rootPointerAddress(instructions: instructions, pc: 0x3000), 0x2000)
    }

    func testRejectChangedInstructionOrRegister() {
        for bytes: [UInt8] in [
            [0, 0, 0, 0],
            [0x88, 0x0f, 0x00, 0xd0, 0x20, 0x41, 0x47, 0xf9, 0xc0, 0x03, 0x5f, 0xd6]
        ] {
            XCTAssertThrowsError(try BinaryImage.rootPointerAddress(instructions: Data(bytes), pc: 0x11853c))
        }
    }

    func testRejectInvalidImages() {
        for bytes in [Data(), Data(repeating: 0, count: 32), Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0xff, 0xff])] {
            XCTAssertThrowsError(try BinaryImage(data: bytes, cpu: BinaryImage.arm64))
        }
    }

    func testRejectOutOfBoundsReads() {
        let bytes = Data([0, 1, 2, 3])
        XCTAssertThrowsError(try bytes.uint(-1, 4))
        XCTAssertThrowsError(try bytes.uint(2, 4))
        XCTAssertThrowsError(try bytes.uint(Int.max, 4))
        XCTAssertThrowsError(try bytes.cString(1, limit: 3))
    }
    // Minimal real Mach-O structure, with deliberately different offsets for the
    // symbol table, string table, and virtual address, catches file/VM confusion.
    private func thinImage() -> Data {
        var bytes = Data(repeating: 0, count: 240)
        func put(_ offset: Int, _ value: UInt64, _ width: Int = 4) {
            for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        put(0, 0xfeedfacf); put(4, UInt64(BinaryImage.arm64))
        put(16, 3); put(20, 120)
        put(32, 0x19); put(36, 72)
        bytes.replaceSubrange(40..<46, with: Array("__TEXT".utf8))
        put(56, 0x100000000, 8)
        put(104, 0x1b); put(108, 24)
        bytes.replaceSubrange(112..<128, with: Array(UInt8(0)...UInt8(15)))
        put(128, 2); put(132, 24); put(136, 160); put(140, 1)
        put(144, 192); put(148, 48)
        put(160, 1); put(168, 0x100001234, 8)
        let name = Array("_mono_get_root_domain".utf8) + [0]
        bytes.replaceSubrange(193..<(193 + name.count), with: name)
        return bytes
    }

    func testThinAndUniversalImagesSelectARM64Slice() throws {
        let thin = thinImage()
        let parsed = try BinaryImage(data: thin, cpu: BinaryImage.arm64)
        XCTAssertEqual(parsed.rootDomainOffset, 0x1234)
        XCTAssertEqual(parsed.uuid, "000102030405060708090a0b0c0d0e0f")
        for fat64 in [false, true] {
            var fat = Data(repeating: 0, count: 64)
            func put(_ offset: Int, _ value: UInt64, _ width: Int = 4) {
                for index in 0..<width { fat[offset + index] = UInt8(truncatingIfNeeded: value >> ((width - index - 1) * 8)) }
            }
            put(0, fat64 ? 0xcafebabf : 0xcafebabe); put(4, 1)
            put(8, UInt64(BinaryImage.arm64)); put(16, 64, fat64 ? 8 : 4)
            put(fat64 ? 24 : 20, UInt64(thin.count), fat64 ? 8 : 4)
            fat.append(thin)
            XCTAssertEqual(try BinaryImage(data: fat, cpu: BinaryImage.arm64).rootDomainOffset, 0x1234)
            XCTAssertThrowsError(try BinaryImage(data: fat, cpu: BinaryImage.x86_64))
            fat[16] = 0xff
            XCTAssertThrowsError(try BinaryImage(data: fat, cpu: BinaryImage.arm64))
        }
    }

    func testRejectCorruptCommandAndSymbolBounds() {
        for offset in [36, 136, 144, 160] {
            var data = thinImage()
            data.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try BinaryImage(data: data, cpu: BinaryImage.arm64))
        }
        let instructions = Data([0x88, 0x0f, 0x00, 0xd0, 0x00, 0x41, 0x47, 0xf9, 0xc0, 0x03, 0x5f, 0xd6])
        XCTAssertThrowsError(try BinaryImage.rootPointerAddress(instructions: instructions, pc: UInt64(Int64.max)))
    }

}
