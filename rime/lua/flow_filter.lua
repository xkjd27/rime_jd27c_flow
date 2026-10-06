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
local secondary = require("flow_secondary")

local ready = false
local hint_on = true       -- 总开关（声码提示 + 候选排序）
local hint_shape = true    -- 笔码（形码）提示：flow_hint/shape
local hint_topup = true    -- 不可顶功提示（⛔️）：flow_hint/topup
-- 自动前进状态：key = 音码串 .. "|" .. 形码前缀 -> 当时的首选
local top_cache = {}

local function full_span(cand, input_len)
    return (cand._start or 0) == 0 and (cand._end or 0) == input_len
end

-- 把手动顺序里的候选提到前面；传了 span 时，列表里有、当前翻译没给的
-- （用户 pin 过的词，含造词入库的）直接补一个候选——所以只用 order.userdb
-- 就能既排序又加词。
local function apply_manual_order(list, key, span_start, span_end, code)
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
            -- 翻译没给的 pin（造词存的组合词）补成候选；preedit 要带上当前
            -- 音码——否则这一段 composition 的 preedit 只剩形码，提示框里
            -- 看不到 hjm，simp 这种没有词库兜底的词库下尤其明显
            local cand = Candidate("flow_order", span_start, span_end, text, "")
            cand.preedit = code or ""
            result[#result + 1] = cand
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

-- 给候选写上提示：优先补声码（先音后形），声码已完则给形码（可用
-- flow_hint/shape 关）；返回提示键串（= 还差几键），供候选排序用
local function apply_hint(cand, input, shape, base, excluded, current_top, ctx)
    if not hint_on or cand.text == current_top then
        return nil
    end
    local hint = codes.next_keys(cand.text, input)
    if not hint and hint_shape then
        hint = shape_hint(cand, input, shape, base, excluded, current_top, ctx)
    end
    if hint and hint ~= "" then
        cand.comment = hint
        return hint
    end
    return nil
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

    -- 收集这段 translation 的候选。
    -- 造词模式下 filter 也会被叫到开头 ` 的 punct 段上，这时候
    -- composition:back() 是后面的音码段；span 要以这段候选自己的为准，
    -- 否则会把 pin 候选挂到 ` 段上（preedit/preview 里重复显示）。
    -- 普通模式照旧要求候选覆盖整段输入。
    local dict_words = {}
    local base = {}
    local span_start, span_end
    if creating then
        for cand in translation:iter() do
            local s, e = cand._start or 0, cand._end or 0
            if not span_start then
                span_start, span_end = s, e
            end
            if s == span_start and e == span_end then
                dict_words[cand.text] = true
                if shapes.match(cand.text, shape) then
                    base[#base + 1] = cand
                end
            end
        end
        if not span_start then
            -- 这段还没有候选（音码打一半）：退回当前段
            span_start, span_end = 0, input_len
            local seg = ctx.composition and ctx.composition:back()
            if seg then
                span_start, span_end = seg.start, seg._end
            end
        end
    else
        span_start, span_end = 0, input_len
        for cand in translation:iter() do
            if (cand._start or 0) == span_start and
                    (cand._end or 0) == span_end then
                dict_words[cand.text] = true
                if shapes.match(cand.text, shape) then
                    base[#base + 1] = cand
                end
            end
        end
    end
    -- 当前段的音码（造词模式下去掉开头的 `）。pin / 自动前进 / 补全都用它
    -- 当 key：造词模式下已确认的段不该参与当前段的候选和排除
    local code_text = input:sub(span_start + 1, span_end)
    if creating then
        code_text = create.strip_marker(code_text)
    end
    local key = code_text .. "|" .. shape
    -- 自造词补全：自造词只存在 pin 里，输入同音码下更短/其它形码级别时
    -- 也要能像词库词一样看到它——同音码下 pin 在其它级别的词按 pin 长短
    -- 补进候选（pin 越短越靠前）。不这样做的话，simp 这种词库没兜底的词
    -- 一旦被 = 加长就整个消失。
    -- 补进 base 而不是单放 chosen：shape_hint 只认 base，进 base 才能像
    -- 词库词一样算「还需要按什么」；自造词同样参与自动前进排除，
    -- 多按一个形码就该翻到下一个候选（和词库词一致）。
    -- 默认权重高：补出来的自造词放在自然候选前面（命中 pin 的再由
    -- apply_manual_order 提到最前），其余和自然候选一起按提示键数排序。
    local injected = {}
    if code_text ~= "" and not is_shape_only_input(code_text) then
        local seen = {}
        for _, cand in ipairs(base) do
            seen[cand.text] = true
        end
        local pins = order.pins_under(code_text)
        table.sort(pins, function(a, b)
            if #a.shape ~= #b.shape then
                return #a.shape < #b.shape
            end
            return a.key < b.key
        end)
        for _, pin in ipairs(pins) do
            for _, text in ipairs(pin.list) do
                if not dict_words[text] then
                    -- 本级 pin 也要进 base：模拟更深一级时它仍在候选里，
                    -- apply_manual_order 会把它排到当前级别首位，不会重复
                    if not seen[text] and shapes.match(text, shape) then
                        seen[text] = true
                        local cand = Candidate("flow_order", span_start,
                                               span_end, text, "")
                        cand.preedit = code_text
                        injected[#injected + 1] = cand
                    end
                end
            end
        end
    end
    if #injected > 0 then
        for _, cand in ipairs(base) do
            injected[#injected + 1] = cand
        end
        base = injected
    end
    -- 先应用 pin：列表里有、翻译没给的词会被补成候选（造词存的组合词）
    local chosen = apply_manual_order(base, key, span_start, span_end, code_text)
    -- 造词模式还没打码（只有 `）：候选里补上最近的造词，供 = 删除。
    -- 文本带造词标记（`` `简直了 ``），选中后状态和普通造词选段一致；
    -- 注释标「最近」，不参与提示计算（见下面 yield 前的分支）
    local recent
    if creating and create.strip_marker(input) == "" then
        local list = order.recent(8)
        if #list > 0 then
            recent = {}
            for _, word in ipairs(list) do
                local text = create.mark() .. word
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
    -- 次简（原版「二重」）：当前码有次简时放到第 2 位、注释 🔹；
    -- 不在候选里就注入一个（Tab 学来的可能是词组）
    local secondary_text
    if not creating then
        secondary_text = secondary.get(input .. shape)
        if secondary_text then
            local found
            for i, cand in ipairs(chosen) do
                if cand.text == secondary_text then
                    found = i
                    break
                end
            end
            if not found then
                local cand =
                    Candidate("flow_order", span_start, span_end, secondary_text, "")
                cand.preedit = code_text
                chosen[#chosen + 1] = cand
                found = #chosen
            end
            if found > 2 then
                local cand = table.remove(chosen, found)
                table.insert(chosen, 2, cand)
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
        for idx, cand in ipairs(chosen) do
            if secondary_text and cand.text == secondary_text and idx > 1 then
                cand.comment = "🔹"
            end
            yield(cand)
        end
        return
    end

    local excluded = collect_exclusions(code_text, shape)

    -- 该 key 有手动顺序：不再做自动前进
    local wanted = order.get(key)
    local final, current_top
    if wanted and #wanted > 0 then
        final = chosen
        current_top = chosen[1].text
    else
        local has_excluded = next(excluded) ~= nil
        final = {}
        local full_code = {}   -- 全码命中但被自动前进排除的，低优先级兜底
        for _, cand in ipairs(chosen) do
            if has_excluded and excluded[cand.text] then
                -- 音码已完整 + 形码刚好是完整形码 = 命中全码：无视 auto
                -- advance，补在候选最后（组内保持 chosen 顺序：自造词在前，
                -- 其余按权重序）；纯形码输入不算
                if shape ~= "" and shapes.expected(cand.text) == shape and
                        codes.next_keys(cand.text, code_text) == nil then
                    full_code[#full_code + 1] = cand
                end
            else
                final[#final + 1] = cand
            end
        end
        for _, cand in ipairs(full_code) do
            final[#final + 1] = cand
        end
        if #final == 0 then  -- 全被排除则回退，避免空菜单
            final = chosen
        end
        current_top = final[1].text
    end

    top_cache[key] = current_top

    -- 提示按键：造词模式用当前段的音码（去掉开头的 `），否则用整段输入
    local hint_input = code_text
    local hint_ctx = {}
    -- 不可顶功提示（原版 ⛔️）：纯音码、不足 4 键、还没形码时，
    -- 再加音码也不会顶功上屏（只会继续延长输入）
    local code = code_text
    local no_topup = shape == "" and #code >= 1 and #code < 4 and
        code:match("^[bcdfghjklmnpqrstuwxyz;]+$") ~= nil
    -- 按「还差几键」（提示键数）稳定排序：首选 0 键、次简 1 键（Tab），
    -- 其余按提示长度；同样键数的保持原来的权重 / pin 顺序；没有提示的
    -- （最近造词、推不上去的）放最后
    local ordered = {}
    for i, cand in ipairs(final) do
        local cost
        if recent and recent[cand.text] then
            -- 最近造词：不参与提示计算，注释标「最近」
            cand.comment = "最近"
            cost = math.huge
        elseif secondary_text and cand.text == secondary_text and i > 1 then
            -- 次简：注释标 🔹（和原版一样），形码照常显示在 preedit 上；
            -- 次简本身就是首选时不标（Tab 仍然上屏它）
            annotate(cand, shape)
            cand.comment = "🔹"
            cost = 1
        else
            local hint = apply_hint(cand, hint_input, shape, base, excluded,
                                    current_top, hint_ctx)
            annotate(cand, shape)
            if creating and hint_input == "" then
                -- 只有 `：在标点的〔半角〕/〔全角〕提示后补「造词模式」
                cand.comment = (cand.comment or "") .. "造词"
            end
            if i == 1 and hint_on and hint_topup and no_topup then
                cand.comment = "⛔️" .. (cand.comment or "")
            end
            if i == 1 then
                cost = 0
            elseif hint then
                cost = #hint
            else
                cost = math.huge
            end
        end
        ordered[#ordered + 1] = { cand = cand, cost = cost, i = i }
    end
    table.sort(ordered, function(a, b)
        if a.cost ~= b.cost then
            return a.cost < b.cost
        end
        return a.i < b.i
    end)
    for _, entry in ipairs(ordered) do
        yield(entry.cand)
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
    local cfg = env.engine.schema.config
    -- flow_hint 支持两种写法：
    --   flow_hint: false                -- 总开关（提示 + 排序都关）
    --   flow_hint:\n    shape: false   -- 笔码提示
    --                topup: false   -- 不可顶功提示（⛔️）
    -- 是 map 时 get_bool("flow_hint") 不可靠，只要子项出现过就当总开关是开
    local hs = cfg:get_bool("flow_hint/shape")
    local ht = cfg:get_bool("flow_hint/topup")
    local h = cfg:get_bool("flow_hint")
    if hs ~= nil or ht ~= nil then
        hint_on = true
    elseif h ~= nil then
        hint_on = h
    end
    if hs ~= nil then
        hint_shape = hs
    end
    if ht ~= nil then
        hint_topup = ht
    end
end

return { func = filter, tags_match = tags_match, init = init }
