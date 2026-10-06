-- 键道27C Flow —— 候选音码推导（用于「还需要按什么键」提示）
--
-- reverse db 里只有单字码（好 -> h hz、会 -> h hb k kd），没有词组；
-- 词组的音码按码表规则用单字码拼出来：
--   * 2 字：音音全码（原 fg + 神 uk = fguk）
--   * 3/4 字：各字首键
--   * 5+ 字：前三首 + 末一首
-- 推导结果只用来给候选显示提示键，不参与候选匹配。

local M = {}
M.ready = false
M.reverse = nil

local char_cache = {}
local word_cache = {}

local function utf8_chars(text)
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    return chars
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
        M.ready = true
        return true
    end
    log.warning("flow_codes: cannot load reverse db")
    return false
end

-- 单字的所有音码（1 键简码 + 全码，多音字有多个）
local function char_codes(ch)
    local cached = char_cache[ch]
    if cached then
        return cached
    end
    local list = {}
    local s = M.reverse and M.reverse:lookup(ch) or ""
    for code in s:gmatch("%S+") do
        list[#list + 1] = code
    end
    char_cache[ch] = list
    return list
end

-- 推导候选词的音码（多音字会得到多个候选码）
local function build_codes(text)
    local cached = word_cache[text]
    if cached then
        return cached
    end
    local chars = utf8_chars(text)
    local n = #chars
    local result = {}
    if n == 1 then
        for _, c in ipairs(char_codes(chars[1])) do
            result[#result + 1] = c
        end
    elseif n == 2 then
        local a, b = char_codes(chars[1]), char_codes(chars[2])
        for _, ca in ipairs(a) do
            if #ca >= 2 then
                for _, cb in ipairs(b) do
                    if #cb >= 2 then
                        result[#result + 1] = ca .. cb
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
        local function combine(i, acc)
            if i > #idx then
                result[#result + 1] = acc
                return
            end
            local seen = {}
            for _, c in ipairs(char_codes(chars[idx[i]])) do
                local k = c:sub(1, 1)
                if k ~= "" and not seen[k] then
                    seen[k] = true
                    combine(i + 1, acc .. k)
                end
            end
        end
        combine(1, "")
    end
    local uniq = {}
    for _, c in ipairs(result) do
        uniq[c] = true
    end
    result = {}
    for c in pairs(uniq) do
        result[#result + 1] = c
    end
    table.sort(result)
    word_cache[text] = result
    return result
end

-- input 之后还需要输入的声码（取最短扩展），没有则返回 nil
function M.next_keys(text, input)
    local best = nil
    for _, code in ipairs(build_codes(text)) do
        if #code > #input and code:sub(1, #input) == input then
            local rest = code:sub(#input + 1)
            if not best or #rest < #best then
                best = rest
            end
        end
    end
    return best
end

return M
