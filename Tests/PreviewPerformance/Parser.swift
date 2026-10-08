import Foundation
import Darwin
import CryptoKit

func memory() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return ["rss_mib": Double(info.resident_size) / 1048576,
            "physical_footprint_mib": Double(info.phys_footprint) / 1048576]
}

@main struct ParserBenchmark {
    static func emit(_ data: [String: Any]) {
        let encoded = try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
        fflush(stdout)
    }

    static func main() {
        let paragraph = "## Heading\n\nMarkdown **bold**, *emphasis*, [link](https://example.com), 中文。 "
            + String(repeating: "Plain text for layout and rendering. ", count: 12) + "\n\n"
        let workloads = [("small", String(repeating: paragraph, count: 8)),
                         ("long", String(repeating: paragraph, count: 1000))]
        let concurrentSource = "# Concurrent\n\n| A | B |\n| --- | --- |\n| one | two |\n\n- [x] done\n"
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            autoreleasepool {
                let html = renderMarkdownHTML(markdown: concurrentSource)!
                precondition(html.contains("<table>") && html.contains("checked"))
            }
        }
        emit(["event": "concurrent_registration", "parses": 32])
        emit(["event": "baseline", "memory": memory(), "pid": getpid()])
        for (name, content) in workloads {
            var latencies = [Double]()
            var digest = ""
            for index in 0..<100 {
                autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let html = renderMarkdownHTML(markdown: content)!
                    latencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    if index == 0 { digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined() }
                }
                if [0, 9, 24, 49, 74, 99].contains(index) {
                    emit(["event": "checkpoint", "workload": name, "iteration": index + 1,
                          "markdown_bytes": content.utf8.count, "memory": memory()])
                }
            }
            emit(["event": "summary", "workload": name, "latency_ms": latencies,
                  "html_sha256": digest, "memory": memory()])
        }
        if ProcessInfo.processInfo.environment["FSNOTES_BENCH_LEAKS_WAIT"] == "1" {
            emit(["event": "awaiting_leaks", "pid": getpid()])
            sleep(20)
        }
    }
}
