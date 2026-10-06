-- 键道27C Flow —— 整段过滤 + 形码筛选 + 手动调序
--
-- 1. 只保留覆盖整段输入（_start==0 且 _end==输入长）的候选；
-- 2. 按 flow_shape 做形码筛选（规则见 flow_shapes.lua），并把形码显示在
--    preedit 末尾；
-- 3. 自动前进：每多一个键（声码或形码），排除所有更短前缀当时的首选，
--    让首选项前进（细选）；
-- 4. 手动调序：flow_order 里记录的候选排前面（该 key 有记录时不再自动前进）；
-- 5. 造词模式只按 ` 时：候选里补上最近的造词（注释「最近」），供 = 删除。

local order = require("flow_order")
local shapes = require("flow_shapes")
local codes = require("flow_codes")
local create = require("flow_create")

local ready = false
local hint_on = true
-- 自动前进状态：key = 音码串 .. "|" .. 形码前缀 -> 当时的首选
local top_cache = {}

local function full_span(cand, input_len)
    return (cand._start or 0) == 0 and (cand._end or 0) == input_len
end

-- 把手动顺序里的候选提到前面；传了 span 时，列表里有、当前翻译没给的
-- （用户 pin 过的词，含造词入库的）直接补一个候选——所以只用 order.userdb
-- 就能既排序又加词。
local function apply_manual_order(list, key, span_start, span_end)
    local wanted = order.get(key)
    if not wanted or #wanted == 0 then
        return list
    end
    local used = {}
    local result = {}
    for _, text in ipairs(wanted) do
        local found
        for i, cand in ipairs(list) do
            if not used[i] and cand.text == text then
                found = i
                break
            end
        end
        if found then
            result[#result + 1] = list[found]
            used[found] = true
        elseif span_start then
            result[#result + 1] =
                Candidate("flow_order", span_start, span_end, text, "")
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

-- 把当前形码接到候选 preedit 末尾显示（有候选时走这条，前端一定能看到）
local function annotate(cand, shape)
    if shape == "" then
        return
    end
    local p = cand.preedit or ""
    cand.preedit = (p == "" and shape) or (p .. " " .. shape)
end

-- 把 base 的候选按期望形码前缀分桶（每个候选 O(形码长) 一次），
-- shape_hint 里就不用每步线性扫 base 了
local function build_buckets(base, shape)
    local buckets = {}
    local n = #shape
    for _, c in ipairs(base) do
        local exp = shapes.expected(c.text)
        if exp and exp:sub(1, n) == shape then
            for k = n + 1, #exp do
                local p = exp:sub(1, k)
                local b = buckets[p]
                if not b then
                    b = {}
                    buckets[p] = b
                end
                b[#b + 1] = c
            end
        end
    end
    return buckets
end

-- 沿候选的期望形码串模拟自动前进，返回让它成为首选的形码键串
local function shape_hint(cand, input, shape, base, excluded, current_top, ctx)
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
        if not ctx.buckets then
            ctx.buckets = build_buckets(base, shape)
        end
        local list = ctx.buckets[p]
        if not list then
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
local function apply_hint(cand, input, shape, base, excluded, current_top, ctx)
    if not hint_on or cand.text == current_top then
        return
    end
    local hint = codes.next_keys(cand.text, input)
    if not hint then
        hint = shape_hint(cand, input, shape, base, excluded, current_top, ctx)
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
    local creating = ctx:get_property("flow_create") == "1"
    local key = input .. "|" .. shape

    -- 造词模式按当前段（分词后可能不是从 0 开始）收集候选；
    -- 普通模式要求候选覆盖整段输入
    local span_start, span_end = 0, input_len
    if creating then
        local seg = ctx.composition and ctx.composition:back()
        if seg then
            span_start, span_end = seg.start, seg._end
        end
    end

    local base = {}
    for cand in translation:iter() do
        if (cand._start or 0) == span_start and (cand._end or 0) == span_end
                and shapes.match(cand.text, shape) then
            base[#base + 1] = cand
        end
    end
    -- 先应用 pin：列表里有、翻译没给的词会被补成候选（造词存的组合词）
    local chosen = apply_manual_order(base, key, span_start, span_end)
    -- 造词模式还没打码（只有 `）：候选里补上最近的造词，供 = 删除。
    -- 注释标「最近」，不参与提示计算（见下面 yield 前的分支）
    local recent
    if creating and create.strip_marker(input) == "" then
        local list = order.recent(8)
        if #list > 0 then
            recent = {}
            for _, text in ipairs(list) do
                recent[text] = true
                local dup = false
                for _, cand in ipairs(chosen) do
                    if cand.text == text then
                        dup = true
                        break
                    end
                end
                if not dup then
                    chosen[#chosen + 1] =
                        Candidate("flow_order", span_start, span_end, text, "")
                end
            end
        end
    end
    -- 形码显示：有候选时接在候选 preedit 上（annotate）；候选全空时
    -- preedit 会退回原始输入，改挂在段的 prompt 上（插在 preedit 结尾）
    local seg = ctx.composition and ctx.composition:back()
    if seg then
        seg.prompt = (#chosen == 0 and shape ~= "") and (" " .. shape) or ""
    end
    if #chosen == 0 then
        return
    end

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

    -- 提示按键：造词模式用当前段的音码（去掉开头的 `），否则用整段输入
    local hint_input = input:sub(span_start + 1, span_end)
    if creating then
        hint_input = create.strip_marker(hint_input)
    end
    local hint_ctx = {}
    for _, cand in ipairs(final) do
        if recent and recent[cand.text] then
            -- 最近造词：不参与提示计算，注释标「最近」
            cand.comment = "最近"
        else
            apply_hint(cand, hint_input, shape, base, excluded, current_top, hint_ctx)
            annotate(cand, shape)
            if creating and hint_input == "" then
                -- 只有 `：在标点的〔半角〕/〔全角〕提示后补「造词模式」
                cand.comment = (cand.comment or "") .. "造词模式"
            end
        end
        yield(cand)
    end
end

local function tags_match(segment, env)
    if segment:has_tag("abc") then
        return true
    end
    -- 造词模式开头那个 ` 是 punct 段，也要过 filter（给它补「造词模式」提示）
    local ctx = env and env.engine and env.engine.context
    return ctx ~= nil and ctx:get_property("flow_create") == "1"
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
