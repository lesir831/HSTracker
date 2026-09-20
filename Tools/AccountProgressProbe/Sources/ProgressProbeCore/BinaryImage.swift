import Foundation

public enum ProbeError: Error, CustomStringConvertible {
    case invalid(String)
    case unavailable(String)
    public var description: String {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        }
    }
}

extension Data {
    func uint(_ offset: Int, _ width: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ProbeError.invalid("Truncated binary data")
        }
        let bytes = self[offset..<(offset + width)]
        return (bigEndian ? Array(bytes) : Array(bytes.reversed())).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    func cString(_ offset: Int, limit: Int) throws -> String {
        guard offset >= 0, offset < count, limit > 0 else { throw ProbeError.invalid("Invalid string range") }
        let end = offset + Swift.min(limit, count - offset)
        guard let nul = self[offset..<end].firstIndex(of: 0),
              let string = String(data: self[offset..<nul], encoding: .utf8) else {
            throw ProbeError.invalid("Unterminated or invalid metadata string")
        }
        return string
    }
}

/// Reads the actual Mach-O slice rather than assuming a universal image is a thin x86 binary.
public struct BinaryImage {
    public static let arm64: UInt32 = 0x0100000c
    public static let x86_64: UInt32 = 0x01000007
    let bytes: Data
    public let cpu: UInt32
    public let uuid: String
    public let rootDomainOffset: UInt64

    public init(data: Data, cpu: UInt32) throws {
        let magic = try data.uint(0, 4, bigEndian: true)
        var slice = data
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(try data.uint(4, 4, bigEndian: true))
            guard count > 0, count <= 32 else { throw ProbeError.invalid("Invalid architecture count") }
            let stride = magic == 0xcafebabf ? 32 : 20
            var selected: Data?
            for index in 0..<count {
                let base = 8 + stride * index
                if try data.uint(base, 4, bigEndian: true) == cpu {
                    let width = stride == 32 ? 8 : 4
                    let offset = try data.uint(base + 8, width, bigEndian: true)
                    let size = try data.uint(base + 8 + width, width, bigEndian: true)
                    guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset else {
                        throw ProbeError.invalid("Architecture slice exceeds file")
                    }
                    selected = Data(data[Int(offset)..<Int(offset + size)])
                }
            }
            guard let selected else { throw ProbeError.unavailable("Requested architecture is absent") }
            slice = selected
        }
        guard try slice.uint(0, 4) == 0xfeedfacf, try slice.uint(4, 4) == cpu else {
            throw ProbeError.invalid("Unsupported Mach-O architecture or format")
        }
        let count = Int(try slice.uint(16, 4))
        let commandBytes = Int(try slice.uint(20, 4))
        guard commandBytes <= slice.count - 32, count <= commandBytes / 8 else {
            throw ProbeError.invalid("Invalid Mach-O load commands")
        }
        var offset = 32
        var symbolTable: (Int, Int, Int, Int)?
        var imageUUID: String?
        var textBase: UInt64?
        for _ in 0..<count {
            let kind = try slice.uint(offset, 4)
            let size = Int(try slice.uint(offset + 4, 4))
            guard size >= 8, size <= 32 + commandBytes - offset else {
                throw ProbeError.invalid("Invalid Mach-O command size")
            }
            if kind == 2 { // LC_SYMTAB
                guard size >= 24 else { throw ProbeError.invalid("Truncated symbol table command") }
                symbolTable = (Int(try slice.uint(offset + 8, 4)), Int(try slice.uint(offset + 12, 4)),
                               Int(try slice.uint(offset + 16, 4)), Int(try slice.uint(offset + 20, 4)))
            } else if kind == 0x1b { // LC_UUID
                guard size >= 24 else { throw ProbeError.invalid("Truncated UUID command") }
                imageUUID = slice[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            } else if kind == 0x19 { // LC_SEGMENT_64
                guard size >= 72 else { throw ProbeError.invalid("Truncated segment command") }
                if try slice.cString(offset + 8, limit: 16) == "__TEXT" {
                    textBase = try slice.uint(offset + 24, 8)
                }
            }
            offset += size
        }
        guard let (symbols, number, strings, stringSize) = symbolTable, let imageUUID, let textBase,
              symbols <= slice.count, number <= (slice.count - symbols) / 16,
              strings <= slice.count, stringSize <= slice.count - strings else {
            throw ProbeError.invalid("Missing or invalid Mach-O tables")
        }
        var root: UInt64?
        for index in 0..<number {
            let entry = symbols + index * 16
            let nameOffset = Int(try slice.uint(entry, 4))
            guard nameOffset < stringSize else { throw ProbeError.invalid("Invalid symbol name offset") }
            if try slice.cString(strings + nameOffset, limit: stringSize - nameOffset) == "_mono_get_root_domain" {
                let value = try slice.uint(entry + 8, 8)
                guard value >= textBase, value - textBase < (1 << 32) else { throw ProbeError.invalid("Invalid root-domain symbol") }
                root = value - textBase
            }
        }
        guard let root else { throw ProbeError.unavailable("Mono root-domain symbol is absent") }
        self.bytes = slice
        self.cpu = cpu
        self.uuid = imageUUID
        self.rootDomainOffset = root
    }

    /// Decode only the known ADRP/LDR/RET sequence; never guess after a runtime update.
    public static func rootPointerAddress(instructions: Data, pc: UInt64) throws -> UInt64 {
        let adrp = UInt32(try instructions.uint(0, 4))
        let ldr = UInt32(try instructions.uint(4, 4))
        let ret = UInt32(try instructions.uint(8, 4))
        guard adrp & 0x9f000000 == 0x90000000,
              ldr & 0xffc0001f == 0xf9400000,
              (ldr >> 5) & 31 == adrp & 31,
              ret == 0xd65f03c0 else {
            throw ProbeError.unavailable("Unsupported ARM64 root-domain instruction sequence")
        }
        let immediate = Int64(((adrp >> 5) & 0x7ffff) << 2 | ((adrp >> 29) & 3))
        let signed = immediate & 0x100000 == 0 ? immediate : immediate - 0x200000
        let page = pc & ~UInt64(0xfff)
        guard page < (1 << 48) else { throw ProbeError.invalid("Invalid program counter") }
        let result = Int64(page) + signed * 4096 + Int64((ldr >> 10) & 0xfff) * 8
        guard result > 0 else { throw ProbeError.invalid("Invalid root-domain address") }
        return UInt64(result)
    }
}
