-- 键道27C Flow —— 次简表（默认值 + 用户覆盖/学习）
--
-- 默认值来自原版 buchong 的「二重」段（15 个单键 + 20 个多键 + 3 个
-- 三键）和「形简」段里多出来的 `识 o`（原来排在 shape.dict 的 2 号位，
-- 现在由这里管）。
-- 用户覆盖/学习写在 flow_order 的 ~secondary 键里，优先于默认；覆盖值
-- 为空字符串表示取消该码的默认次简。
--
-- 「码」= 用户实际敲的键（音码 + 形码），例如 z / zto / br / o。
-- Tab 的行为见 flow_shape：当前码有次简就上屏次简，没有则上屏当前候选
-- 并把它学成该码首键的次简（如 kffy → 可以 → k 的次简）。

local order = require("flow_order")

local M = {}

M.defaults = {
    -- 二重（单键声码）：吧b 打d 发f 嘿h 及j 啦l 嘛m 哪n 期q 挺t 实u 玩w 嗯x 重y 咱z
    b = "吧", d = "打", f = "发", h = "嘿", j = "及", l = "啦", m = "嘛",
    n = "哪", q = "期", t = "挺", u = "实", w = "玩", x = "嗯", y = "重", z = "咱",
    -- 二重（多键）：码 = 音码 + 形码
    br = "叭", uy = "氏", jc = "脚", js = "届", jy = "急", hf = "呵", lx = "凉",
    py = "屁", pn = "噗", ww = "喂", xy = "兮", ru = "哟", fy = "咦", wr = "哇",
    zf = "啧", qy = "嘁", fs = "耶", ["f;"] = "愈", mt = "蛮", [";l"] = "长",
    fyo = "意", fyoo = "噫", uyo = "视",
    -- 形简里多出来的那条
    o = "识",
}

-- 该码的次简；nil = 没有（用户显式取消、或表里没有）
function M.get(code)
    local override = order.get_secondary(code)
    if override ~= nil then
        if override == "" then
            return nil
        end
        return override
    end
    return M.defaults[code]
end

-- 记一条（Tab 学习 / 用户覆盖）
function M.set(code, text)
    order.set_secondary(code, text)
end

return M
