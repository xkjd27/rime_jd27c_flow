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
--   * 形码键      -> 输入串只有 aeiov 时进入输入串，由纯形码表（xkjd27c_flow.shape）
--                    匹配（纯笔码）；否则追加到 flow_shape，刷新候选
--   * 回车        -> 原样上屏输入（输入 + 形码）
--   * BackSpace   -> flow_shape 非空则删掉最后一个形码
--   * `-` / `=`   -> 手动调序（见上）；造词模式下 `-` 入库退出、`=` 删除
--   * 音码键      -> 若 flow_shape 非空（顶码）或音码已达 4 键（四码）则先上屏；
--                    造词模式下不上屏，改为确认当前段、继续新段（顶功前进）
--   * 其它键      -> 交给后续组件；上屏后由 commit_notifier 清状态

local order = require("flow_order")
local shapes = require("flow_shapes")
local codes = require("flow_codes")
local create = require("flow_create")
local secondary = require("flow_secondary")

local SHAPE_KEYS = { a = true, e = true, i = true, o = true, v = true }
local PROP = "flow_shape"
local XK_BACKSPACE = 0xff08
local XK_TAB = 0xff09
local XK_RETURN = 0xff0d
local XK_ESCAPE = 0xff1b
local KEY_MINUS = 0x2d
local KEY_EQUAL = 0x3d

