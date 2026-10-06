-- 键道27C Flow —— 手动调序存储
--
-- 两种后端（schema 配置 flow_order/backend，用户可用 .custom 覆盖）：
--   leveldb : Rime 原生 userdb（leveldb）   -> <user>/<name>.userdb/
--   txt     : 本模块写的纯文本               -> <user>/<name>.txt
--
-- （librime 的 plain_userdb/tabledb 只接受「code+tab+词」这种用户词典
--   key 格式，不适合当通用 KV，配置成 tabledb 会退回 txt。）
--
-- 内存里始终有一份 order[key] = {候选1, 候选2...}，查询 O(1)；
-- 只有 insert/remove/move_down/remove_word 时才写后端
-- （db 单键写，txt 整文件重写）。remove_word 是反查删除（造词用）：
-- leveldb 没有反向索引，但全部 pin 都在内存里（M.order），扫一遍即可。
--
-- value 格式：条目用 \t 分隔；条目 = 候选词，或
--   「候选词 + 空格 + 完整音节」（音码削减过的 pin，如 ``你 ny``），
--   供 `=` 还原到完整音节时使用（没有记录时回退反查）。
-- 另有特殊 key "~recent"：最近造词记录（造词模式只按 ` 时列出、= 删除）。
-- 特殊 key "~secondary"：次简表（码=文本，Tab 学习/用户覆盖）。
--
-- 调试用 .custom 切到 txt 即可手改数据。

local M = {}
M.order = {}
M.syllables = {}   -- key -> {候选词 = 完整音节}
M.secondary = {}   -- 次简：码 -> 文本（用户覆盖/学习，见 ~secondary）
M.key_prefix = "ord/"
M.ready = false
M.users = 0
M.backend = "leveldb"
M.recent_max = 20   -- 最近造词记录上限（flow_order/recent_max）
M.name = nil
M.path = nil   -- txt 后端文件
M.db = nil     -- leveldb 后端

local function user_dir()
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir()
    end
    return "."
end

-- 解析 value -> M.order[key] / M.syllables[key]
local function parse_value(key, value)
    local list = {}
    local syls = nil
    for entry in value:gmatch("[^\t]+") do
        local text, syl = entry:match("^(.-) (.*)$")
        if text and syl and syl ~= "" then
            list[#list + 1] = text
            syls = syls or {}
            syls[text] = syl
        else
            list[#list + 1] = entry
        end
    end
    M.order[key] = list
    M.syllables[key] = syls
end

local function serialize_value(key)
    local list = M.order[key]
    if not list or #list == 0 then
        return nil
    end
    local syls = M.syllables[key]
    local parts = {}
    for i, text in ipairs(list) do
        local syl = syls and syls[text]
        parts[i] = syl and (text .. " " .. syl) or text
    end
    return table.concat(parts, "\t")
end

-- ---------------- 次简表（特殊 key ~secondary） ----------------
-- value 格式：码=文本，\t 分隔；文本为空表示「取消默认次简」。
-- 码和用户实际敲的键一致（音码 + 形码，如 z / zto / br / o）。

local SECONDARY_KEY = "~secondary"

local function parse_secondary(value)
    M.secondary = {}
    for entry in value:gmatch("[^\t]+") do
        local code, text = entry:match("^(.-)=(.*)$")
        if code and code ~= "" then
            M.secondary[code] = text
        end
    end
end

local function serialize_secondary()
    local parts = {}
    for code, text in pairs(M.secondary) do
        parts[#parts + 1] = code .. "=" .. text
    end
    if #parts == 0 then
        return nil
    end
    table.sort(parts)
    return table.concat(parts, "\t")
end

-- ---------------- txt 后端 ----------------

local function load_txt()
    local f = io.open(M.path, "r")
    if not f then
        return
    end
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local fields = {}
            for field in line:gmatch("[^\t]+") do
                fields[#fields + 1] = field
            end
            if #fields >= 2 then
                if fields[1] == SECONDARY_KEY then
                    parse_secondary(table.concat(fields, "\t", 2))
                else
                    parse_value(fields[1], table.concat(fields, "\t", 2))
                end
            end
        end
    end
    f:close()
end

local function save_txt()
    local f = io.open(M.path, "w")
    if not f then
        return
    end
    f:write("# key\t候选（越靠前越优先；音码削减过的带完整音节）\n")
    for key in pairs(M.order) do
        local value = serialize_value(key)
        if value then
            f:write(key, "\t", value, "\n")
        end
    end
    local sec = serialize_secondary()
    if sec then
        f:write(SECONDARY_KEY, "\t", sec, "\n")
    end
    f:close()
end

-- ---------------- db 后端 ----------------

local function load_db()
    local acc = M.db:query(M.key_prefix)
    if not acc then
        return
    end
    for k, v in acc:iter() do
        local key = k:sub(#M.key_prefix + 1)
        if key == SECONDARY_KEY then
            parse_secondary(v)
        else
            parse_value(key, v)
        end
    end
    -- DbAccessor 要先释放，之后 close 才安全
    acc = nil
    collectgarbage()
end

local function save_key(key)
    if M.backend == "txt" then
        save_txt()
        return
    end
    if not M.db then
        return
    end
    local value
    if key == SECONDARY_KEY then
        value = serialize_secondary()
    else
        value = serialize_value(key)
    end
    if value then
        M.db:update(M.key_prefix .. key, value)
    else
        M.db:erase(M.key_prefix .. key)
    end
end

-- ---------------- 公共接口 ----------------

function M.init(env)
    M.users = M.users + 1
    if M.ready then
        return
    end
    M.order = {}
    M.syllables = {}
    local cfg = env.engine.schema.config
    local backend = cfg:get_string("flow_order/backend")
    if not backend or backend == "" then
        backend = "leveldb"
    end
    local name = cfg:get_string("flow_order/name")
    if not name or name == "" then
        name = cfg:get_string("translator/dictionary") .. ".order"
    end
    M.backend = backend
    M.name = name
    local rmax = cfg:get_int("flow_order/recent_max")
    if rmax and rmax > 0 then
        M.recent_max = rmax
    end
    if backend == "tabledb" then
        -- plain_userdb 不适合做通用 KV，退回 txt
        log.warning("flow_order: tabledb unsupported, fallback to txt")
        backend = "txt"
        M.backend = "txt"
    end

    if backend == "txt" then
        M.path = user_dir() .. "/" .. name .. ".txt"
        load_txt()
    else
        local db
        if LevelDb then
            db = LevelDb(name)
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
            -- 后端不可用则退回 txt
            backend = "txt"
            M.backend = "txt"
            M.path = user_dir() .. "/" .. name .. ".txt"
            load_txt()
            log.warning("flow_order: db backend unavailable, fallback to txt")
        end
    end
    M.ready = true
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

function M.get(key)
    return M.order[key]
end

-- text 在 input 下的 pin 级别（形码串；没有 pin 则 nil）
function M.pin_level(input, text)
    if not input or input == "" or not text or text == "" then
        return nil
    end
    local prefix = input .. "|"
    local n = #prefix
    for key, list in pairs(M.order) do
        if key:sub(1, n) == prefix then
            for _, t in ipairs(list) do
                if t == text then
                    return key:sub(n + 1)
                end
            end
        end
    end
    return nil
end

-- 把 text 从所有 pin 里删掉（保留 ~recent / ~secondary 特殊键）。
-- 调频时词可能只以「补全」身份出现在当前级别（真正的 pin 在别的级别），
-- 只 remove 当前 key 清不到，会留下重复 pin；所以移动 pin 前用这个。
function M.remove_pin(text)
    if not text or text == "" then
        return
    end
    local keys = {}
    for key, list in pairs(M.order) do
        if key:find("|", 1, true) then
            for _, t in ipairs(list) do
                if t == text then
                    keys[#keys + 1] = key
                    break
                end
            end
        end
    end
    for _, key in ipairs(keys) do
        M.remove(key, text)
    end
end

-- 列出同音码下所有形码级别的 pin（不含 ~ 特殊键）：
-- 返回 { { key = 完整键, shape = 形码级别, list = 候选列表 }, ... }。
-- 自造词只存在 pin 里，输入更短的码时也要能像词库词一样看到它，
-- flow_filter 用这个做「同音码补全」。
function M.pins_under(input)
    if not input or input == "" then
        return {}
    end
    local prefix = input .. "|"
    local n = #prefix
    local out = {}
    for key, list in pairs(M.order) do
        if key:sub(1, n) == prefix then
            out[#out + 1] = {
                key = key,
                shape = key:sub(n + 1),
                list = list,
            }
        end
    end
    return out
end

-- 次简覆盖：nil = 没有覆盖；"" = 显式取消（盖掉默认）
function M.get_secondary(code)
    return M.secondary[code]
end

-- 记一条次简覆盖/学习；text 为空表示取消该码的默认次简
function M.set_secondary(code, text)
    if not code or code == "" then
        return
    end
    M.secondary[code] = text or ""
    save_key(SECONDARY_KEY)
end

-- 音码削减过的候选 @ key 上保存的完整音节
function M.get_syllable(key, text)
    local syls = M.syllables[key]
    return syls and syls[text] or nil
end

-- 把 text 放到 key 的第 index 位（默认第 1 位）；syl 非空时记录完整音节
function M.insert(key, text, index, syl)
    local list = M.order[key]
    if not list then
        list = {}
        M.order[key] = list
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    index = index or 1
    if index < 1 then
        index = 1
    elseif index > #list + 1 then
        index = #list + 1
    end
    table.insert(list, index, text)
    if syl and syl ~= "" then
        M.syllables[key] = M.syllables[key] or {}
        M.syllables[key][text] = syl
    end
    save_key(key)
end

-- 把 text 从 key 的手动列表里移出（空则删除整个 key）
function M.remove(key, text)
    local list = M.order[key]
    if not list then
        return
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    local syls = M.syllables[key]
    if syls then
        syls[text] = nil
        if not next(syls) then
            M.syllables[key] = nil
        end
    end
    if #list == 0 then
        M.order[key] = nil
        M.syllables[key] = nil
    end
    save_key(key)
end

-- 反查删除（造词用）：把 text 从**所有** key 里删掉（含最近造词记录），
-- 返回删掉的条数。leveldb 本身没有反向索引，但 init 时已经把全部 pin
-- 读进了内存（M.order: key -> {词...}），所以反查就是扫一遍内存表；
-- 受影响的 key 逐个写回后端（db 单键写 / txt 整文件重写），不需要额外
-- 维护索引。
function M.remove_word(text)
    if not text or text == "" then
        return 0
    end
    local removed = 0
    local keys = {}
    for key in pairs(M.order) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        local list = M.order[key]
        local hit = false
        for i = #list, 1, -1 do
            if list[i] == text then
                table.remove(list, i)
                removed = removed + 1
                hit = true
            end
        end
        if hit then
            local syls = M.syllables[key]
            if syls then
                syls[text] = nil
                if not next(syls) then
                    M.syllables[key] = nil
                end
            end
            if #list == 0 then
                M.order[key] = nil
                M.syllables[key] = nil
            end
            save_key(key)
        end
    end
    return removed
end

-- ---------------- 最近造词（造词模式只按 ` 时列出、= 删除） ----------------

