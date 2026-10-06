-- 键道27C Flow —— 形码处理器 + 顶功 + 手动调序
--
-- a/e/i/o/v 是五种笔形（㇐丨丶丿乛），不属于音码。处理器把它们从 speller
-- 输入里取出来，存进 context property "flow_shape"，由 flow_filter 用来
-- 筛选候选，并把它们显示在候选 preedit 末尾。
--
-- 顶功：
--   * 形码后再按音码键：先把形码筛出的候选上屏，再用这个音码键开始新的一段；
--   * 音码已有 4 键时再按音码键：同上（四码自动上屏）。
--
-- 手动调序（用户词典学习已关，改用显式调整）：
--   * `-` 降档/上调：把当前候选 pin 到更短一级，同时从当前级别移走
--     （hjmovo -> hjmov -> hjmo -> hjm，只留最终一级的 pin）；
--     若目标级别已被其他候选占据，被顶掉的候选沿它自己的下一笔形码
--     自动顺延（继续冲突则继续顺延），而不是回到自然排序；
--     可用 flow_order/displace: false 关闭顺延；
--   * `-` 降档/上调：单字全码（声韵，2 键）在最短级别再按 `-` 会削到
--     1 键简码（ny -> n，如把「你」提到 n），并把完整音节 ny 记进 order；
--   * `=` 升档/下调：1 键级别优先用记录的音节还原（n -> ny），没有记录
--     则反查单字码；其它情况补下一笔形码并 pin 到更长一级，
--     同时从更短一级的 pin 列表里移走（保持当前候选，不锁死短码）；
--     到完整形码后则在该 key 内下移一位。
--   * 纯笔码（输入只有 aeiov）：码即完整形码，只有本级——`-` 把候选提到
--     本级首位（不顺延）、`=` 在本级内下移。
--
-- 行为：
--   * 形码键      -> 输入串只有 aeiov 时进入输入串，由笔码表（xkjd27c_flow.bima）
--                    匹配（纯笔码）；否则追加到 flow_shape（最长 12 键），刷新候选
--   * 回车        -> 原样上屏输入（输入 + 形码）
--   * BackSpace   -> flow_shape 非空则删掉最后一个形码
--   * `-` / `=`   -> 手动调序（见上）
--   * 音码键      -> 若 flow_shape 非空（顶码）或音码已达 4 键（四码）则先上屏
--   * 其它键      -> 交给后续组件；上屏后由 commit_notifier 清状态

local order = require("flow_order")
local shapes = require("flow_shapes")
local codes = require("flow_codes")

local SHAPE_KEYS = { a = true, e = true, i = true, o = true, v = true }
local PROP = "flow_shape"
local MAX_SHAPE = 12
local XK_BACKSPACE = 0xff08
local XK_RETURN = 0xff0d
local KEY_MINUS = 0x2d
local KEY_EQUAL = 0x3d

-- 纯形码输入（只有 aeiov）：走笔码表，不走音码逻辑
local function is_shape_only(s)
    return s ~= "" and s:match("^[aeiov]+$") ~= nil
end

local function get_shape(ctx)
    return ctx:get_property(PROP) or ""
end

local function set_shape(ctx, s)
    ctx:set_property(PROP, s)
    ctx:refresh_non_confirmed_composition()
end

local function commit_current(ctx)
    if ctx:is_composing() then
        if ctx:get_selected_candidate() then
            ctx:commit()
        else
            ctx:clear()
        end
    end
end

