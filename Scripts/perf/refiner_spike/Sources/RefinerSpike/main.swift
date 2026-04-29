// THROWAWAY spike for v0.6.3 #R4. Goals:
// 1. Resolve mlx-swift-lm + integration packages
// 2. Load mlx-community/Qwen3.5-4B-MLX-4bit (cached locally from prior audit)
// 3. Generate one refine, verify enable_thinking=false suppresses <think>...</think>
// 4. Print peak RSS to compare against baseline (~2.6 GB target from baseline.md)

import Foundation
import Darwin
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1024.0 / 1024.0 : -1
}

@main
struct Spike {
    static func main() async throws {
        // NOTE: spike uses 0.6B (~400 MB) not 4B to avoid RAM pressure on
        // dev machine while validating the Swift API path. The 4B latency/RSS
        // data is already in docs/perf/baseline.md from Python audit.
        let modelId = "mlx-community/Qwen3-0.6B-4bit"
        print("[Spike] Pre-load RSS=\(String(format: "%.1f", rssMB()))MB")

        let configuration = ModelConfiguration(id: modelId)

        let t0 = nowMs()
        let model = try await #huggingFaceLoadModelContainer(configuration: configuration)
        let loadMs = nowMs() - t0
        print("[Spike] Loaded in \(Int(loadMs))ms, RSS=\(String(format: "%.1f", rssMB()))MB")

        let sysprompt = "You are a careful editor. Polish the spoken transcript: fix fillers, homophones, and natural punctuation. Output only the polished text, no quotes."
        let userInput = "嗯 我们要去那个公园 you know 然后 uhh 看一下日落"

        // Test A: enable_thinking=false (Qwen3-aware)
        print("\n--- Test A: additionalContext=[enable_thinking: false] ---")
        let sessionA = ChatSession(
            model,
            instructions: sysprompt,
            additionalContext: ["enable_thinking": false]
        )
        let t1 = nowMs()
        let outA = try await sessionA.respond(to: userInput)
        print("[Spike] Refine A in \(Int(nowMs() - t1))ms, RSS=\(String(format: "%.1f", rssMB()))MB")
        print("OUTPUT_A: \(outA)")
        print("HAS_THINK_A: \(outA.contains("<think>"))")

        // Test B: default (thinking on, baseline behavior)
        print("\n--- Test B: default additionalContext (thinking on) ---")
        let sessionB = ChatSession(model, instructions: sysprompt)
        let t2 = nowMs()
        let outB = try await sessionB.respond(to: userInput)
        print("[Spike] Refine B in \(Int(nowMs() - t2))ms, RSS=\(String(format: "%.1f", rssMB()))MB")
        print("OUTPUT_B: \(outB)")
        print("HAS_THINK_B: \(outB.contains("<think>"))")

        print("\n[Spike] Done. Peak RSS=\(String(format: "%.1f", rssMB()))MB")
    }
}
