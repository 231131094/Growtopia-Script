local WM = "Farm Wooden Platform - KPLUV (V4.0 Auto-Save)"
local C = {
    world_farm = "KPLUV", door_id = "",
    block_id = 102, seed_id = 103,
    max_plant_seeds = 2645, plant_first_min = 100, stack_cap = 200,

    pnb_pos = {67, 49}, pnb_width = 5, pnb_offsets = {-2, -1, 0, 1, 2},
    pnb_offset_y = -1, pnb_max_idle = 15, max_punch_rounds = 5,

    delay_place = 150, delay_punch = 170, min_packet_gap = 55,
    pickup_cooldown = 1200, pickup_max = 6,
    pickup_all = true, auto_drop_full = true,
    spot_pnb_200 = false,

    auto_leave_on_staff = true, wait_empty_sec = 90,
    idle_scan_sec = 5,
    sweep_retry_ms = 60000, unreach_ms = 120000,

    -- Pengaturan Cache & Walk Stall (Anti-Lag)
    ready_cache_ms = 150,
    inv_cache_ms   = 100,
    obj_cache_ms   = 80,
    tiles_cache_ms = 300,
    walk_stall_ms  = 1200,
    walk_max_ms    = 8000
}

local F, state = {}, {
    paused = true, lag = 0, last_send = 0, last_hook = 0,
    ready_t = 0, ready_v = false,
    inv_cache = nil, inv_map = nil, inv_t = 0,
    obj_cache = nil, obj_t = 0,
    tiles_cache = nil, tiles_map = nil, tiles_t = 0,
    picked = {}, sweep_tried = {}, unreach = {},
    drop_target_id = nil, drop_target_cnt = 0,
    last_pnb_plant = 0, standby_logged = false,
    open_menu_req = false, set_pos_req = false, save_req = false
}

local floor, abs, min, max, random = math.floor, math.abs, math.min, math.max, math.random

local function tkey(x, y) return y * 256 + x end

function F.log(t) pcall(log, "[" .. WM .. "] " .. tostring(t)) end
function F.invalidate() state.inv_t, state.obj_t, state.tiles_t = 0, 0, 0 end
function F.lag_bad() state.lag = min(state.lag + 80, 400) end
function F.lag_ok() state.lag = max(state.lag - 40, 0) end
function F.pause(b) sleep((b or C.delay_punch) + random(10, 30) + state.lag) end

function F.update_offsets()
    C.pnb_width = (tonumber(C.pnb_width) == 3) and 3 or 5
    C.pnb_offsets = (C.pnb_width == 3) and {-1, 0, 1} or {-2, -1, 0, 1, 2}
end
F.update_offsets()

----------------------------------------------------------------
-- API DASAR & CACHE RINGAN
----------------------------------------------------------------
function F.wait_until(fn, ms)
    local t = getTime()
    while getTime() - t < ms do
        local ok, r = pcall(fn)
        if ok and r then return true end
        sleep(30)
    end
    return false
end

function F.world_name()
    local ok, w = pcall(getCurrentWorldName)
    return (ok and type(w) == "string") and w or ""
end

function F.world_is(name) return F.world_name():upper() == name:upper() end

function F.safe_local()
    local ok, me = pcall(getLocal)
    return (ok and type(me) == "table" and me.posX and me.posY) and me or nil
end

function F.ready()
    local now = getTime()
    if now - state.ready_t < C.ready_cache_ms then return state.ready_v end
    local w = F.world_name()
    local v = F.safe_local() ~= nil and w ~= "" and w:upper() ~= "EXIT"
    state.ready_t, state.ready_v = now, v
    return v
end

function F.tile_pos()
    local me = F.safe_local()
    if not me then return nil, nil end
    return floor(me.posX / 32), floor(me.posY / 32)
end

