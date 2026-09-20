import Foundation
import Darwin

/// A read-only Mach task port. No writes, injection or remote function execution.
public final class RemoteMemory {
    private let task: mach_port_t
    private var remainingBytes = 32 * 1024 * 1024
    public func beginRead() { remainingBytes = 32 * 1024 * 1024 }

    public init(pid: Int32) throws {
        var port: mach_port_t = 0
        let result = task_for_pid(mach_task_self_, pid, &port)
        guard result == KERN_SUCCESS else {
            throw ProbeError.unavailable("processAccessDenied: task_for_pid returned \(result)")
        }
        task = port
    }
    deinit { mach_port_deallocate(mach_task_self_, task) }

    public func data(at address: UInt64, count: Int) throws -> Data {
        guard address >= 4096, address < (1 << 48), count > 0, count <= 1024 * 1024,
              UInt64(count) <= UInt64.max - address, count <= remainingBytes else {
            throw ProbeError.invalid("Read exceeds address or diagnostic budget")
        }
        remainingBytes -= count
        var bytes = Data(count: count)
        var actual: mach_vm_size_t = 0
        let result = bytes.withUnsafeMutableBytes { buffer in
            mach_vm_read_overwrite(task, address, UInt64(count),
                                   UInt64(UInt(bitPattern: buffer.baseAddress!)), &actual)
        }
        guard result == KERN_SUCCESS, actual == count else {
            throw ProbeError.unavailable("memoryUnavailable: read failed (\(result))")
        }
        return bytes
    }
    public func uint(at address: UInt64, width: Int = 8) throws -> UInt64 {
        let value = try data(at: address, count: width).uint(0, width)
        // All 64-bit values used by this profile are pointers or array lengths;
        // reject tagged/corrupt values before callers perform address arithmetic.
        guard width != 8 || value < (1 << 48) else { throw ProbeError.invalid("Unsupported pointer or array length") }
        return value
    }
    public func string(at address: UInt64, limit: Int = 1024) throws -> String {
        guard address >= 4096, address < (1 << 48), limit > 0, limit <= 4096 else { throw ProbeError.invalid("Invalid string pointer") }
        var result = Data()
        while result.count < limit {
            let current = address + UInt64(result.count)
            let size = min(64, limit - result.count, 4096 - Int(current & 4095))
            let chunk = try data(at: current, count: size)
            if let end = chunk.firstIndex(of: 0) {
                result.append(chunk[..<end])
                guard let string = String(data: result, encoding: .utf8) else { throw ProbeError.invalid("Invalid UTF-8 metadata") }
                return string
            }
            result.append(chunk)
        }
        throw ProbeError.invalid("Metadata string exceeds limit")
    }

    public func monoModule() throws -> (address: UInt64, path: String) {
        var info = task_dyld_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_DYLD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ProbeError.unavailable("dyldInfoUnavailable: \(result)") }
        let header = try data(at: info.all_image_info_addr, count: 16)
        let imageCount = try header.uint(4, 4)
        let array = try header.uint(8, 8)
        guard imageCount > 0, imageCount <= 4096 else { throw ProbeError.invalid("Invalid dyld image count") }
        let images = try data(at: array, count: Int(imageCount) * 24)
        for index in 0..<Int(imageCount) {
            let pathAddress = try images.uint(index * 24 + 8, 8)
            let path = try string(at: pathAddress)
            if path.hasSuffix("/libmonobdwgc-2.0.dylib") {
                return (try images.uint(index * 24, 8), path)
            }
        }
        throw ProbeError.unavailable("monoNotLoaded")
    }
}
