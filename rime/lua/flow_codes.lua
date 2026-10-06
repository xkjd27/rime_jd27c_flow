-- 键道27C Flow —— 候选音码推导（用于「还需要按什么键」提示）
--
-- reverse db 里只有单字码（好 -> h hz、会 -> h hb k kd），没有词组；
-- 词组的音码按码表规则用单字码拼出来：
--   * 2 字：音音全码（原 fg + 神 uk = fguk）
--   * 3/4 字：各字首键
--   * 5+ 字：前三首 + 末一首
-- 推导结果只用来给候选显示提示键，不参与候选匹配。
--
-- 多音字按单字表 xkjd27c_flow.danzi 的读音权重挑最重的读音补全：
-- reverse db 的顺序不可靠（了 -> l,lc,lf），低权重读音会让提示指错
-- （了 在 l 下曾提示 c，实际打 lf 才成首选）。

local M = {}
M.ready = false
M.reverse = nil

local char_cache = {}
local word_cache = {}
local code_weight = {}  -- 字 -> { 音码 = 权重 }

local function utf8_chars(text)
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    return chars
end

-- 读单字表的「字/读音码/权重」（只用于选提示键）
local function load_code_weight()
    local dir = (rime_api and rime_api.get_user_data_dir and
                 rime_api.get_user_data_dir()) or "."
    local f = io.open(dir .. "/xkjd27c_flow.danzi.dict.yaml")
    if not f then
        return
    end
    for line in f:lines() do
        local ch, code, w = line:match("^(.-)\t([^\t]+)\t([%d%.]+)$")
        if ch and ch ~= "" and code then
            local t = code_weight[ch]
            if not t then
                t = {}
                code_weight[ch] = t
            end
            local n = tonumber(w) or 0
            if n > (t[code] or -1) then
                t[code] = n
            end
        end
    end
    f:close()
end

function M.init(env)
    if M.ready then
        return true
    end
    local dict = env.engine.schema.config:get_string("translator/dictionary")
    local db
    if ReverseDb then
        db = ReverseDb("build/" .. dict .. ".reverse.bin")
    end
    if db then
        M.reverse = db
        load_code_weight()
        M.ready = true
        return true
    end
    log.warning("flow_codes: cannot load reverse db")
    return false
end

-- 单字的所有音码（1 键简码 + 全码，多音字有多个），按读音权重降序
local function char_entries(ch)
    local cached = char_cache[ch]
    if cached then
        return cached
    end
    local list = {}
    local s = (M.reverse and M.reverse:lookup(ch)) or ""
    local weights = code_weight[ch]
    for code in s:gmatch("%S+") do
        list[#list + 1] = {
            code = code,
            w = (weights and weights[code]) or 0,
        }
    end
    table.sort(list, function(a, b)
        if a.w ~= b.w then
            return a.w > b.w
        end
        return a.code < b.code
    end)
    char_cache[ch] = list
    return list
end

-- 推导候选词的音码：返回 {code=码, w=权重} 列表（多音字会得到多个候选码）
local function build_codes(text)
    local cached = word_cache[text]
    if cached then
        return cached
    end
    local chars = utf8_chars(text)
    local n = #chars
    local result = {}
    if n == 1 then
        for _, e in ipairs(char_entries(chars[1])) do
            result[#result + 1] = e
        end
    elseif n == 2 then
        local a, b = char_entries(chars[1]), char_entries(chars[2])
        for _, ca in ipairs(a) do
            if #ca.code >= 2 then
                for _, cb in ipairs(b) do
                    if #cb.code >= 2 then
                        result[#result + 1] =
                            { code = ca.code .. cb.code, w = ca.w + cb.w }
                    end
                end
            end
        end
    else
        local idx = {}
        if n >= 5 then
            idx = { 1, 2, 3, n }
        else
            for i = 1, n do
                idx[#idx + 1] = i
            end
        end
        -- 各字的声母首键 -> 该键上的最大读音权重
        local initials = {}
        for _, i in ipairs(idx) do
            local best = {}
            for _, e in ipairs(char_entries(chars[i])) do
                local k = e.code:sub(1, 1)
                if k ~= "" and (best[k] == nil or e.w > best[k]) then
                    best[k] = e.w
                end
            end
            initials[#initials + 1] = best
        end
        local function combine(i, acc, w)
            if i > #initials then
                result[#result + 1] = { code = acc, w = w }
                return
            end
            for k, kw in pairs(initials[i]) do
                combine(i + 1, acc .. k, w + kw)
            end
        end
        combine(1, "", 0)
    end
    -- 去重（同码取最大权重），按权重降序
    local uniq = {}
    local out = {}
    for _, e in ipairs(result) do
        local cur = uniq[e.code]
        if not cur then
            uniq[e.code] = e
            out[#out + 1] = e
        elseif e.w > cur.w then
            cur.w = e.w
        end
    end
    table.sort(out, function(a, b)
        if a.w ~= b.w then
            return a.w > b.w
        end
        return a.code < b.code
    end)
    word_cache[text] = out
    return out
end

-- input 之后还需要输入的声码（按最重读音补全），没有则返回 nil
function M.next_keys(text, input)
    local best, best_w = nil, nil
    for _, e in ipairs(build_codes(text)) do
        local code = e.code
        if #code > #input and code:sub(1, #input) == input then
            local rest = code:sub(#input + 1)
            if not best or e.w > best_w or
                    (e.w == best_w and #rest < #best) then
                best, best_w = rest, e.w
            end
        end
    end
    return best
end

-- 词组全码：每个字取一个 2 键音码拼起来。
-- input 非空且是按对（每字 2 键）对齐的前缀时，优先选与该前缀一致的读音，
-- 否则每字取权重最高的读音；有字找不到 2 键码时返回 nil。
function M.full_code(text, input)
    local chars = utf8_chars(text)
    if #chars == 0 then
        return nil
    end
    local choices = {}
    local prefix_ok = input and input ~= "" and #input <= 2 * #chars
    for i, ch in ipairs(chars) do
        local list = {}
        for _, e in ipairs(char_entries(ch)) do
            if #e.code == 2 then
                list[#list + 1] = e
            end
        end
        if #list == 0 then
            return nil
        end
        choices[i] = list
        if prefix_ok and 2 * i <= #input then
            local pair = input:sub(2 * i - 1, 2 * i)
            local found = false
            for _, e in ipairs(list) do
                if e.code == pair then
                    found = true
                    break
                end
            end
            if not found then
                prefix_ok = false
            end
        end
    end
    local out = {}
    for i = 1, #choices do
        local pick = choices[i][1]
        if prefix_ok then
            local pair = input:sub(2 * i - 1, 2 * i)
            for _, e in ipairs(choices[i]) do
                if e.code == pair then
                    pick = e
                    break
                end
            end
        end
        out[#out + 1] = pick.code
    end
    return table.concat(out)
end

-- text 的推导码里是否有 code（build_codes 含 2 字全码/3 字以上简码的所有变体）
function M.has_code(text, code)
    for _, e in ipairs(build_codes(text)) do
        if e.code == code then
            return true
        end
    end
    return false
end

return M
