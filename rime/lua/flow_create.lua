-- 键道27C Flow —— 造词模式
--
-- ` 开头进入：
--   * 标记 ` 进输入串，preedit 里看得见；另见 flow_filter 的「造词模式」提示；
--   * 普通输入，但禁用顶功/四码自动上屏（临时关掉 _auto_commit）；
--   * 候选提示照常；空格/数字用于分词选择（确认当前段 / 选第 N 个候选），
--     都不上屏；非法内容（再按 `、没候选时的空格、标点）原样上屏退出；
--   * `-`：把**已确认**的词 pin 在「音码|形码」首位（造词全码，如 其实我觉得 →
--     quwd + voeoeeoi）；如果还有没确认的段（正在打 / 还在选 / 打错没
--     候选）则吞掉——用户还没把词组打完，不猜候选。最后一段用空格确认
--     （数字只用于选是哪个候选）。入库时音码归位到方案简码（`jm;yl 拼
--     出来的简直了 → j;l），形码一律重填成这个词需要的完整形码；退出
--     造词并还原成普通输入（保留形码），之后继续按 `-` 一级一级剥形码调权；
--   * `=` 无效；Esc，或退格到空输入退出。
--
-- 入库即 flow_order 里的一条 pin，不再单独维护 words 库：造出来的词一定
-- 是当前码上的现成候选，pin 住它就能到首位。

local order = require("flow_order")
local codes = require("flow_codes")
local shapes = require("flow_shapes")

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

-- `-`：把已经确认的词 pin 在「音码|形码」首位（造词全码，如 其实我觉得 →
-- quwd + voeoeeoi）；还有没确认的段（正在打/还在选/打错）时直接吞掉：
-- 还没打完，不猜候选。确认最后一段用空格（数字只用于选候选）。
-- 退出造词模式并还原成普通输入（保留形码），之后可以继续按 `-`
-- 一格一格剥形码，把词调到想要的级别/权重。
function M.store(ctx)
    -- 当前段还有没确认的输入：有候选（还在选）或没候选（打错了）都吞掉
    local seg = ctx.composition and ctx.composition:back()
    if seg and (seg._end - seg.start) > 0 then
        return
    end
    local sound = M.strip_marker(ctx.input)
    local phrase = M.strip_marker(ctx:get_commit_text())
    local ok = phrase ~= "" and sound ~= ""
    local shape = ""
    if ok then
        -- 音码归位到方案简码（顶功前进拼出来的全码 → 方案码）
        if not codes.is_scheme_code(phrase, sound) then
            sound = codes.scheme_code(phrase) or sound
        end
        -- 形码删掉重填：全码一律用这个词需要的完整形码（没打也会补）
        shape = shapes.expected(phrase) or ""
        order.insert(sound .. "|" .. shape, phrase, 1)
    end
    ctx:set_property(PROP, "")
    restore(ctx)
    ctx:clear()
    if ok then
        -- 回到普通模式：音码进输入、形码留在 shape；词已在候选首位，
        -- 继续按 `-` 就能一级一级升上去
        ctx:set_property("flow_shape", shape)
        ctx:push_input(sound)
    else
        ctx:set_property("flow_shape", "")
    end
end

return M
