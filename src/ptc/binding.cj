package atelier.ptc

import jsonvalue.*
import std.collection.*
import atelier.tool.*

/**
 * PTC 子调用的宿主侧契约。
 *
 * 实现方负责把子调用接入与模型直调**完全相同**的策略链：信任闸门、交互审批、
 * `beforeTool` / `afterTool` 钩子、事件流、调用上限。绑定桥只负责参数转换、
 * 调用编号与结果映射，不复制也不跳过任何策略——否则 PTC 会成为绕过闸门的后门。
 */
public interface PtcSubCallHost {
    /**
     * 授权一次子调用，并给出最终参数（钩子可以改写）。
     */
    func authorize(tool: Tool, args: JsonValue): PtcAuthDecision

    /**
     * 执行一次子调用，含开始/结束事件与 `afterTool` 钩子。
     *
     * 实现方保证不抛异常：工具失败以 `ToolResult.isError` 表达。
     */
    func dispatch(tool: Tool, args: JsonValue, callId: String): ToolResult

    /** 生成下一个子调用编号（形如 `<parent>:ptc:<n>`，按提交顺序递增）。 */
    func nextCallId(): String
}

/**
 * 把可见工具集包装成 PTC 绑定命名空间。
 *
 * 生成的命名空间固定为 `tools`，成员名即工具名（原样使用，不做别名改写）：
 * 程序里写作 `(tools::read_file {...})`。
 */
public class PtcBindings {

    /** 绑定命名空间的名字。 */
    public static let NAMESPACE: String = "tools"

    /**
     * 为给定工具集构造 `tools` 命名空间的绑定。
     *
     * 只传入**当前可见**的工具：不注册再过滤，因为权限检查对特殊形式无效，
     * 「环境里没有」才是可靠的边界。
     */
    public static func forTools(tools: ArrayList<Tool>, host: PtcSubCallHost): PtcBindingNamespace {
        let members = HashMap<String, PtcBindingFunction>()
        for (tool in tools) {
            members.add(tool.name(), makeBinding(tool, host))
        }
        PtcBindingNamespace(NAMESPACE, members)
    }

    /**
     * 单个工具的绑定。
     *
     * 返回工具的主文本：与 native 模式下模型看到的内容一致，
     * 这样同一次调用在两种呈现下的语义不因模式而变。
     */
    private static func makeBinding(tool: Tool, host: PtcSubCallHost): PtcBindingFunction {
        { args: JsonValue =>
            match (host.authorize(tool, args)) {
                case PtcAuthDecision.Deny(reason) => PtcBindingOutcome.Err(reason)
                case PtcAuthDecision.Allow => dispatchWith(host, tool, args)
                // 钩子改写的参数同样要落到实际执行上，否则两种呈现下语义不一致
                case PtcAuthDecision.AllowWith(replaced) => dispatchWith(host, tool, replaced)
            }
        }
    }

    private static func dispatchWith(
        host: PtcSubCallHost,
        tool: Tool,
        args: JsonValue
    ): PtcBindingOutcome {
        let callId = host.nextCallId()
        let result = host.dispatch(tool, args, callId)
        if (result.isError) {
            PtcBindingOutcome.Err(result.text)
        } else {
            PtcBindingOutcome.Ok(JsonValue.String(result.text))
        }
    }
}
