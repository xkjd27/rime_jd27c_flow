-- 键道27C Flow —— 次简表（默认值 + 用户覆盖/学习）
--
-- 默认值 = 原版 buchong「二重」段的**单键**条目（15 个声码）
-- + 「形简」段里多出来的 `识 o`（原来排在 shape.dict 的 2 号位）。
-- buchong 里多键的「二重」（叭br 氏uy 嘁qy…）不在这里——那些是原版
-- 词库层面的第 2 位，不是次简。
-- 用户覆盖/学习写在 flow_order 的 ~secondary 键里，优先于默认；覆盖值
-- 为空字符串表示取消该码的默认次简。
--
-- 「码」= 用户实际敲的键（音码 + 形码），例如 z / zto / o。
-- Tab 的行为见 flow_shape：当前码有次简就上屏次简，没有则上屏当前候选
-- 并把它学成该码首键的次简（如 kffy → 可以 → k 的次简）。

local order = require("flow_order")

local M = {}

-- 总开关：flow_secondary: false 时整块关掉（Tab 处理、次简候选、学习），
-- 已经存下的 ~secondary 数据保留，重新打开就恢复。
local enabled = true

M.defaults = {
    -- 二重（单键声码）：吧b 打d 发f 嘿h 及j 啦l 嘛m 哪n 期q 挺t 实u 玩w 嗯x 重y 咱z
    b = "吧", d = "打", f = "发", h = "嘿", j = "及", l = "啦", m = "嘛",
    n = "哪", q = "期", t = "挺", u = "实", w = "玩", x = "嗯", y = "重", z = "咱",
    -- 形简里多出来的那条
    o = "识",
}

-- 读配置（由 flow_shape / flow_filter 的 init 调用）
function M.init(env)
    local v = env.engine.schema.config:get_bool("flow_secondary")
    if v ~= nil then
        enabled = v
    end
end

function M.enabled()
    return enabled
end

-- 该码的次简；nil = 没有（功能关掉 / 用户显式取消 / 表里没有）
function M.get(code)
    if not enabled then
        return nil
    end
    local override = order.get_secondary(code)
    if override ~= nil then
        if override == "" then
            return nil
        end
        return override
    end
    return M.defaults[code]
end

-- 记一条（Tab 学习 / 用户覆盖；功能关掉时不写）
function M.set(code, text)
    if not enabled then
        return
    end
    order.set_secondary(code, text)
end

return M
