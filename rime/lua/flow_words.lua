-- 键道27C Flow —— 造词存储（用户词库）
--
-- 造词模式（` 开头，见 flow_shape.lua）按 `-` 时把「音码 + 形码」当作
-- 全码存进来（如 其实我觉得 → quwdvoeoeeoi）；之后在普通模式下输入同一串
-- 会被注入到候选最前。
--
-- 存储：Rime 原生 leveldb -> <user>/xkjd27c_flow.words.userdb/
--   key   = "w/" .. 全码（音码 + 形码，造词时实际打出的那串）
--   value = 词条，多个用 \t 分隔
--
-- 命中规则：输入（音码 + 形码）恰好等于全码。要更短的前缀/权重，用普通模式的
-- `-` 一级一级把词升上去（写进 flow_order 的 pin）。

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

-- 入库：全码（音码 + 形码）-> 词条
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

-- 输入 code（音码 + 形码）恰好命中时返回用户词
function M.match(code)
    if not M.ready or not M.db or code == "" then
        return {}
    end
    local list = M.entries[code]
    if not list or #list == 0 then
        return {}
    end
    local out = {}
    for _, w in ipairs(list) do
        out[#out + 1] = w
    end
    return out
end

return M
