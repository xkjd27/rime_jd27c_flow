-- 键道27C Flow —— 造词存储（用户词库）
--
-- 造词模式（` 开头，见 flow_shape.lua）按 `-` 时把当前 composition 的文字
-- 反推成全码存进来；之后在普通模式下它会作为候选注入。
--
-- 存储：Rime 原生 leveldb -> <user>/xkjd27c_flow.words.userdb/
--   key   = "w/" .. 词组全码（各字 2 键音码拼接；推导失败时退回输入串）
--   value = 词条，多个用 \t 分隔
--
-- 命中规则（查询走内存，见 M.match）：
--   1. 输入恰好等于全码；
--   2. 输入等于候选文字按方案规则推导出的码（2 字全码 / 3 字以上简码，
--      含多音字变体，复用 flow_codes.build_codes）。

local codes = require("flow_codes")

local M = {}
M.entries = {}  -- key -> { 词条, ... }
M.ready = false
M.users = 0
M.db = nil
M.key_prefix = "w/"

local function parse_value(key, value)
    local list = {}
    for entry in value:gmatch("[^\t]+") do
        list[#list + 1] = entry
    end
    if #list > 0 then
        M.entries[key] = list
    end
end

local function serialize(key)
    local list = M.entries[key]
    if not list or #list == 0 then
        return nil
    end
    return table.concat(list, "\t")
end

local function load_db()
    local acc = M.db:query(M.key_prefix)
    if not acc then
        return
    end
    for k, v in acc:iter() do
        parse_value(k:sub(#M.key_prefix + 1), v)
    end
    -- DbAccessor 要先释放，之后 close 才安全
    acc = nil
    collectgarbage()
end

local function save_key(key)
    if not M.db then
        return
    end
    local value = serialize(key)
    if value then
        M.db:update(M.key_prefix .. key, value)
    else
        M.db:erase(M.key_prefix .. key)
    end
end

function M.init(env)
    M.users = M.users + 1
    if M.ready then
        return M.db ~= nil
    end
    M.entries = {}
    local db
    if LevelDb then
        db = LevelDb("xkjd27c_flow.words")
    end
    if db then
        if not db:loaded() then
            db:open()
        end
        if db:loaded() then
            M.db = db
            load_db()
        end
    end
    if not M.db then
        log.warning("flow_words: leveldb unavailable")
    end
    M.ready = true
    return M.db ~= nil
end

function M.close()
    M.users = M.users - 1
    if M.users > 0 then
        return
    end
    M.users = 0
    if M.db then
        M.db:close()
        M.db = nil
    end
    -- 允许下次 init 重新打开（部署/重建引擎时会 fini + init）
    M.ready = false
end

-- 入库：全码 key -> 词条
function M.add(key, word)
    if not M.ready or not M.db or key == "" or word == "" then
        return false
    end
    local list = M.entries[key]
    if not list then
        list = {}
        M.entries[key] = list
    end
    for _, w in ipairs(list) do
        if w == word then
            return true
        end
    end
    list[#list + 1] = word
    save_key(key)
    return true
end

-- 输入 input 时命中的用户词（全码精确 / 方案码精确）
function M.match(input)
    if not M.ready or not M.db or input == "" then
        return {}
    end
    local out, seen = {}, {}
    local function push(w)
        if not seen[w] then
            seen[w] = true
            out[#out + 1] = w
        end
    end
    local list = M.entries[input]
    if list then
        for _, w in ipairs(list) do
            push(w)
        end
    end
    for _, words_list in pairs(M.entries) do
        for _, w in ipairs(words_list) do
            if not seen[w] and codes.has_code(w, input) then
                push(w)
            end
        end
    end
    return out
end

return M
