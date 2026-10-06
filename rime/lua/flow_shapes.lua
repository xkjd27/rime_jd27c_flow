-- 键道27C Flow —— 形码数据与期望形码串
--
-- 期望形码串（原版 xkjd27c.cizu 全量验证 38,678/38,679 吻合）：
--   前 n-1 个字各取首键 + 最后一个字的完整形码。
-- 数据来自 <dict>.shape.txt（ZiDB 前 4 笔形，aeiov）。

local M = {}
M.shapes = {}
M.ready = false
local expected_cache = {}
local function resource_paths(env, suffix)
    local dict = env.engine.schema.config:get_string("translator/dictionary")
    local names = { dict }
    -- 词库变体名（xkjd27c_flow.ice / .simp）：共享文件按基础名再找一次
    local base = dict:match("^(.-)%.[^%.]+$")
    if base and base ~= dict then
        names[#names + 1] = base
    end
    local paths = {}
    for _, name in ipairs(names) do
        if rime_api and rime_api.get_user_data_dir then
            paths[#paths + 1] = rime_api.get_user_data_dir() ..
                "/" .. name .. suffix
        end
        if rime_api and rime_api.get_shared_data_dir then
            paths[#paths + 1] = rime_api.get_shared_data_dir() ..
                "/" .. name .. suffix
        end
    end
    return paths
end

function M.init(env)
    if M.ready then
        return true
    end
    for _, path in ipairs(resource_paths(env, ".shape.txt")) do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and line:sub(1, 1) ~= "#" then
                    local char, shape = line:match("^([^\t]+)\t([^\t]+)")
                    if char then
                        M.shapes[char] = shape
                    end
                end
            end
            f:close()
            M.ready = true
            return true
        end
    end
    log.warning("flow_shapes: cannot load shape table")
    return false
end

-- 候选文本的期望形码串；任一字缺形码数据返回 nil
function M.expected(text)
    local cached = expected_cache[text]
    if cached ~= nil then
        return cached or nil
    end
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    local n = #chars
    if n < 1 then
        expected_cache[text] = false
        return nil
    end
    local parts = {}
    for i = 1, n - 1 do
        local s = M.shapes[chars[i]]
        if not s or s == "" then
            expected_cache[text] = false
            return nil
        end
        parts[#parts + 1] = s:sub(1, 1)
    end
    local last = M.shapes[chars[n]]
    if not last or last == "" then
        expected_cache[text] = false
        return nil
    end
    parts[#parts + 1] = last
    local result = table.concat(parts)
    expected_cache[text] = result
    return result
end

-- shape 之后的下一个期望键；不匹配或没有则 nil
function M.next_key(text, shape)
    local exp = M.expected(text)
    if not exp then
        return nil
    end
    if #shape >= #exp then
        return nil
    end
    if exp:sub(1, #shape) ~= shape then
        return nil
    end
    return exp:sub(#shape + 1, #shape + 1)
end

function M.match(text, shape)
    if shape == "" then
        return true
    end
    local exp = M.expected(text)
    if not exp then
        return false
    end
    return exp:sub(1, #shape) == shape
end

return M