function F.throttle()
    local wait = state.last_send + C.min_packet_gap + (state.lag // 4) - getTime()
    if wait > 0 then sleep(wait) end
    state.last_send = getTime()
end

function F.packet_raw(pkt)
    if not F.ready() then return false end
    F.throttle()
    return (pcall(sendPacketRaw, false, pkt))
end

function F.packet_text(ptype, str)
    if not F.ready() then return false end
    F.throttle()
    local fn = type(sendPacket) == "function" and sendPacket
               or (type(SendPacket) == "function" and SendPacket or nil)
    if type(fn) ~= "function" then return false end
    return (pcall(fn, ptype, str))
end

function F.inventory()
    if not F.ready() then return {} end
    local now = getTime()
    if state.inv_cache and now - state.inv_t < C.inv_cache_ms then return state.inv_cache end
    local ok, list = pcall(getInventory)
    if ok and type(list) == "table" then
        local map = {}
        for _, it in pairs(list) do
            if it and it.id then map[it.id] = (map[it.id] or 0) + (it.amount or 0) end
        end
        state.inv_cache, state.inv_map, state.inv_t = list, map, now
        return list
    end
    return {}
end

function F.inv(id)
    if not F.ready() then return 0 end
    F.inventory()
    return (state.inv_map and state.inv_map[id]) or 0
end

function F.objects()
    if not F.ready() then return {} end
    local now = getTime()
    if state.obj_cache and now - state.obj_t < C.obj_cache_ms then return state.obj_cache end
    local ok, list = pcall(getObjectList)
    if ok and type(list) == "table" then
        state.obj_cache, state.obj_t = list, now
        return list
    end
    return {}
end

function F.tiles()
    if not F.ready() then return {}, {} end
    local now = getTime()
    if state.tiles_cache and now - state.tiles_t < C.tiles_cache_ms then
        return state.tiles_cache, state.tiles_map
    end
    local ok, list = pcall(getTiles)
    if not ok or type(list) ~= "table" then return {}, {} end
    local map = {}
    for _, t in pairs(list) do
        if t and t.x and t.y then map[tkey(t.x, t.y)] = t end
    end
    state.tiles_cache, state.tiles_map, state.tiles_t = list, map, now
    return list, map
end

function F.tile(x, y)
    local ok, t = pcall(getTile, x, y)
    return (ok and type(t) == "table") and t or nil
end

----------------------------------------------------------------
-- UI DIALOG MENU (/menu) & SHORTCUT CHAT (/s, /pos)
----------------------------------------------------------------
function F.open_ui()
    local st = state.paused and "`4DIJEDA (Standby)``" or "`2BERJALAN``"
    local tg = state.paused and "`2Mulai / Lanjutkan Bot``" or "`8Jeda (Pause) Bot``"
    local dlg = table.concat({
        "set_default_color|`o",
        "add_label_with_icon|big|`wPengaturan Auto Farm``|left|" .. C.block_id .. "|",
        "add_textbox|Status: " .. st .. " `o- Shortcut: `6/s `o(Start/Pause), `6/pos `o(Set PNB), `6/menu`o.|left|",
        "add_spacer|small|",
        "add_label_with_icon|small|`w1. World & Item Target``|left|3802|",
        "add_text_input|world_farm|Nama World Farm:|" .. C.world_farm .. "|24|",
        "add_text_input|door_id|Door ID (Kosongkan jika tidak ada):|" .. C.door_id .. "|20|",
        "add_text_input|block_id|ID Block:|" .. C.block_id .. "|8|",
        "add_text_input|seed_id|ID Seed:|" .. C.seed_id .. "|8|",
        "add_spacer|small|",
        "add_label_with_icon|small|`w2. Posisi & Area PNB Utama``|left|18|",
        "add_text_input|pnb_x|Koordinat Berdiri X:|" .. C.pnb_pos[1] .. "|6|",
        "add_text_input|pnb_y|Koordinat Berdiri Y:|" .. C.pnb_pos[2] .. "|6|",
        "add_button|set_pos_here|`2Gunakan Posisi Karakter Sekarang``|noflags|0|0|",
        "add_text_input|pnb_width|Jumlah Tile PNB (Isi 3 atau 5):|" .. C.pnb_width .. "|4|",
        "add_text_input|pnb_height|Jarak di Atas Kepala (Isi 1 atau 2):|" .. abs(C.pnb_offset_y) .. "|4|",
        "add_spacer|small|",
        "add_label_with_icon|small|`w3. Kecepatan & Batas Tanam``|left|5732|",
        "add_text_input|delay_place|Delay Taruh Block/Seed (ms):|" .. C.delay_place .. "|6|",
        "add_text_input|delay_punch|Delay Pukul Block (ms):|" .. C.delay_punch .. "|6|",
        "add_text_input|punch_rounds|Maksimal Pukulan Block (Hit):|" .. C.max_punch_rounds .. "|4|",
        "add_text_input|idle_scan|Jeda Scan Saat Standby/Kosong (Detik):|" .. C.idle_scan_sec .. "|4|",
        "add_text_input|max_plant|Batas Maksimal Tanam Seed:|" .. C.max_plant_seeds .. "|6|",
        "add_text_input|plant_first|Prioritas Tanam Dulu Jika Seed >=:|" .. C.plant_first_min .. "|6|",
        "add_spacer|small|",
        "add_label_with_icon|small|`w4. Fitur Tambahan & Keamanan``|left|1432|",
        "add_checkbox|pickup_all|Collect Semua Drop (Gems, Block, Seed, Bonus)|" .. (C.pickup_all and "1" or "0") .. "|",
        "add_checkbox|auto_drop|Auto-Drop ke Posisi PNB Jika Tas Penuh (200)|" .. (C.auto_drop_full and "1" or "0") .. "|",
        "add_checkbox|spot_pnb_200|[Opsional] PNB di Sebelah Kanan Saat Block 200|" .. (C.spot_pnb_200 and "1" or "0") .. "|",
        "add_checkbox|auto_staff|Auto-Kabur ke EXIT Jika Mod/Guardian Masuk|" .. (C.auto_leave_on_staff and "1" or "0") .. "|",
        "add_spacer|small|",
        "add_button|toggle_bot|" .. tg .. "|noflags|0|0|",
        "add_button|save_run|`2Simpan & Jalankan``|noflags|0|0|",
        "end_dialog|kpluv_ui_cfg|Tutup||"
    }, "\n")
    local ok, err = pcall(growtopia.sendDialog, dlg)
    if not ok then F.log("Gagal membuka dialog: " .. tostring(err)) end
end

function F.apply_settings(d)
    if d.world_farm and d.world_farm ~= "" then C.world_farm = d.world_farm:gsub("%s+", ""):upper() end
    if d.door_id ~= nil then C.door_id = d.door_id:gsub("%s+", "") end
    local bid, sid = tonumber(d.block_id), tonumber(d.seed_id)
    if bid and bid > 0 then C.block_id = floor(bid) end
    if sid and sid > 0 then C.seed_id = floor(sid) end
    local px, py = tonumber(d.pnb_x), tonumber(d.pnb_y)
    if px and py then C.pnb_pos = {floor(px), floor(py)} end
    local w, h = tonumber(d.pnb_width), tonumber(d.pnb_height)
    if w == 3 or w == 5 then C.pnb_width = w; F.update_offsets() end
    if h == 1 or h == 2 then C.pnb_offset_y = -h end
    local dp, du = tonumber(d.delay_place), tonumber(d.delay_punch)
    if dp and dp >= 80 then C.delay_place = floor(dp) end
    if du and du >= 80 then C.delay_punch = floor(du) end
    local pr = tonumber(d.punch_rounds)
    if pr and pr >= 1 and pr <= 25 then C.max_punch_rounds = floor(pr) end
    local isc = tonumber(d.idle_scan)
    if isc and isc >= 2 and isc <= 60 then C.idle_scan_sec = floor(isc) end
    local mp, pf = tonumber(d.max_plant), tonumber(d.plant_first)
    if mp and mp > 0 then C.max_plant_seeds = floor(mp) end
    if pf and pf >= 0 then C.plant_first_min = floor(pf) end
    if d.pickup_all ~= nil then C.pickup_all = (d.pickup_all == "1") end
    if d.auto_drop ~= nil then C.auto_drop_full = (d.auto_drop == "1") end
    if d.spot_pnb_200 ~= nil then C.spot_pnb_200 = (d.spot_pnb_200 == "1") end
    if d.auto_staff ~= nil then C.auto_leave_on_staff = (d.auto_staff == "1") end
end

----------------------------------------------------------------
-- PENYIMPANAN OTOMATIS (modul preferences milik launcher)
----------------------------------------------------------------
local pref
do
    local ok, p = pcall(function()
        local m = require("preferences")
        m:new("farm_wooden_kpluv_v3")
        return m
    end)
    if ok and p then
        pref = p
        pcall(function() pref:load() end)
    end
end

local SETTING_KEYS = {
    "world_farm", "door_id", "block_id", "seed_id",
    "pnb_x", "pnb_y", "pnb_width", "pnb_height",
    "delay_place", "delay_punch", "punch_rounds", "idle_scan",
    "max_plant", "plant_first",
    "pickup_all", "auto_drop", "spot_pnb_200", "auto_staff"
}

function F.settings_snapshot()
    return {
        world_farm = C.world_farm, door_id = C.door_id,
        block_id = C.block_id, seed_id = C.seed_id,
        pnb_x = C.pnb_pos[1], pnb_y = C.pnb_pos[2],
        pnb_width = C.pnb_width, pnb_height = abs(C.pnb_offset_y),
        delay_place = C.delay_place, delay_punch = C.delay_punch,
        punch_rounds = C.max_punch_rounds, idle_scan = C.idle_scan_sec,
        max_plant = C.max_plant_seeds, plant_first = C.plant_first_min,
        pickup_all   = C.pickup_all and "1" or "0",
        auto_drop    = C.auto_drop_full and "1" or "0",
        spot_pnb_200 = C.spot_pnb_200 and "1" or "0",
        auto_staff   = C.auto_leave_on_staff and "1" or "0"
    }
end

function F.save_settings()
    if not pref then return false end
    local snap = F.settings_snapshot()
    local ok = pcall(function()
        for _, k in ipairs(SETTING_KEYS) do pref:set(k, tostring(snap[k])) end
        pref:save()
    end)
    if not ok then F.log("Gagal menyimpan setting ke penyimpanan.") end
    return ok
end

function F.load_settings()
    if not pref then
        F.log("Penyimpanan (preferences) tidak tersedia, setting tidak akan tersimpan.")
        return false
    end
    local UNSET = "__unset__"
    local d, n = {}, 0
    for _, k in ipairs(SETTING_KEYS) do
        local ok, v = pcall(function() return pref:get(k, UNSET) end)
        if ok and v ~= nil and v ~= UNSET then
            d[k] = tostring(v)
            n = n + 1
        end
    end
    if n == 0 then
        F.log("Belum ada setting tersimpan, memakai nilai default.")
        return false
    end
    F.apply_settings(d)   -- memakai validasi yang sama dengan menu
    F.log("Setting dimuat dari penyimpanan (" .. n .. " item).")
    return true
end

function F.process_pending_ui()
    local need_save = state.save_req
    state.save_req = false

    if state.set_pos_req then
        state.set_pos_req = false
        local cx, cy = F.tile_pos()
        if cx and cy then
            C.pnb_pos = {cx, cy}
            F.log("Posisi PNB diperbarui ke x" .. cx .. " y" .. cy)
            need_save = true
        end
    end

    if need_save then F.save_settings() end

    if state.open_menu_req then
        state.open_menu_req = false
        F.open_ui()
    end
end

local function on_packet_hook(ptype, pkt)
    if type(pkt) ~= "string" then pkt = (type(ptype) == "string") and ptype or "" end
    local cmd = pkt:match("text|([^\r\n]+)")
    if cmd then
        local c = cmd:gsub("`.", ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local now = getTime()
        if c == "/menu" then
            if now - state.last_hook > 150 then
                state.last_hook = now
                state.open_menu_req = true
            end
            return true
        elseif c == "/s" then
            if now - state.last_hook > 150 then
                state.last_hook = now
                state.paused = not state.paused
                state.standby_logged = false
                F.log(state.paused and "Bot dijeda (/s)." or "Bot dijalankan (/s).")
            end
            return true
        elseif c == "/pos" then
            if now - state.last_hook > 150 then
                state.last_hook = now
                state.set_pos_req = true
            end
            return true
        end
    end

    if pkt:find("dialog_name|kpluv_ui_cfg", 1, true) then
        local d = {}
        for line in pkt:gmatch("[^\r\n]+") do
            local k, v = line:match("^([^|]+)|(.*)$")
            if k then d[k] = v end
        end
        local btn = d.buttonClicked or ""
        if btn == "set_pos_here" then
            F.apply_settings(d)
            state.set_pos_req = true
            state.open_menu_req = true
            state.save_req = true
        elseif btn == "toggle_bot" then
            F.apply_settings(d)
            state.paused = not state.paused
            state.standby_logged = false
            F.log(state.paused and "Bot dijeda melalui UI." or "Bot dilanjutkan melalui UI.")
            state.open_menu_req = true
            state.save_req = true
        elseif btn == "save_run" then
            F.apply_settings(d)
            state.paused = false
            state.standby_logged = false
            state.save_req = true
            local mode_txt = C.spot_pnb_200 and "PNB Kanan di Tempat" or ("PNB Utama x" .. C.pnb_pos[1] .. " y" .. C.pnb_pos[2])
            F.log("Pengaturan disimpan! World: " .. C.world_farm .. " | Mode: " .. mode_txt .. " | Hit: " .. C.max_punch_rounds .. "x")
        end
        return true
    end
    return false
end

local function on_variant_hook(var)
    if not state.drop_target_id or type(var) ~= "table" then return false end
    local fname, arg = var.v1, var.v2
    if fname ~= "OnDialogRequest" then
        fname, arg = (var.v0 or var[0]), (var.v1 or var[1])
    end
    if fname ~= "OnDialogRequest" or type(arg) ~= "string" then return false end
    if not arg:find("dialog_name|drop_item", 1, true) then return false end

    local id, cnt = state.drop_target_id, state.drop_target_cnt
    state.drop_target_id = nil
    local fn = type(sendPacket) == "function" and sendPacket
               or (type(SendPacket) == "function" and SendPacket or nil)
    if fn then
        pcall(fn, 2, "action|dialog_return\ndialog_name|drop_item\nitemID|" .. id .. "|\ncount|" .. cnt .. "\n")
    end
    return true
end

local ok_hook, err_hook = pcall(function()
    addHook(on_packet_hook, "onSendPacket")
    addHook(on_variant_hook, "onVariant")
    if type(applyHook) == "function" then applyHook() end
end)
if not ok_hook then F.log("Gagal memasang hook: " .. tostring(err_hook)) end

----------------------------------------------------------------
-- KEAMANAN STAF & NAVIGASI
----------------------------------------------------------------
function F.is_staff(p)
    if type(p) ~= "table" then return false end
    if p.isMod or p.mod or p.isGuardian or p.guardian or p.invis or p.invisible then
        return true, "Flag/Invis Staff"
    end
    local nm = (type(p.name) == "string" and p.name:gsub("`.", "") or ""):gsub("^%s+", "")
    if nm:sub(1, 1) == "@" or nm:sub(1, 1) == "#" or nm:find("^%[G%]") or nm:find("^Guardian") then
        return true, nm
    end
    return false
end

function F.check_safety()
    F.process_pending_ui()
    if state.paused or not F.ready() then return false end
    if not C.auto_leave_on_staff then return true end
    local me = F.safe_local()
    local ok, players = pcall(getPlayers)
    if not me or not ok or type(players) ~= "table" then return me ~= nil end
    for _, p in pairs(players) do
        if p and p.netID and p.netID ~= me.netID then
            local staff, info = F.is_staff(p)
            if staff then
                F.log("STAF TERDETEKSI (" .. tostring(info) .. ")! Keluar ke EXIT...")
                pcall(growtopia.warpTo, "EXIT")
                state.ready_t = 0
                sleep(C.wait_empty_sec * 1000)
                return false
            end
        end
    end
    return true
end

function F.walk_to(x, y)
    if not F.ready() or not F.check_safety() then return false end
    local px, py = F.tile_pos()
    if px == x and py == y then return true end
    if not pcall(FindPath, x, y) then return false end

    local t0 = getTime()
    local last_move, lx, ly = t0, px, py
    while true do
        F.process_pending_ui()
        if state.paused or not F.ready() then return false end
        px, py = F.tile_pos()
        if px == x and py == y then return true end

        local now = getTime()
        if px ~= lx or py ~= ly then lx, ly, last_move = px, py, now end
        if now - last_move > C.walk_stall_ms then return false end
        if now - t0 > C.walk_max_ms then return false end
        sleep(50)
    end
end

function F.ensure_world(name)
    if F.world_is(name) and F.ready() then return F.check_safety() end
    local target = (C.door_id ~= "") and (name .. "|" .. C.door_id) or name
    for i = 1, 3 do
        F.process_pending_ui()
        if state.paused then return false end
        F.log("Masuk ke " .. name .. " (" .. i .. "/3)")
        pcall(growtopia.warpTo, target)
        state.ready_t = 0
        if F.wait_until(function() return F.world_is(name) and F.ready() end, 12000) then
            sleep(random(1200, 1800))
            F.invalidate()
            return F.check_safety()
        end
        sleep(600)
    end
    return false
end

function F.act(x, y, item)
    local me = F.safe_local()
    return me and F.packet_raw({type = 3, value = item, px = x, py = y, x = me.posX, y = me.posY}) or false
end

----------------------------------------------------------------
-- AUTO-DROP, PICKUP & SWEEP
----------------------------------------------------------------
function F.safe_drop(id)
    local count = F.inv(id)
    if count <= 0 or not F.ready() then return false end

    local fn = (type(growtopia) == "table" and (growtopia.confirmDropItem or growtopia.dropItem))
               or confirmDropItem or dropItem
    if type(fn) == "function" then
        F.throttle()
        pcall(fn, id, count)
        if F.wait_until(function() F.invalidate(); return F.inv(id) < count end, 700) then
            return true
        end
    end

    state.drop_target_id = id
    state.drop_target_cnt = count
    F.packet_text(2, "action|drop\n|itemID|" .. tostring(id) .. "\n")
    local ok = F.wait_until(function() F.invalidate(); return F.inv(id) < count end, 1200)
    state.drop_target_id = nil
    return ok
end

function F.drop_full_to_pnb(rx, ry)
    if not C.auto_drop_full or not F.ready() then return false end
    local function full(id) return F.inv(id) >= C.stack_cap end
    if not full(C.block_id) and not full(C.seed_id) then return false end

    local px, py = C.pnb_pos[1], C.pnb_pos[2]
    F.log("Tas penuh (Block:" .. F.inv(C.block_id) .. ", Seed:" .. F.inv(C.seed_id) .. "), drop ke x" .. px .. " y" .. py)

    local spots = {{px, py}, {px - 1, py}, {px + 1, py}}
    local dropped_any = false

    for _, spot in ipairs(spots) do
        if not full(C.block_id) and not full(C.seed_id) then break end
        if F.walk_to(spot[1], spot[2]) then
            sleep(80)
            if full(C.block_id) and F.safe_drop(C.block_id) then dropped_any = true end
            if full(C.seed_id)  and F.safe_drop(C.seed_id)  then dropped_any = true end
        end
    end

    if not dropped_any then
        F.log("Gagal drop (petak penuh atau API tidak merespons).")
        return false
    end

    if rx and ry and F.walk_to(rx, ry) then
        F.pickup_near(rx, ry, true)
    end
    return true
end

function F.obj_tile(o)
    if not o or not o.pos or not o.pos.x or not o.pos.y then return nil, nil end
    return floor(o.pos.x / 32), floor(o.pos.y / 32)
end

function F.wanted(id)
    if C.pickup_all then return id ~= nil end
    return id == C.block_id or id == C.seed_id
end

function F.pickup_near(px, py, force, only)
    if not F.ready() or not px or not py then return end
    local now, sent, cd = getTime(), 0, force and 300 or C.pickup_cooldown
    for oid, t in pairs(state.picked) do
        if now - t > 10000 then state.picked[oid] = nil end
    end
    local seed_ok = (only == "pnb") and (F.inv(C.seed_id) < C.stack_cap) or false

    for _, o in pairs(F.objects()) do
        if sent >= C.pickup_max then break end
        if o and o.id and o.pos then
            local want
            if only == "pnb" then
                want = (o.itemid == C.block_id) or (o.itemid == 112)
                       or (o.itemid == C.seed_id and seed_ok)
            elseif only then
                want = (o.itemid == only or o.itemid == 112)
            else
                want = F.wanted(o.itemid)
            end
            local last = state.picked[o.id]
            if want and (not last or now - last >= cd) then
                local ox, oy = F.obj_tile(o)
                if ox and oy and abs(ox - px) <= 3 and abs(oy - py) <= 3 then
                    if F.packet_raw({type = 11, value = o.id, x = o.pos.x, y = o.pos.y}) then
                        state.picked[o.id] = now
                        sent = sent + 1
                    end
                end
            end
        end
    end
    if sent > 0 then F.invalidate() end
end

function F.floor_total(item, px, py, radius)
    local n = 0
    for _, o in pairs(F.objects()) do
        if o and o.itemid == item then
            if not px or not py then
                n = n + (o.amount or 0)
            else
                local ox, oy = F.obj_tile(o)
                if ox and oy and abs(ox - px) <= radius and abs(oy - py) <= radius then
                    n = n + (o.amount or 0)
                end
            end
        end
    end
    return n
end

function F.fetch_floor(item, cx, cy, radius)
    for _, o in pairs(F.objects()) do
        if o and o.itemid == item then
            local ox, oy = F.obj_tile(o)
            local inside = true
            if cx and cy and radius and ox and oy then
                inside = abs(ox - cx) <= radius and abs(oy - cy) <= radius
            end
            if ox and oy and inside then
                if not F.ready() or not F.check_safety() or F.inv(item) >= C.stack_cap then return end
                if F.walk_to(ox, oy) then
                    F.pickup_near(ox, oy, true, item)
                    sleep(60)
                end
            end
        end
    end
end

function F.sort_tiles(list)
    if #list <= 1 then return end
    if C.spot_pnb_200 then
        table.sort(list, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
    else
        local rank, ys = {}, {}
        for _, p in ipairs(list) do
            if p.y and not rank[p.y] then rank[p.y] = true; ys[#ys + 1] = p.y end
        end
        table.sort(ys)
        for i, y in ipairs(ys) do rank[y] = i end
        table.sort(list, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            if (rank[a.y] or 1) % 2 == 1 then
                return a.x < b.x
            else
                return a.x > b.x
            end
        end)
    end
end

function F.sweep_dropped_loot()
    if not F.ready() or not F.check_safety() then return end
    local px, py = C.pnb_pos[1], C.pnb_pos[2]
    local swept, now = 0, getTime()

    for oid, t in pairs(state.sweep_tried) do
        if now - t > C.sweep_retry_ms then state.sweep_tried[oid] = nil end
    end

    for _ = 1, 3 do
        local b_full = F.inv(C.block_id) >= C.stack_cap
        local s_full = F.inv(C.seed_id) >= C.stack_cap
        local piles, targets = {}, {}

        for _, o in pairs(F.objects()) do
            if o and o.id and o.pos and not state.sweep_tried[o.id] then
                local it = o.itemid
                local rel = (it == C.block_id) or (it == C.seed_id) or (C.pickup_all and it == 112)
                local can = not ((it == C.block_id and b_full) or (it == C.seed_id and s_full))
                local ox, oy = F.obj_tile(o)
                local skip_pnb = false
                if ox and oy and not C.spot_pnb_200 then
                    skip_pnb = abs(ox - px) <= 2 and abs(oy - py) <= 2
                end
                if rel and can and ox and oy and not skip_pnb then
                    local key = tkey(ox, oy)
                    if not piles[key] then
                        piles[key] = {x = ox, y = oy, ids = {}}
                        targets[#targets + 1] = piles[key]
                    end
                    piles[key].ids[#piles[key].ids + 1] = o.id
                end
            end
        end

        if #targets == 0 then break end
        if swept == 0 then F.log("Mengumpulkan item terjatuh yang tertinggal...") end
        F.sort_tiles(targets)

        for _, pos in ipairs(targets) do
            if not F.ready() or not F.check_safety() then return end
            if C.spot_pnb_200 and F.inv(C.block_id) >= C.stack_cap then
                F.pnb_on_spot()
            else
                F.drop_full_to_pnb(pos.x, pos.y)
            end
            if F.walk_to(pos.x, pos.y) then
                F.pickup_near(pos.x, pos.y, true)
                sleep(60)
                swept = swept + 1
            end
            local t = getTime()
            for _, id in ipairs(pos.ids) do state.sweep_tried[id] = t end
        end
    end
    if swept > 0 then F.log("Sweep selesai (" .. swept .. " titik).") end
end

----------------------------------------------------------------
-- CEK AKTIVITAS (ANTI-LAG PRE-CHECK TANPA PACKET)
----------------------------------------------------------------
function F.is_pnb_reserved(x, y)
    if C.spot_pnb_200 then return false end
    local px, py = C.pnb_pos[1], C.pnb_pos[2]
    if x == px and y == py then return true end
    if y ~= (py + C.pnb_offset_y) then return false end
    for _, dx in ipairs(C.pnb_offsets) do
        if x == px + dx then return true end
    end
    return false
end

function F.has_work()
    local all, map = F.tiles()
    local growing, ripe = 0, 0
    for _, t in pairs(all) do
        if t and t.fg == C.seed_id then
            growing = growing + 1
            if t.readyharvest then ripe = ripe + 1 end
        end
    end

    if ripe > 0 then return true, growing end
    if F.inv(C.block_id) > 0 then return true, growing end

    local now = getTime()
    local has_plant_spot = false
    for _, t in pairs(all) do
        if t and t.x and t.y and t.fg == 0 and not F.is_pnb_reserved(t.x, t.y) then
            local bad = state.unreach[tkey(t.x, t.y)]
            if not (bad and now - bad < C.unreach_ms) then
                local b = map[tkey(t.x, t.y + 1)]
                if b and b.fg ~= 0 and b.fg ~= C.seed_id then
                    has_plant_spot = true
                    break
                end
            end
        end
    end

    if F.inv(C.seed_id) > 0 and has_plant_spot then return true, growing end

    local px, py = C.pnb_pos[1], C.pnb_pos[2]
    local b_full = F.inv(C.block_id) >= C.stack_cap
    local s_full = F.inv(C.seed_id) >= C.stack_cap

    for _, o in pairs(F.objects()) do
        if o and o.id and o.pos then
            local it = o.itemid
            if it == C.block_id and not b_full then return true, growing end
            if it == C.seed_id and not s_full and has_plant_spot then return true, growing end
            local tried = state.sweep_tried[o.id]
            if C.pickup_all and it == 112 and not (tried and now - tried < C.sweep_retry_ms) then
                local ox, oy = F.obj_tile(o)
                local skip_pnb = (not C.spot_pnb_200) and ox and oy
                                 and (abs(ox - px) <= 2 and abs(oy - py) <= 2)
                if not skip_pnb then return true, growing end
            end
        end
    end

    return false, growing
end

----------------------------------------------------------------
-- FITUR TAMBAHAN: PNB DI TEMPAT KE SEBELAH KANAN
----------------------------------------------------------------
function F.pnb_right_wave(px, py)
    local stock, targets = F.inv(C.block_id), {}
    for _, dir in ipairs({1, -1}) do
        targets = {}
        local sim = stock
        for step = 1, 2 do
            local tx = px + (dir * step)
            local g = F.tile(tx, py)
            if g then
                if g.fg == C.seed_id and g.readyharvest then
                    F.act(tx, py, 18)
                    F.pause(C.delay_punch)
                    F.wait_until(function() local ng = F.tile(tx, py); return ng and ng.fg == 0 end, 600)
                    g = F.tile(tx, py)
                end
                if g and g.fg == 0 and sim > 0 then
                    F.act(tx, py, C.block_id)
                    sim = sim - 1
                    targets[#targets + 1] = tx
                elseif g and g.fg == C.block_id then
                    targets[#targets + 1] = tx
                end
            end
        end
        if #targets > 0 then break end
    end
    if #targets == 0 then return false end
    F.invalidate()
    sleep(C.delay_place)
    for _ = 1, C.max_punch_rounds do
        local any = false
        for _, tx in ipairs(targets) do
            local g = F.tile(tx, py)
            if g and g.fg == C.block_id then any = true; F.act(tx, py, 18) end
        end
        if not any then break end
        F.pause(C.delay_punch)
    end
    return true
end

function F.pnb_on_spot()
    local px, py = F.tile_pos()
    if not px or not py then return false end
    local idle, started = 0, false

    while true do
        if not F.ready() and not F.wait_until(F.ready, 15000) then return false end
        if not F.check_safety() then return false end

        if F.inv(C.seed_id) >= C.stack_cap and getTime() - state.last_pnb_plant > 20000 then
            state.last_pnb_plant = getTime()
            F.log("Seed mencapai " .. F.inv(C.seed_id) .. " saat PNB, menanam dulu...")
            F.plant()
            F.walk_to(px, py)
            started = false
        end

        local stock = F.inv(C.block_id)
        if stock <= 0 then
            F.pickup_near(px, py, false, "pnb")
            sleep(80)
            stock = F.inv(C.block_id)
            if stock <= 0 then
                if F.floor_total(C.block_id, px, py, 3) <= 0 then
                    F.pickup_near(px, py, true, "pnb")
                    if started then F.log("PNB di tempat selesai (x" .. px .. " y" .. py .. ")") end
                    return true
                end
                idle = idle + 1
                if idle >= C.pnb_max_idle then return false end
            end
        else
            if not started then
                F.log("PNB di tempat (x" .. px .. " y" .. py .. ") ke sebelah kanan...")
                started = true
            end
            if not F.walk_to(px, py) then
                idle = idle + 1
                if idle >= C.pnb_max_idle then return false end
                sleep(100)
            else
                local ok_wave = F.pnb_right_wave(px, py)
                F.pickup_near(px, py, false, "pnb")
                local after = F.inv(C.block_id)
                if not ok_wave or after >= stock then
                    idle = idle + 1
                    if idle >= C.pnb_max_idle then return false end
                    sleep(100)
                else
                    idle = 0
                end
            end
        end
    end
end

----------------------------------------------------------------
-- HARVEST, PLANT & PNB UTAMA
----------------------------------------------------------------
function F.harvest_tile(t)
    if not F.ready() or not F.check_safety() or not F.walk_to(t.x, t.y) then return false end
    for _ = 1, 3 do
        if not F.act(t.x, t.y, 18) then return false end
        F.pause(C.delay_punch)
        if F.wait_until(function()
            local g = F.tile(t.x, t.y)
            return g and (g.fg ~= C.seed_id or not g.readyharvest)
        end, 700) then
            F.lag_ok()
            local cx, cy = F.tile_pos()
            F.pickup_near(cx, cy, false)
            return true
        end
        F.lag_bad()
    end
    return false
end

function F.harvest()
    local total = 0
    for _ = 1, 10 do
        state.tiles_t = 0
        if not F.ready() or not F.check_safety() then break end
        local list, seen = {}, {}
        for _, t in pairs((F.tiles())) do
            if t and t.x and t.y and t.fg == C.seed_id and t.readyharvest then
                local key = tkey(t.x, t.y)
                if not seen[key] then seen[key] = true; list[#list + 1] = {x = t.x, y = t.y} end
            end
        end
        if #list == 0 then break end
        if total == 0 then F.log("Memulai Harvest...") end
        F.sort_tiles(list)
        local done = 0
        for _, t in ipairs(list) do
            if not F.ready() or not F.check_safety() then break end
            if F.harvest_tile(t) then
                done = done + 1
                if C.spot_pnb_200 then
                    if F.inv(C.block_id) >= C.stack_cap then
                        F.log("Block mencapai " .. F.inv(C.block_id) .. ", langsung PNB di sebelah kanan!")
                        F.pnb_on_spot()
                        F.walk_to(t.x, t.y)
                        F.pickup_near(t.x, t.y, true)
                    end
                    if F.inv(C.seed_id) >= C.stack_cap then
                        F.plant()
                        F.walk_to(t.x, t.y)
                        F.pickup_near(t.x, t.y, true)
                    end
                else
                    F.drop_full_to_pnb(t.x, t.y)
                end
            end
        end
        total = total + done
        if done == 0 then break end
    end
    F.sweep_dropped_loot()
    if total > 0 then F.log("Harvest selesai: " .. total) end
    return total
end

function F.plant_targets()
    local all, map = F.tiles()
    local list = {}
    for _, t in pairs(all) do
        if t and t.x and t.y and t.fg == 0 and not F.is_pnb_reserved(t.x, t.y) then
            local b = map[tkey(t.x, t.y + 1)]
            if b and b.fg ~= 0 and b.fg ~= C.seed_id then
                list[#list + 1] = {x = t.x, y = t.y}
            end
        end
    end
    F.sort_tiles(list)
    return list
end

function F.plant_tile(x, y)
    for _ = 1, 2 do
        if not F.ready() or not F.check_safety() or not F.act(x, y, C.seed_id) then return false end
        F.pause(C.delay_place)
        if F.wait_until(function() local g = F.tile(x, y); return g and g.fg == C.seed_id end, 700) then
            F.lag_ok(); F.invalidate(); return true
        end
        F.lag_bad()
    end
    return false
end

function F.plant()
    local targets = F.plant_targets()
    if #targets == 0 then return 0 end
    F.log("Memulai Plant...")
    local planted, skipped = 0, 0
    for _, t in ipairs(targets) do
        if not F.ready() or not F.check_safety() or planted >= C.max_plant_seeds then break end
        local key = tkey(t.x, t.y)
        local bad = state.unreach[key]
        if bad and getTime() - bad < C.unreach_ms then
            skipped = skipped + 1
        else
            if F.inv(C.seed_id) <= 0 then
                F.fetch_floor(C.seed_id)
                if F.inv(C.seed_id) <= 0 then break end
            end
            if F.walk_to(t.x, t.y) then
                if F.plant_tile(t.x, t.y) then
                    planted = planted + 1
                else
                    state.unreach[key] = getTime()
                end
            else
                state.unreach[key] = getTime()
            end
        end
    end
    if planted > 0 then
        F.log("Plant selesai: " .. planted .. (skipped > 0 and (" (lewati " .. skipped .. " tile)") or ""))
    end
    return planted
end

function F.pnb_wave(px, target_y)
    local stock, targets = F.inv(C.block_id), {}
    for _, dx in ipairs(C.pnb_offsets) do
        local tx = px + dx
        local g = F.tile(tx, target_y)
        if g then
            if g.fg == 0 and stock > 0 then
                F.act(tx, target_y, C.block_id)
                stock = stock - 1
                targets[#targets + 1] = tx
            elseif g.fg == C.block_id then
                targets[#targets + 1] = tx
            end
        end
    end
    if #targets == 0 then return false end
    F.invalidate()
    sleep(C.delay_place)
    for _ = 1, C.max_punch_rounds do
        local any = false
        for _, tx in ipairs(targets) do
            local g = F.tile(tx, target_y)
            if g and g.fg == C.block_id then any = true; F.act(tx, target_y, 18) end
        end
        if not any then break end
        F.pause(C.delay_punch)
    end
    return true
end

function F.pnb()
    if C.spot_pnb_200 then
        if F.inv(C.block_id) > 0 then F.pnb_on_spot() end
        return true
    end

    local px, py = C.pnb_pos[1], C.pnb_pos[2]
    local target_y, idle, started = py + C.pnb_offset_y, 0, false

    while true do
        if not F.ready() and not F.wait_until(F.ready, 15000) then return false end
        if not F.check_safety() then return false end

        if F.inv(C.seed_id) >= C.stack_cap and getTime() - state.last_pnb_plant > 30000 then
            state.last_pnb_plant = getTime()
            F.log("Seed mencapai " .. F.inv(C.seed_id) .. " saat PNB, menanam seed dulu...")
            local p_now = F.plant()
            if p_now > 0 then started = false end
        end

        local stock = F.inv(C.block_id)
        if stock <= 0 then
            F.pickup_near(px, py, false, "pnb")
            sleep(80)
            stock = F.inv(C.block_id)
            if stock <= 0 then
                if F.floor_total(C.block_id, px, py, 4) <= 0 then
                    F.pickup_near(px, py, true, "pnb")
                    if started then F.log("PNB selesai, block bersih") end
                    return true
                end
                if not started then F.log("Mengambil sisa block sekitar PNB..."); started = true end
                F.fetch_floor(C.block_id, px, py, 4)
                idle = idle + 1
                if idle >= C.pnb_max_idle then
                    F.log("PNB macet saat mengambil sisa block sekitar PNB.")
                    return false
                end
            end
        else
            if not started then
                F.log("Memulai PNB di x" .. px .. " y" .. py .. " (target y" .. target_y .. ")")
                started = true
            end
            if not F.walk_to(px, py) then
                idle = idle + 1
                if idle >= C.pnb_max_idle then
                    F.log("PNB macet: gagal menuju titik berdiri x" .. px .. " y" .. py)
                    return false
                end
                sleep(120)
            else
                local ok_wave = F.pnb_wave(px, target_y)
                F.pickup_near(px, py, false, "pnb")
                local after = F.inv(C.block_id)
                if not ok_wave or after >= stock then
                    idle = idle + 1
                    if idle >= C.pnb_max_idle then
                        F.log("PNB macet: baris target y" .. target_y .. " terhalang blok lain! Pindahkan titik PNB lewat /menu.")
                        return false
                    end
                    sleep(120)
                else
                    idle = 0
                end
            end
        end
    end
end

----------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------
function F.guarded(fn)
    local ok, err = pcall(fn)
    if not ok then F.log("Error tertahan: " .. tostring(err)); sleep(1500) end
end

function F.main()
    F.log("V4.0 siap! Ketik /menu (atur), /s (Start/Pause), /pos (Set PNB).")
    F.wait_until(F.ready, 30000)
    sleep(200)
    F.load_settings()
    F.open_ui()

    local cycles = 0
    while true do
        F.process_pending_ui()

        if state.paused then
            sleep(100)
        elseif not F.ensure_world(C.world_farm) then
            sleep(3000)
        else
            local work, growing = false, 0
            F.guarded(function() work, growing = F.has_work() end)

            if not work then
                if growing == 0 and F.inv(C.seed_id) <= 0 and F.floor_total(C.seed_id) <= 0 then
                    F.log("Selesai: tidak ada seed & tanaman tumbuh. Bot dijeda.")
                    state.paused = true
                    state.standby_logged = false
                else
                    if not state.standby_logged then
                        F.log("Tidak ada aktivitas (" .. growing .. " pohon tumbuh). Diam & scan tiap " .. C.idle_scan_sec .. " detik...")
                        state.standby_logged = true
                    end
                    local wait_end = getTime() + (C.idle_scan_sec * 1000)
                    while getTime() < wait_end do
                        F.process_pending_ui()
                        if state.paused or not F.check_safety() then break end
                        sleep(100)
                    end
                end
            else
                state.standby_logged = false
                local h, p, pnb_ok = 0, 0, true
                if F.inv(C.seed_id) >= C.plant_first_min then
                    F.guarded(function() p = p + F.plant() end)
                end
                F.guarded(function() h = F.harvest() end)
                F.guarded(function() pnb_ok = F.pnb() end)

                if not pnb_ok and not state.paused then
                    F.log("Bot dijeda otomatis karena PNB terhalang. Atur ulang posisi di /menu.")
                    state.paused = true
                else
                    F.guarded(function() p = p + F.plant() end)
                    cycles = cycles + 1
                    if h > 0 or p > 0 then
                        F.log("Siklus #" .. cycles .. " selesai (Harvest: " .. h .. ", Plant: " .. p .. ")")
                    end
                end
                if cycles % 5 == 0 then collectgarbage("collect") end
            end
        end
    end
end

runThread(function() F.guarded(F.main) end)
