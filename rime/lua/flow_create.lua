-- 键道27C Flow —— 造词模式
--
-- `（或 ~）开头进入：
--   * 普通输入，但禁用顶功/四码自动上屏（临时关掉 _auto_commit）；
--   * 不计算候选提示（flow_filter 负责）；
--   * 空格/数字用于分词选择（确认当前段 / 选第 N 个候选），都不上屏；
--   * `-`：把当前 composition 的文字（各段选择拼起来）反推全码写入
--     flow_words 的 LevelDB，退出造词模式并把输入重写成全码；
--   * `=` 无效；Esc，或退格到空输入退出。
--
-- _auto_commit 的恢复：主动退出（Esc / `-` / 退到底）立即恢复；经由
-- 上屏结束时（Enter 等走 commit_notifier）延后到下一次按键，避免在
-- commit_notifier 里触发 composition 刷新。

local codes = require("flow_codes")
local words = require("flow_words")

local M = {}

local PROP = "flow_create"
local TRIGGERS = { [0x60] = true, [0x7e] = true }  -- ` / ~

local on_state = false
local saved_auto = true
local restore_pending = false

function M.is_trigger(code)
    return TRIGGERS[code] == true
end

function M.active(ctx)
    return on_state and ctx:get_property(PROP) == "1"
end

function M.enter(ctx)
    on_state = true
    restore_pending = false
    ctx:set_property(PROP, "1")
    local saved = ctx:get_option("_auto_commit")
    saved_auto = (saved == nil) and true or saved
    ctx:set_option("_auto_commit", false)
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

-- `-`：composition 文字 -> 全码入库，退出造词模式，输入重写成全码，
-- 之后按普通候选参与 `-`/`=` 调频。
function M.store(ctx)
    local seg = ctx.composition and ctx.composition:back()
    if seg and not ctx:has_menu() and (seg._end - seg.start) > 0 then
        -- 当前段是没有候选的原始输入，不当词存
        return
    end
    local phrase = ctx:get_commit_text()
    local input = ctx.input
    local key
    if phrase ~= "" then
        key = codes.full_code(phrase, input) or input
    end
    if key and key ~= "" then
        words.add(key, phrase)
    end
    ctx:set_property(PROP, "")
    restore(ctx)
    ctx:clear()
    if key and key ~= "" then
        ctx:push_input(key)
    end
end

function M.init(env)
    words.init(env)
end

function M.close()
    words.close()
end

return M
