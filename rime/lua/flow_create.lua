-- 键道27C Flow —— 造词模式
--
-- `（或 ~）开头进入：
--   * 普通输入，但禁用顶功/四码自动上屏（临时关掉 _auto_commit）；
--   * 不计算候选提示（flow_filter 负责）；
--   * 空格/数字用于分词选择（确认当前段 / 选第 N 个候选），都不上屏；
--   * `-`：把「音码 + 形码」（实际打出来的那串）作为全码 → 词组文字写入
--     flow_words 的 LevelDB，退出造词模式并还原成普通输入（保留形码）；
--     之后继续按 `-` 可以一级一级剥形码调整权重；
--   * `=` 无效；Esc，或退格到空输入退出。
--
-- _auto_commit 的恢复：主动退出（Esc / `-` / 退到底）立即恢复；经由
-- 上屏结束时（Enter 等走 commit_notifier）延后到下一次按键，避免在
-- commit_notifier 里触发 composition 刷新。

local words = require("flow_words")

local M = {}

local PROP = "flow_create"
-- 造词模式的开始标记：只认半角 backtick。它从空输入进入造词，并原样放进
-- 输入串（用户看得到当前状态，`-` 入库时去掉）。
local TRIGGERS = { [0x60] = "`" }
-- 可能出现在 composition 开头的标记（全角形位也认，兼容全角模式下的标点候选）
local MARKERS = { "`", "｀" }

local on_state = false
local saved_auto = true
local restore_pending = false

function M.is_trigger(code)
    return TRIGGERS[code]
end

-- 去掉开头的造词标记（` / ~ / ｀ / ～），去掉一个
function M.strip_marker(s)
    for _, p in ipairs(MARKERS) do
        if s:sub(1, #p) == p then
            return s:sub(#p + 1)
        end
    end
    return s
end

function M.active(ctx)
    return on_state and ctx:get_property(PROP) == "1"
end

function M.enter(ctx, mark)
    on_state = true
    restore_pending = false
    ctx:set_property(PROP, "1")
    local saved = ctx:get_option("_auto_commit")
    saved_auto = (saved == nil) and true or saved
    ctx:set_option("_auto_commit", false)
    -- 标记进入输入串，组句开头就能看到造词状态
    ctx:push_input(mark or "`")
end

local function restore(ctx)
    if on_state or restore_pending then
        on_state = false
        restore_pending = false
        ctx:set_option("_auto_commit", saved_auto ~= false)
    end
end

function M.exit(ctx)
    ctx:set_property(PROP, "")
    restore(ctx)
end

-- 上屏/中止时清状态（commit_notifier 调用）
function M.reset(ctx)
    if not on_state then
        return
    end
    on_state = false
    restore_pending = true
    ctx:set_property(PROP, "")
end

-- 处理器每次按键先调用：恢复延后的 _auto_commit
function M.tick(ctx)
    if restore_pending then
        restore_pending = false
        ctx:set_option("_auto_commit", saved_auto ~= false)
    end
end

-- `-`：把「音码 + 形码」当作这个词的全码入库（如 其实我觉得 →
-- quwdvoeoeeoi）；退出造词模式并还原成普通输入（保留形码），
-- 之后可以继续按 `-` 一格一格剥形码，把词调到想要的级别/权重。
function M.store(ctx)
    local seg = ctx.composition and ctx.composition:back()
    if seg and not ctx:has_menu() and (seg._end - seg.start) > 0 then
        -- 当前段是没有候选的原始输入，不当词存
        return
    end
    local sound = M.strip_marker(ctx.input)
    local shape = ctx:get_property("flow_shape") or ""
    local phrase = M.strip_marker(ctx:get_commit_text())
    local code = sound .. shape
    local key
    if phrase ~= "" and code ~= "" then
        key = code
        words.add(key, phrase)
    end
    ctx:set_property(PROP, "")
    restore(ctx)
    ctx:clear()
    if key then
        -- 回到普通模式：音码进输入、形码留在 shape；词已在候选首位，
        -- 继续按 `-` 就能一级一级升上去
        ctx:set_property("flow_shape", shape)
        ctx:push_input(sound)
    else
        ctx:set_property("flow_shape", "")
    end
end

function M.init(env)
    words.init(env)
end

function M.close()
    words.close()
end

return M