local RECENT_KEY = "~recent"

-- 记一条最近造词：去重后放最前，截到 recent_max
function M.touch_recent(text)
    if not text or text == "" then
        return
    end
    local list = M.order[RECENT_KEY]
    if not list then
        list = {}
        M.order[RECENT_KEY] = list
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    table.insert(list, 1, text)
    for i = #list, M.recent_max + 1, -1 do
        table.remove(list, i)
    end
    save_key(RECENT_KEY)
end

-- 最近造词（最多 limit 条，默认全部）
function M.recent(limit)
    local list = M.order[RECENT_KEY]
    if not list then
        return {}
    end
    limit = limit or #list
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i]
    end
    return out
end

-- 把 text 往下移一位；已在末位则移出手动列表
function M.move_down(key, text)
    local list = M.order[key]
    if not list then
        return
    end
    for i, t in ipairs(list) do
        if t == text then
            if i == #list then
                table.remove(list, i)
                local syls = M.syllables[key]
                if syls then
                    syls[text] = nil
                    if not next(syls) then
                        M.syllables[key] = nil
                    end
                end
                if #list == 0 then
                    M.order[key] = nil
                    M.syllables[key] = nil
                end
            else
                list[i], list[i + 1] = list[i + 1], list[i]
            end
            save_key(key)
            return
        end
    end
end

-- 把 text 往下移一位；已在末位则保留（不删）。
-- 自造词只存在 pin 里，到完整形码后 `=` 再用 move_down 会把词整条
-- 删掉（从所有级别消失），所以这条路径用它：末位就待在末位。
function M.move_down_keep(key, text)
    local list = M.order[key]
    if not list then
        return
    end
    for i, t in ipairs(list) do
        if t == text then
            if i < #list then
                list[i], list[i + 1] = list[i + 1], list[i]
                save_key(key)
            end
            return
        end
    end
end

return M