-- 把 text 放到 input|shape 的首位；目标位若已被其他候选占据，
-- 被顶掉的候选沿它自己的形码串顺延到下一级，递归直到有空位；
-- 已到完整形码仍无空位则丢弃该 pin（回归自然排序）。
-- flow_order/displace: false 时退化为直接插到首位。
-- syl 非空时表示这是一次音码削减，完整音节会随 pin 保存。
local function place(text, input, shape, syl)
    if not order.displace then
        order.insert(input .. "|" .. shape, text, 1, syl)
        return
    end
    local function put(t, s, sy, depth)
        if depth > MAX_SHAPE + 1 then
            return
        end
        local key = input .. "|" .. s
        local list = order.get(key)
        local occupant = list and list[1]
        if occupant == t then
            return
        end
        local occ_syl
        if occupant then
            occ_syl = order.get_syllable(key, occupant)
            order.remove(key, occupant)
        end
        order.insert(key, t, 1, sy)
        if occupant then
            local exp = shapes.expected(occupant)
            if exp and #s < #exp and exp:sub(1, #s) == s then
                put(occupant, exp:sub(1, #s + 1), occ_syl, depth + 1)
            end
        end
    end
    put(text, shape, syl, 1)
end

-- `-` 降档（上调）：把候选从当前级别移走，pin 到更短一级；
--   单字全码（声韵）在最短级别继续削到 1 键简码；
--   已在最短级别（1 键简码）则 pin 在当前位置。
local function promote(ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    if is_shape_only(input) then
        -- 纯笔码：码即完整形码，没有更短的级别；把候选提到本级首位
        -- （不走 place，避免被顶掉的候选顺延到笔码输入打不出的更长 key）
        order.remove(input .. "|", cand.text)
        order.insert(input .. "|", cand.text, 1)
    elseif shape ~= "" then
        order.remove(input .. "|" .. shape, cand.text)
        local target = shape:sub(1, -2)
        place(cand.text, input, target)
        ctx:set_property(PROP, target)
    elseif utf8.len(cand.text) == 1 and #input == 2 then
        -- 声韵 -> 1 键简码；完整音节记进 order，供 = 还原
        order.remove(input .. "|", cand.text)
        local short = input:sub(1, 1)
        place(cand.text, short, "", input)
        ctx.input = short
    else
        place(cand.text, input, "")
    end
    ctx:refresh_non_confirmed_composition()
end

-- `=` 升档/下调：1 键级别优先用记录的音节还原到声韵（否则反查）；
--   其它情况补下一笔形码并 pin 到更长一级；
--   同时把它从当前（更短）一级的 pin 列表里移走，避免把短码锁死。
--   已到完整形码则在当前 key 内下移一位（下调）。
local function lower_or_extend(ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    local key = input .. "|" .. shape
    if is_shape_only(input) then
        -- 纯笔码：码即完整形码，已是最长级别，在本 key 内下移一位
        order.move_down(key, cand.text)
        ctx:refresh_non_confirmed_composition()
        return
    end
    if shape == "" and #input == 1 then
        local syl = order.get_syllable(key, cand.text)
        if not syl then
            local rest = codes.next_keys(cand.text, input)
            if rest and #rest == 1 then
                syl = input .. rest
            end
        end
        if syl then
            order.remove(key, cand.text)
            order.insert(syl .. "|", cand.text, 1)
            ctx.input = syl
            ctx:refresh_non_confirmed_composition()
            return
        end
    end
    local next = shapes.next_key(cand.text, shape)
    if not next then
        order.move_down(key, cand.text)
        ctx:refresh_non_confirmed_composition()
        return
    end
    order.remove(key, cand.text)
    shape = shape .. next
    order.insert(input .. "|" .. shape, cand.text, 1)
    ctx:set_property(PROP, shape)
    ctx:refresh_non_confirmed_composition()
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return 2
    end
    local ctx = env.engine.context
    local code = key_event.keycode

    -- BackSpace：优先删形码
    if code == XK_BACKSPACE then
        local s = get_shape(ctx)
        if s ~= "" then
            set_shape(ctx, s:sub(1, -2))
            return 1
        end
        return 2
    end

    -- `-` / `=`：手动调序
    if code == KEY_MINUS or code == KEY_EQUAL then
        if ctx:has_menu() and ctx:get_selected_candidate() then
            if code == KEY_MINUS then
                promote(ctx)
            else
                lower_or_extend(ctx)
            end
            return 1
        end
        return 2
    end

    -- 回车：原样上屏输入（含形码），不走 express_editor 的原始输入
    -- （后者只提交 ctx.input，会丢掉 flow_shape 里的形码）
    if code == XK_RETURN then
        if ctx:is_composing() then
            local text = ctx.input .. get_shape(ctx)
            if text ~= "" then
                -- engine:commit_text 不会触发 commit_notifier，手动清形码状态
                ctx:set_property(PROP, "")
                ctx:clear()
                env.engine:commit_text(text)
                return 1
            end
        end
        return 2
    end

    if code < 0x20 or code >= 0x7f then
        return 2
    end
    local key = string.char(code)

    -- 形码键
    if SHAPE_KEYS[key] then
        if ctx:is_composing() then
            -- 纯笔码输入（还没有音码）：形码进入输入串，交给笔码表匹配
            if ctx.input == "" or is_shape_only(ctx.input) then
                return 2
            end
            local s = get_shape(ctx)
            if #s < MAX_SHAPE then
                set_shape(ctx, s .. key)
            end
            return 1
        end
        return 2
    end

    -- 音码键
    if key:match("^[a-z;]$") then
        local s = get_shape(ctx)
        if s ~= "" then
            -- 顶码（形码）后自动上屏
            commit_current(ctx)
            ctx:set_property(PROP, "")
        elseif #ctx.input >= 4 and ctx:is_composing() and
                ctx:get_selected_candidate() then
            -- 四码自动上屏：已有 4 个音码键且当前有候选，再按音码键先上屏；
            -- 若无候选（如 5 键节奏码的前 4 键不合法），则让按键继续延长输入
            ctx:commit()
        end
    end

    return 2
end

local function init(env)
    order.init(env)
    shapes.init(env)
    codes.init(env)
    env.flow_shape_conn = env.engine.context.commit_notifier:connect(
        function(ctx)
            ctx:set_property(PROP, "")
        end)
end

local function fini(env)
    if env.flow_shape_conn then
        env.flow_shape_conn:disconnect()
        env.flow_shape_conn = nil
    end
    order.close()
end

return { func = processor, init = init, fini = fini }
