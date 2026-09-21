package atelier.tool

import std.collection.*
import std.core.*
import jsonvalue.*

/**
 * ToolExecutor executes single tools and batches of tools.
 *
 * For batch execution:
 * - Tools are executed in the same order as input.
 * - Sequential tools run one by one.
 * - Consecutive Parallel tools run concurrently (via spawn).
 * - If any tool returns terminate=true, remaining sequential tools are skipped
 *   (parallel tools already running may still complete).
 *
 * Every call is bounded by [budget] (None = unbounded) unless the tool declares
 * its own; see {@link executeTool} for what "timeout" means for a synchronous
 * tool, and {@link ToolBudgetPolicy} for why read-only and side-effecting tools
 * get different budgets.
 */
public class ToolExecutor {
    let registry: ToolRegistry
    /** 框架级工具预算策略（只读/有副作用分开）；两类都为 None = 不限时。 */
    let budget: ToolBudgetPolicy

    public init(registry: ToolRegistry,
        budget!: ToolBudgetPolicy = ToolBudgetPolicy(None, None)) {
        this.registry = registry
        this.budget = budget
    }

    /**
     * Execute a single tool by name.
     */
    public func execute(name: String, ctx: ToolContext, args: JsonValue): ToolResult {
        let maybeTool = this.registry.get(name)
        match (maybeTool) {
            case Some(tool) =>
                return executeTool(tool, ctx, args, this.budget.forTool(tool))
            case None =>
                return ToolResult("Tool not found: ${name}", None, true, false)
        }
    }

    /**
     * Execute a batch of tools.
     *
     * Results are returned in the same order as the input tools.
     * If a tool returns terminate=true, remaining sequential tools are skipped.
     */
    public func executeBatch(tools: ArrayList<(String, ToolContext, JsonValue)>): ArrayList<ToolResult> {
        let n = Int64(tools.size)
        let resultMap = HashMap<Int64, ToolResult>()

        var i: Int64 = 0
        var terminated: Bool = false

        while (i < n && !terminated) {
            let (name, ctx, args) = tools[Int64(i)]

            let maybeTool = this.registry.get(name)
            match (maybeTool) {
                case None =>
                    resultMap[i] = ToolResult("Tool not found: ${name}", None, true, false)
                    i = i + 1
                    continue
                case Some(tool) =>
                    match (tool.executionMode()) {
                        case ToolExecutionMode.Sequential =>
                            // Run sequential tool directly
                            let result = executeTool(tool, ctx, args, this.budget.forTool(tool))
                            resultMap[i] = result
                            if (result.terminate) {
                                // Mark remaining as skipped
                                var k = i + 1
                                while (k < n) {
                                    resultMap[k] = ToolResult("Skipped due to terminate flag", None, false, true)
                                    k = k + 1
                                }
                                terminated = true
                            } else {
                                i = i + 1
                            }

                        case ToolExecutionMode.Parallel =>
                            // Collect consecutive parallel tools
                            let parallelBatch = ArrayList<(Int64, String, ToolContext, JsonValue)>()
                            var j = i
                            while (j < n) {
                                let (pname, pctx, pargs) = tools[Int64(j)]
                                let pmaybeTool = this.registry.get(pname)
                                match (pmaybeTool) {
                                    case None => break
                                    case Some(ptool) =>
                                        match (ptool.executionMode()) {
                                            case ToolExecutionMode.Parallel =>
                                                parallelBatch.add((j, pname, pctx, pargs))
                                            case ToolExecutionMode.Sequential =>
                                                break
                                        }
                                }
                                j = j + 1
                            }

                            // Run all parallel tools concurrently via spawn
                            let futures = ArrayList<Future<(Int64, ToolResult)>>()
                            for (batchItem in parallelBatch) {
                                let (idx, pname, pctx, pargs) = batchItem
                                let innerTool = match (this.registry.get(pname)) {
                                    case Some(t) => t
                                    case None => continue
                                }
                                let future = spawn {
                                    let r = executeTool(innerTool, pctx, pargs,
                                        this.budget.forTool(innerTool))
                                    (idx, r)
                                }
                                futures.add(future)
                            }

                            // Wait for all parallel tools and collect results
                            for (future in futures) {
                                let (idx, result) = future.get()
                                resultMap[idx] = result
                            }

                            i = j  // Move past the parallel batch
                    }
            }
        }

        // Build results in original order
        let orderedResults = ArrayList<ToolResult>()
        for (k in 0..n) {
            orderedResults.add(resultMap[k])
        }

        orderedResults
    }
}
