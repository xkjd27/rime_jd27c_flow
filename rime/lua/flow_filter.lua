-- 键道27C Flow —— 整段过滤 + 形码筛选 + 手动调序
--
-- 1. 只保留覆盖整段输入（_start==0 且 _end==输入长）的候选；
-- 2. 按 flow_shape 做形码筛选（规则见 flow_shapes.lua），并把形码显示在
--    preedit 末尾；
-- 3. 自动前进：每多一个键（声码或形码），排除所有更短前缀当时的首选，
--    让首选项前进（细选）；
-- 4. 手动调序：flow_order 里记录的候选排前面（该 key 有记录时不再自动前进）。

local order = require("flow_order")
local shapes = require("flow_shapes")
local codes = require("flow_codes")

local ready = false
local hint_on = true
-- 只给前面的候选算提示：翻到第 3 页以后还看提示的情况很少，
-- 而提示（尤其形码提示）要模拟筛选，很费；上限之外照常出候选。
local HINT_LIMIT = 20
-- 自动前进状态：key = 音码串 .. "|" .. 形码前缀 -> 当时的首选
local top_cache = {}

local function full_span(cand, input_len)
    return (cand._start or 0) == 0 and (cand._end or 0) == input_len
end

-- 把手动顺序里的候选提到前面，其余保持原顺序
local function apply_manual_order(list, key)
    local wanted = order.get(key)
    if not wanted or #wanted == 0 then
        return list
    end
    local used = {}
    local result = {}
    for _, text in ipairs(wanted) do
        for i, cand in ipairs(list) do
            if not used[i] and cand.text == text then
                result[#result + 1] = cand
                used[i] = true
                break
            end
        end
    end
    for i, cand in ipairs(list) do
        if not used[i] then
            result[#result + 1] = cand
        end
    end
    return result
end

-- 排除所有更短前缀（声码 + 形码）当时的首选：
--   * 同输入下更短的形码前缀（含无形码的 base，i=0）
--   * 更短的音码前缀（无形码状态）
local function collect_exclusions(input, shape)
    local excluded = {}
    for i = 0, #shape - 1 do
        local t = top_cache[input .. "|" .. shape:sub(1, i)]
        if t then
            excluded[t] = true
        end
    end
    for i = 1, #input - 1 do
        local t = top_cache[input:sub(1, i) .. "|"]
        if t then
            excluded[t] = true
        end
    end
    return excluded
end

-- 纯形码输入（只有 aeiov）：走纯形码表，不做音码自动前进/提示
local function is_shape_only_input(s)
    return s ~= "" and s:match("^[aeiov]+$") ~= nil
end

-- 把当前形码接到候选 preedit 末尾显示
local function annotate(cand, shape)
    if shape == "" then
        return
    end
    local p = cand.preedit or ""
    cand.preedit = (p == "" and shape) or (p .. " " .. shape)
end

-- 沿候选的期望形码串模拟自动前进，返回让它成为首选的形码键串
local function shape_hint(cand, input, shape, base, excluded, current_top)
    local exp = shapes.expected(cand.text)
    if not exp or exp:sub(1, #shape) ~= shape then
        return nil
    end
    local skip = {}
    for t in pairs(excluded) do
        skip[t] = true
    end
    if current_top then
        skip[current_top] = true
    end
    local p = shape
    local keys = {}
    while #p < #exp do
        p = p .. exp:sub(#p + 1, #p + 1)
        local list = {}
        for _, c in ipairs(base) do
            if shapes.match(c.text, p) then
                list[#list + 1] = c
            end
        end
        if #list == 0 then
            return nil
        end
        local ordered = apply_manual_order(list, input .. "|" .. p)
        local wanted = order.get(input .. "|" .. p)
        local top
        if wanted and #wanted > 0 then
            top = ordered[1]
        else
            for _, c in ipairs(ordered) do
                if not skip[c.text] then
                    top = c
                    break
                end
            end
            if not top then
                top = ordered[1]
            end
        end
        keys[#keys + 1] = exp:sub(#p, #p)
        if top.text == cand.text then
            return table.concat(keys)
        end
        skip[top.text] = true
    end
    return nil
end

-- 给候选写上提示：优先补声码（先音后形），声码已完则给形码
local function apply_hint(cand, input, shape, base, excluded, current_top)
    if not hint_on or cand.text == current_top then
        return
    end
    local hint = codes.next_keys(cand.text, input)
    if not hint then
        hint = shape_hint(cand, input, shape, base, excluded, current_top)
    end
    if hint and hint ~= "" then
        cand.comment = hint
    end
end

local function filter(translation, env)
    if not ready then
        for cand in translation:iter() do
            yield(cand)
        end
        return
    end
    local ctx = env.engine.context
    local input = ctx.input
    local input_len = #input
    local shape = ctx:get_property("flow_shape") or ""
    local key = input .. "|" .. shape

    -- 先收集整段（且符合形码）的候选
    local base = {}
    for cand in translation:iter() do
        if full_span(cand, input_len) and shapes.match(cand.text, shape) then
            base[#base + 1] = cand
        end
    end
    if #base == 0 then
        return
    end
    local chosen = apply_manual_order(base, key)

    -- 纯笔码输入：手动 pin 优先，其余保持原顺序，不发音码/形码提示
    if is_shape_only_input(input) then
        top_cache[key] = chosen[1] and chosen[1].text or nil
        for _, cand in ipairs(chosen) do
            yield(cand)
        end
        return
    end

    local excluded = collect_exclusions(input, shape)

    -- 该 key 有手动顺序：不再做自动前进
    local wanted = order.get(key)
    local final, current_top
    if wanted and #wanted > 0 then
        final = chosen
        current_top = chosen[1].text
    else
        local has_excluded = next(excluded) ~= nil
        final = {}
        for _, cand in ipairs(chosen) do
            if not (has_excluded and excluded[cand.text]) then
                final[#final + 1] = cand
            end
        end
        if #final == 0 then  -- 全被排除则回退，避免空菜单
            final = chosen
        end
        current_top = final[1].text
    end

    top_cache[key] = current_top
    local n = 0
    for _, cand in ipairs(final) do
        n = n + 1
        if n <= HINT_LIMIT then
            apply_hint(cand, input, shape, base, excluded, current_top)
        end
        annotate(cand, shape)
        yield(cand)
    end
end

local function tags_match(segment, env)
    return segment:has_tag("abc")
end

local function init(env)
    order.init(env)
    codes.init(env)
    ready = shapes.init(env)
    local h = env.engine.schema.config:get_bool("flow_hint")
    if h ~= nil then
        hint_on = h
    end
end

return { func = filter, tags_match = tags_match, init = init }