-- 纯形码输入（只有 aeiov）：走纯形码表，不走音码逻辑
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
-- 递归深度由候选自己的期望形码长度兜底（每层形码 +1，不会死循环）。
-- syl 非空时表示这是一次音码削减，完整音节会随 pin 保存。
local function place(text, input, shape, syl)
    local function put(t, s, sy)
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
                put(occupant, exp:sub(1, #s + 1), occ_syl)
            end
        end
    end
    put(text, shape, syl)
end

-- 把一段的文本换成 text。Rime 没有「删字」的 API，用单候选菜单替换；
-- 已确认的段之后不会被重翻译，替换能保持住。
local function set_segment_text(ctx, seg, text)
    local repl = Candidate("flow_order", seg.start, seg._end, text, "")
    repl.preedit = text
    -- Translation 的生成函数要用插件的全局 yield() 产出候选（不能 return）
    local trans = Translation(function()
        yield(repl)
    end)
    local menu = Menu()
    menu:add_translation(trans)
    menu:prepare(1)
    seg.menu = menu
    seg.selected_index = 0
    seg.status = "kSelected"
    ctx.input = ctx.input   -- 触发重画
end

-- `-` 降档（上调）：把候选从当前级别移走，pin 到更短一级；
--   补全来的词（pin 在别的级别）先 pin 到本级，pin 在更短级别时从
--   它自己的级别再上一级；单字全码（声韵）在最短级别继续削到 1 键简码；
--   已在最短级别（1 键简码）则 pin 在当前位置。
local function promote(ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    local level = order.pin_level(input, cand.text)
    if is_shape_only(input) then
        -- 纯笔码：码即完整形码，没有更短的级别；把候选提到本级首位
        -- （不走 place，避免被顶掉的候选顺延到笔码输入打不出的更长 key）
        order.remove_pin(cand.text)
        order.insert(input .. "|", cand.text, 1)
    elseif shape ~= "" then
        local target
        if level == shape then
            target = shape:sub(1, -2)
        elseif level and #level < #shape then
            target = level:sub(1, -2)
        else
            target = shape
        end
        order.remove_pin(cand.text)
        place(cand.text, input, target)
        ctx:set_property(PROP, target)
    elseif utf8.len(cand.text) == 1 and #input == 2 and
            (level == nil or level == "") then
        -- 声韵 -> 1 键简码；完整音节记进 order，供 = 还原
        order.remove_pin(cand.text)
        local short = input:sub(1, 1)
        place(cand.text, short, "", input)
        ctx.input = short
    else
        order.remove_pin(cand.text)
        place(cand.text, input, "")
    end
    ctx:refresh_non_confirmed_composition()
end

-- `=` 升档/下调：1 键级别优先用记录的音节还原到声韵（否则反查）；
--   其它情况补下一笔形码并 pin 到更长一级，从词自己的 pin 级别延长
--   （补全来的词 pin 在别的级别，别从当前级别延长把它提上来）；
--   已到完整形码则在它那一级的 key 内下移一位（下调）。
local function lower_or_extend(ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    local key = input .. "|" .. shape
    local level = order.pin_level(input, cand.text)
    if is_shape_only(input) then
        -- 纯笔码：码即完整形码，已是最长级别，在本 key 内下移一位
        order.move_down(key, cand.text)
        ctx:refresh_non_confirmed_composition()
        return
    end
    if shape == "" and #input == 1 and
            (level == nil or level == "") then
        local syl = order.get_syllable(key, cand.text)
        if not syl then
            local rest = codes.next_keys(cand.text, input)
            if rest and #rest == 1 then
                syl = input .. rest
            end
        end
        if syl then
            order.remove_pin(cand.text)
            order.insert(syl .. "|", cand.text, 1)
            ctx.input = syl
            ctx:refresh_non_confirmed_composition()
            return
        end
    end
    local base = level or shape
    local next = shapes.next_key(cand.text, base)
    if not next then
        if cand.type == "flow_order" then
            -- 补出来的自造词：到完整形码后别把它移出 pin（否则词会从
            -- 所有级别整个消失），在本级末位待着就行
            order.move_down_keep(input .. "|" .. base, cand.text)
        else
            order.move_down(input .. "|" .. base, cand.text)
        end
        ctx:refresh_non_confirmed_composition()
        return
    end
    -- 补码升档：本级首位让给下一个候选（`uyhs=` 后重打 `uyhs` 由「事后」接替）
    local seg = ctx.composition and ctx.composition:back()
    if seg and seg.selected_index == 0 then
        local second = seg:get_candidate_at(1)
        if second and second.text and second.text ~= "" then
            order.remove_pin(second.text)
            order.insert(key, second.text, 1)
        end
    end
    order.remove_pin(cand.text)
    local target = base .. next
    order.insert(input .. "|" .. target, cand.text, 1)
    ctx:set_property(PROP, target)
    ctx:refresh_non_confirmed_composition()
end

local function processor(key_event, env)
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return 2
    end
    local ctx = env.engine.context
    local code = key_event.keycode
    create.tick(ctx)
    local is_create = create.active(ctx)

    -- `：从空输入进入造词模式（标记进输入串）；
    -- 造词中再按 ` 视为非法内容：已输内容连同这个 ` 直接上屏（交给标点/编辑器）
    local mark = create.is_trigger(code)
    if mark then
        if is_create then
            create.exit(ctx)
            return 2
        end
        if not ctx:is_composing() then
            create.enter(ctx, mark)
            return 1
        end
        return 2
    end

    -- Esc：退出造词模式（输入交给 editor 清掉）
    if is_create and code == XK_ESCAPE then
        create.exit(ctx)
        return 2
    end

    -- Tab：次简。当前码有次简 → 上屏次简；否则上屏当前候选，并把它
    -- 学成该码首键的次简（如 `kffy` 的可以 → `k` 的次简）
    if code == XK_TAB and not is_create and secondary.enabled() then
        if ctx:is_composing() and ctx:has_menu() then
            local raw = ctx.input .. get_shape(ctx)
            -- 首码是笔码（纯笔码输入）时不给次简，Tab 直接吞掉：
            -- 笔码候选里没有别的字可选
            if not raw:match("^[bcdfghjklmnpqrstuwxyz;]") then
                return 1
            end
            local want = secondary.get(raw)
            local cand = ctx:get_selected_candidate()
            if not want and raw ~= "" and cand and cand.text and cand.text ~= "" then
                want = cand.text
                secondary.set(raw:sub(1, 1), want)
            end
            if want and want ~= "" then
                -- engine:commit_text 不会触发 commit_notifier，手动清状态
                ctx:set_property(PROP, "")
                ctx:clear()
                env.engine:commit_text(want)
            end
            return 1
        end
        return 2
    end

    -- BackSpace：优先删形码；造词模式下已确认的文本按字删（像上屏后
    -- 在应用里按退格），删空的那一段再整段删（连同它的输入）
    if code == XK_BACKSPACE then
        local s = get_shape(ctx)
        if s ~= "" then
            set_shape(ctx, s:sub(1, -2))
            return 1
        end
        if is_create then
            if #ctx.input <= 1 then
                create.exit(ctx)
                return 2
            end
            local comp = ctx.composition
            local seg = comp:back()
            if seg and (seg._end - seg.start) == 0 then
                comp:pop_back()   -- 尾部空段
                seg = comp:back()
            end
            if seg and (seg.status == "kSelected" or
                    seg.status == "kConfirmed") then
                local cand = seg:get_selected_candidate()
                local text = (cand and cand.text) or ""
                local n = utf8.len(text)
                if n and n > 1 then
                    -- 去掉最后一个字，保留这段的输入和位置
                    set_segment_text(ctx, seg,
                                     text:sub(1, utf8.offset(text, n) - 1))
                    return 1
                end
                -- 只剩一个字（或没候选）：整段连输入一起删
                ctx.input = ctx.input:sub(1, seg.start)
                return 1
            end
            -- 还没确认的输入：逐键删
            ctx.input = ctx.input:sub(1, -2)
            return 1
        end
        return 2
    end

    -- 造词模式：空格/数字用于分词选择；
    -- 还没打码（只有 `）或无候选时，空格视为非法内容，直接上屏退出
    if is_create then
        if code == 0x20 then
            local code_part = create.strip_marker(ctx.input)
            -- 最近造词选中后空格：确认进 context（不上屏、不退出造词），
            -- 状态变成 `` `简直了 ``，之后可以 = 删除或 - 重新按全码入库
            if code_part == "" and ctx:has_menu() and
                    create.recent_selected(ctx) then
                return 2
            end
            if code_part == "" or not ctx:has_menu() then
                -- 数字选过候选后段会关闭、尾巴变成空段（无菜单）：
                -- 空格没有要确认的东西，留在造词模式就好；
                -- 否则会把 `` `哈级 `` 这种带标记的原文直接上屏
                local seg = ctx.composition and ctx.composition:back()
                if code_part ~= "" and seg and
                        (seg._end - seg.start) == 0 then
                    return 1
                end
                create.exit(ctx)
                return 2  -- Editor::Confirm → ConfirmCurrentSelection || Commit
            end
            -- 分词：确认当前段（_auto_commit 已关，不上屏）。先确认再清形码，
            -- 顺序反了会用清掉形码后的候选（可能是别的词）；形码带进下一段
            -- 会让造词模式用上一段的形码筛下一段的读音（simp 下尤明显）
            ctx:confirm_current_selection()
            ctx:set_property(PROP, "")
            return 1
        end
        if code >= 0x30 and code <= 0x39 and not ctx:has_menu() then
            return 1  -- 防止落到 express_editor 的 DirectCommit
        end
    end

    -- `-` / `=`：造词模式 `-` 入库（并退出）、`=` 删除；否则手动调序
    if code == KEY_MINUS or code == KEY_EQUAL then
        if is_create then
            if code == KEY_MINUS then
                create.store(ctx)
            else
                create.delete(ctx)
            end
            return 1
        end
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
                if is_create then
                    create.exit(ctx)
                end
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
            -- 纯笔码输入（还没有音码）：形码进入输入串，交给纯形码表匹配
            if ctx.input == "" or is_shape_only(ctx.input) then
                return 2
            end
            set_shape(ctx, get_shape(ctx) .. key)
            return 1
        end
        return 2
    end

    -- 音码键
    if key:match("^[a-z;]$") then
        if is_create then
            -- 造词模式：不自动上屏，但顶功照常「前进」——当前段音码满
            -- 4 键或已有形码时，把这一段确认掉（composition 保留），
            -- 下一个键开始新的一段：`jm;yl 会边打边前进成「`简直l」
            local seg = ctx.composition and ctx.composition:back()
            local seg_len = seg and (seg._end - seg.start) or 0
            local s = get_shape(ctx)
            if (s ~= "" or seg_len >= 4) and ctx:is_composing() and
                    ctx:get_selected_candidate() then
                ctx:confirm_current_selection()
                ctx:set_property(PROP, "")
            end
            return 2
        end
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
    secondary.init(env)
    env.flow_shape_conn = env.engine.context.commit_notifier:connect(
        function(ctx)
            ctx:set_property(PROP, "")
            create.reset(ctx)
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
