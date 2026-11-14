import Darwin
import Foundation

/// The main thread's call stack, sampled from another thread while the main
/// thread is stuck.
///
/// `MainThreadHangMonitor` could say that the main thread stalled and for how
/// long, never where: `Thread.callStackSymbols` only describes the calling
/// thread. This suspends the main thread for a few microseconds, reads its
/// registers and walks the frame-pointer chain, then resumes it.
///
/// Rules while the main thread is suspended: no allocation, no locks, no
/// Objective-C or Swift runtime calls — the main thread may hold the malloc or
/// dyld lock, and waiting on it here would deadlock the whole app. The frame
/// buffer is allocated up front, memory is read with `vm_read_overwrite` (a
/// Mach trap, and safe on a bad pointer), and symbol lookup (`dladdr`) happens
/// only after `thread_resume`.
enum MainThreadBacktrace {
    private static var mainThread: thread_t = 0
    private static let capacity = 64
    private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)

    /// Call once, on the main thread.
    static func registerMainThread() {
        if mainThread == 0 { mainThread = mach_thread_self() }
    }

    /// Frames as "Image 0xoffset symbol", innermost first. Empty when the
    /// stack can't be read (not registered, or not an arm64 device).
    static func capture() -> [String] {
        #if arch(arm64)
        let thread = mainThread
        guard thread != 0, thread != mach_thread_self() else { return [] }
        var count = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { ptr in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if kr == KERN_SUCCESS {
            frames[0] = UInt(state.__pc)
            frames[1] = UInt(state.__lr)
            count = 2
            var fp = vm_address_t(state.__fp)
            // Each frame record is { previous fp, return address }.
            var record: (UInt, UInt) = (0, 0)
            while fp != 0, fp & 0x7 == 0, count < capacity {
                var read: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &record) { rec in
                    vm_read_overwrite(mach_task_self_, fp, vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                      vm_address_t(UInt(bitPattern: rec)), &read)
                }
                guard ok == KERN_SUCCESS, read == vm_size_t(MemoryLayout<(UInt, UInt)>.size), record.1 != 0 else { break }
                frames[count] = record.1
                count += 1
                // The chain only ever moves up the stack; anything else is garbage.
                guard record.0 > UInt(fp) else { break }
                fp = vm_address_t(record.0)
            }
        }
        thread_resume(thread)
        return (0..<count).map { describe(frames[$0]) }
        #else
        return []
        #endif
    }

    /// "Lumisound 0x1a2b3c symbol+12" (offset from the image's load address,
    /// which is what a crash symbolicator needs with the build's dSYM).
    private static func describe(_ raw: UInt) -> String {
        // Strip pointer-authentication bits from return addresses.
        let address = raw & 0x0000_000f_ffff_ffff
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "? 0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let offset = address - UInt(bitPattern: info.dli_fbase)
        guard let sname = info.dli_sname else { return String(format: "%@ 0x%lx", image, offset) }
        let symbol = String(String(cString: sname).prefix(120))
        let delta = address - UInt(bitPattern: info.dli_saddr)
        return String(format: "%@ 0x%lx %@+%lu", image, offset, symbol, delta)
    }
}
