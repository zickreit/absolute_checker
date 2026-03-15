-- absolute_checker.lua – финальная версия с автообновлением и встроенным changelog

local copas = require('copas')
local http = require('copas.http')
local json = require('dkjson')
local encoding = require('encoding')
local imgui = require('mimgui')
local samp_events = require('samp.events')
local lfs = require('lfs')
local fa = require('fAwesome5')
local bit = require('bit')
local ffi = require('ffi')
local ltn12 = require('ltn12')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- Версия скрипта
local CURRENT_VERSION = "0.5.5"

-- Встроенный список изменений (changelog)
local CHANGELOG = {
    { version = "0.5.4", changes = "- Добавлена команду /admsettings, для открытия меню\n- Исправлен баг с разрешением игры\n Теперь отображаются события выпуска из читмира" }, 
    { version = "0.5.4", changes = "- Изменена начальную прозрачность окна: с 50 на 80"},
    { version = "0.5.3", changes = "- Версия для проверки работы автообновления скрипта"},
    { version = "0.5.2", changes = "- Автообновление без внешних файлов\n- Исправлена ошибка с TreeNode\n- Улучшена стабильность" },
    { version = "0.5.1", changes = "- Первая версия с автообновлением\n- База админов обновляется автоматически" }
}

-- Настройки
local DATA_FOLDER = getWorkingDirectory() .. "\\config\\admin_data\\"
local SERVER_IPS = "185.71.66.21"
local SERVERS = {
    Platinum = { port = 7771, url = "https://sa-mp.ru/adminhistory-platinum" },
    Titanium = { port = 7772, url = "https://sa-mp.ru/adminhistory-titanium" },
    Chromium = { port = 7773, url = "https://sa-mp.ru/adminhistory-chromium" },
    Aurum    = { port = 7774, url = "https://sa-mp.ru/adminhistory-aurum" },
    Lithium  = { port = 7775, url = "https://sa-mp.ru/adminhistory-litium" },
    Test     = { port = 7111, url = nil}
}

-- Фиксированные параметры репозитория
local GITHUB_REPO = "zickreit/absolute_checker"
local GITHUB_BRANCH = "main"

local default_settings = {
    font_size_main = 14,
    font_size_icon = 14,
    font_size_title = 14,
    window_width = 250,
    window_pos_x = 1780,
    window_pos_y = 530,
    window_alpha = 0.8,
    colored_nicks = true,
    afk_check_interval = 1,
    afk_dialog_delay = 10,
    ping_check = true,
    admin_base_interval = 10,      -- минут
    chat_alerts_interval = 5,      -- секунд
    days_to_keep_admins = 14,      -- дней
    recent_activity_threshold = 180,
    enable_chat_alerts = true,
    last_admin_update_time = os.time(),
    view_mode = 1,                  -- 1 все, 2 не AFK, 3 активные, 4 активные не AFK
}

local settings = {}
local settings_file = DATA_FOLDER .. "settings.json"

local function getServerFolder(server_key)
    return DATA_FOLDER .. server_key .. "\\"
end

local function ensureFolder()
    if not lfs.attributes(DATA_FOLDER) then lfs.mkdir(DATA_FOLDER) end
    for key, _ in pairs(SERVERS) do
        local subfolder = getServerFolder(key)
        if not lfs.attributes(subfolder) then lfs.mkdir(subfolder) end
    end
end

local function load_settings()
    local f = io.open(settings_file, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local loaded = json.decode(content)
        if loaded then
            for k, v in pairs(default_settings) do
                settings[k] = loaded[k] ~= nil and loaded[k] or v
            end
        else
            settings = default_settings
        end
    else
        settings = default_settings
    end
end

local function save_settings()
    local f = io.open(settings_file, "w")
    if f then
        f:write(json.encode(settings, { indent = true }))
        f:close()
    end
end

ensureFolder()
load_settings()

-- Состояние
local admins_db = {}               -- { server_key = { nick1 = true, ... } }  (ключи в CP1251)
local current_server_key = nil
local online_admins = {}
local is_updating = false
local last_admin_update = 0        -- время последнего обновления базы админов
local last_chat_check = {}         -- для каждого сервера храним первую запись последней проверки
local last_chat_check_time = 0     -- время последней проверки чата (сек)
local dialog_delay = 0

-- AFK статусы
local afk_status = {}              -- [playerId] = { afk = boolean, minutes, seconds, total }

-- Последняя активность админов (timestamp)
local last_activity = {}            -- [server_key][nick] = timestamp

-- ImGui
local show_window = imgui.new.bool(true)
local show_settings = imgui.new.bool(false)
local show_history = imgui.new.bool(false)
local selected_admin = { nick = "", actions = {}, loading = false, last_loaded_nick = nil }
local history_year = imgui.new.int(os.date("*t").year)
local history_month = imgui.new.int(os.date("*t").month)
local history_count = imgui.new.int(5000)
local history_search = imgui.new.char[256]("")

-- Шрифты
local font_main, font_icon, font_title, font_settings_font

-- Флаги
local auto_afk_check_active = false
local start_quest = false
local big_ping = false
local view_mode_icon_color = { [1]=imgui.ImVec4(1,1,1,1), [2]=imgui.ImVec4(0,1,0,1), [3]=imgui.ImVec4(1,1,0,1), [4]=imgui.ImVec4(1,0,0,1) }

-- Таймеры
local last_afk_check = os.time()
local last_chat_check_time = os.time()

-- Нормализация ника
local function normalizeNick(nick)
    local normalized = nick:gsub("%s*{.-}$", "")
    normalized = normalized:gsub(" ", "_")
    return normalized
end

-- Парсинг даты из строки (пример: "13 марта 2026, в 19:58:34")
local function parse_timestamp(date_str)
    date_str = u8:decode(date_str)
    local day, month_word, year, hour, min, sec = date_str:match("(%d+) (%S+) (%d+), в (%d+):(%d+):(%d+)")
    if not day then return os.time() end
    local month_map = {
        ["января"]=1, ["февраля"]=2, ["марта"]=3, ["апреля"]=4, ["мая"]=5, ["июня"]=6,
        ["июля"]=7, ["августа"]=8, ["сентября"]=9, ["октября"]=10, ["ноября"]=11, ["декабря"]=12
    }
    local month = month_map[month_word:lower()] or 1
    local timestamp = os.time({ 
        year = tonumber(year), 
        month = month, 
        day = tonumber(day),
        hour = tonumber(hour), 
        min = tonumber(min), 
        sec = tonumber(sec) 
    })
    return timestamp
end

-- Асинхронное выполнение POST-запроса к сайту
local function fetch_page(server_key, year, month, count, search, callback)
    copas.addthread(function()
        local url = SERVERS[server_key].url
        local postData = string.format("year=%d&month=%d&count=%d&searchtext=%s", year, month, count, search or "")
        local response_body = {}
        local success, res, code = pcall(http.request, {
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
                ["Content-Length"] = #postData,
            },
            source = ltn12.source.string(postData),
            sink = ltn12.sink.table(response_body)
        })
        if not success then
            callback(nil, 0)
            return
        end
        local html = table.concat(response_body)
        if code ~= 200 or not html then
            callback(nil, code)
            return
        end
        local ok, converted = pcall(function()
            return encoding.UTF8:decode(html):encode('CP1251')
        end)
        if ok then html = converted end
        local actions = {}
        local table_content = html:match("<table>(.-)</table>")
        if table_content then
            for row in table_content:gmatch("<tr>(.-)</tr>") do
                local date, action = row:match("<td>(.-)</td><td>(.-)</td>")
                if date and action and not date:find("Дата") then
                    table.insert(actions, { date = date, action = action })
                end
            end
        end
        callback(actions, code)
    end)
end

-- Получение первой записи страницы (для отслеживания новых)
local function get_first_entry(server_key, year, month, callback)
    fetch_page(server_key, year, month, 1, "", function(actions)
        if actions and #actions > 0 then
            callback(actions[1])
        else
            callback(nil)
        end
    end)
end

-- Обновление базы админов (сбор за последние N дней)
local function update_admins_database(server_key)
    if is_updating then return end
    is_updating = true
    copas.addthread(function()
        local now = os.time()
        local days = settings.days_to_keep_admins
        local cutoff = now - days * 24 * 3600
        local nicks = {}
        local activity = last_activity[server_key] or {}
        local current_year = os.date("*t", now).year
        local current_month = os.date("*t", now).month

        local months_to_check = {}
        local y, m = current_year, current_month
        while true do
            table.insert(months_to_check, { year = y, month = m })
            local first_day = os.time({ year = y, month = m, day = 1, hour = 0, min = 0, sec = 0 })
            if first_day < cutoff then break end
            m = m - 1
            if m < 1 then m = 12; y = y - 1 end
            if y < 2016 then break end
        end

        local total = #months_to_check
        if total == 0 then
            is_updating = false
            return
        end

        local completed = 0
        local function check_complete()
            completed = completed + 1
            if completed == total then
                -- сохраняем
                local set_cp = {}
                for nick, _ in pairs(nicks) do
                    set_cp[u8:encode(nick)] = true
                end
                admins_db[server_key] = set_cp
                last_activity[server_key] = activity

                local folder = getServerFolder(server_key)
                local admins_file = folder .. "admins.json"
                local f = io.open(admins_file, "w")
                if f then
                    f:write(json.encode(set_cp, { indent = true }))
                    f:close()
                end
                local activity_file = folder .. "activity.json"
                f = io.open(activity_file, "w")
                if f then
                    f:write(json.encode(activity, { indent = true }))
                    f:close()
                end

                print("[AdminChecker] База админов для " .. server_key .. " обновлена, найдено " .. table.size(nicks) .. " админов")
                is_updating = false
            end
        end

        for _, period in ipairs(months_to_check) do
            fetch_page(server_key, period.year, period.month, 4000, "", function(actions)
                if actions then
                    for _, entry in ipairs(actions) do
                        local ts = parse_timestamp(entry.date)
                        if ts >= cutoff then
                            local decoded = u8:decode(entry.action)
                            local nick = decoded:match("Админ%s+([^%[%s]+)") or decoded:match("Администратор%s+([^%[%s]+)") or decoded:match("Admin%s+([^%[%s]+)")
                            if nick then
                                local normalized = normalizeNick((nick))
                                nicks[normalized] = true
                                if not activity[normalized] or activity[normalized] < ts then
                                    activity[normalized] = ts
                                end
                            end
                        end
                    end
                end
                check_complete()
            end)
        end
    end)
end

-- Проверка новых записей (читмир и др.)
local function check_new_chat_alerts(server_key)
    if not settings.enable_chat_alerts then return end
    copas.addthread(function()
        local now = os.time()
        local current_year = os.date("*t", now).year
        local current_month = os.date("*t", now).month
        get_first_entry(server_key, current_year, current_month, function(first_entry)
            if not first_entry then return end

            local last = last_chat_check[server_key]
            if not last then
                last_chat_check[server_key] = first_entry
                return
            end

            if first_entry.date ~= last.date or first_entry.action ~= last.action then
                fetch_page(server_key, current_year, current_month, 4000, "", function(actions)
                    if actions then
                        local last_ts = parse_timestamp(last.date)
                        local new_actions = {}
                        for _, act in ipairs(actions) do
                            local ts = parse_timestamp(act.date)
                            if ts > last_ts then
                                table.insert(new_actions, act)
                            end
                        end
                        for _, act in ipairs(new_actions) do
                            local low_act = u8:decode(act.action:lower())
                            if low_act:find("читмир") or low_act:find("читерский мир") or low_act:find("читерского мира") then
                                sampAddChatMessage(u8:decode(act.date) .. ': ' .. u8:decode(act.action), 0xFFA500)
                            end
                        end
                    end
                end)
                last_chat_check[server_key] = first_entry
            end
        end)
    end)
end

-- Получение истории конкретного админа (асинхронно)
local function fetch_admin_history(server_key, nick, year, month, count, callback)
    fetch_page(server_key, year, month, count, u8:encode(nick), function(actions)
        if not actions then
            callback({})
            return
        end
        local result = {}
        local nick_cp = u8:encode(nick)
        for _, act in ipairs(actions) do
            if act.action:find(nick_cp, 1, true) then
                table.insert(result, act)
            end
        end
        callback(result)
    end)
end

-- Обновление всех баз (по таймеру) – запускается параллельно
function update_all_bases()
    for key, _ in pairs(SERVERS) do
        update_admins_database(key)
    end
end

-- Определение сервера
function detectServer(ip, port)
    if ip ~= SERVER_IPS then return nil end
    for key, data in pairs(SERVERS) do
        if data.port == port then
            return key
        end
    end
    return nil
end

local dialog_active = false
local start_quest_dialogs = { 20201, 20202, 20203, 20204, 20205, 20206, 20207, 20208, 20209, 20210, 20211, 20216 }
-- Обработка диалогов
function samp_events.onShowDialog(dialogId, style, title, button1, button2, text)
    dialog_active = true
    for _, i in pairs(start_quest_dialogs) do
        if i == dialogId then
            start_quest = true
            break
        end
    end
    if dialogId == 20221 then
        start_quest = false
    elseif dialogId == 500 and current_server_key then
        local playerId = title:match("%[(%d+)%]")
        if playerId then
            playerId = tonumber(playerId)
            local minutes, seconds
            if title:find("Отошёл") then
                local m, s = title:match("Отошёл (%d+)м:(%d+)с")
                if m and s then
                    minutes = tonumber(m)
                    seconds = tonumber(s)
                else
                    s = title:match("Отошёл (%d+)с")
                    if s then
                        seconds = tonumber(s)
                        minutes = 0
                    end
                end
                if minutes or seconds then
                    afk_status[playerId] = {
                        afk = true,
                        minutes = minutes or 0,
                        seconds = seconds or 0,
                        total = (minutes or 0)*60 + (seconds or 0)
                    }
                else
                    afk_status[playerId] = { afk = true, minutes = 0, seconds = 0, total = 0 }
                end
            else
                afk_status[playerId] = { afk = false, minutes = 0, seconds = 0, total = 0 }
            end
        end
        if auto_afk_check_active then
            dialog_active = false
            return false
        end
    end
    dialog_active = false
    local new_title = ('ID: %d | %s'):format(dialogId, title)
    return {dialogId, style, new_title, button1, button2, text}
end

local textdraws = {39, 47, 48, 43, 42, 49, 162, 2090}

function isTextdrawActive()
    for _, td in ipairs(textdraws) do
        if sampTextdrawIsExists(td) then
            return true
        end
    end
    return false
end

-- Проверка AFK
function checkAfkForAdmins()
    if auto_afk_check_active or not current_server_key or (not admins_db[current_server_key] and current_server_key ~= "Test") then 
        return false 
    end
    auto_afk_check_active = true
    local success, result = pcall(function()
        for _, adm in ipairs(online_admins) do
            if start_quest then
                return false
            end
            if sampIsDialogActive() or isTextdrawActive() or dialog_active then
                return false
            end
            local myPing = sampGetPlayerPing(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))) or 0
            big_ping = myPing > 100 and true or false
            local extraDelay = settings.ping_check and myPing or 0
            wait(extraDelay)
            if sampIsDialogActive() or isTextdrawActive() or dialog_active then
                return false
            end
            dialog_active = true
            sampSendClickPlayer(adm.id, 0)
            local timeout = 0
            repeat wait(0); timeout = timeout + 1 until not dialog_active or timeout > 200
            if timeout > 200 then
                sampAddChatMessage(adm.name, 0xFF0000)
                sampAddChatMessage("[AdminChecker]: Диалог не появился. Timeout...", 0xFF0000)
                return false
            end
            wait(settings.afk_dialog_delay)
        end
        return true
    end)
    auto_afk_check_active = false
    if success then
        return result
    else
        return false
    end
end

-- Подключение к серверу
function samp_events.onSendClientJoin(ver, mod, nick, response, authkey, clientver, unk)
    local ip, port = sampGetCurrentServerAddress()
    local key = detectServer(ip, port)
    if key then
        current_server_key = key
        update_admins_database(key)
        settings.last_admin_update_time = os.time()
        save_settings()
        last_chat_check[key] = nil
    end
end

function samp_events.onSendClickPlayer(playerId, source)
    auto_afk_check_active = false
    lua_thread.create(function()
        eshoRaz(playerId)
    end)
end

function eshoRaz(id)
    wait(200 + sampGetPlayerPing(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))))
    sampSendClickPlayer(id, 0)
end

-- ========== СИСТЕМА АВТООБНОВЛЕНИЯ (без внешних файлов) ==========

local function get_github_raw_url(file)
    local base = "https://raw.githubusercontent.com/" .. GITHUB_REPO .. "/" .. GITHUB_BRANCH .. "/"
    return base .. file
end

local function github_request(url, callback)
    copas.addthread(function()
        local response_body = {}
        local success, ok, response_code = pcall(http.request, {
            url = url,
            sink = ltn12.sink.table(response_body)
        })
        if not success then
            callback(nil, 0, tostring(ok))
            return
        end
        if not ok then
            callback(nil, response_code or 0, table.concat(response_body))
            return
        end
        local content = table.concat(response_body)
        if response_code ~= 200 then
            callback(nil, response_code, content)
            return
        end
        callback(content, response_code)
    end)
end

-- Извлекает версию из содержимого Lua-файла
local function extract_version_from_script(content)
    local version_pattern = 'CURRENT_VERSION%s*=%s*"([^"]+)"'
    return content:match(version_pattern)
end

-- Проверяет версию и при необходимости обновляется
function check_for_updates(manual)
    local script_url = get_github_raw_url("absolute_checker.lua")
    if not script_url then
        if manual then sampAddChatMessage("[AdminChecker] Ошибка: не удалось сформировать URL.", 0xFF0000) end
        return
    end
    if manual then sampAddChatMessage("[AdminChecker] Проверяю обновления...", 0xAAAAAA) end
    github_request(script_url, function(content, code, err)
        if code == 200 and content then
            local remote_version = extract_version_from_script(content)
            if remote_version and remote_version ~= CURRENT_VERSION then
                sampAddChatMessage(string.format("[AdminChecker] Найдена новая версия: %s (текущая %s)", remote_version, CURRENT_VERSION), 0x00FF00)
                -- Конвертируем в CP1251 и сохраняем
                local ok, converted = pcall(function()
                    return u8:decode(content)
                end)
                if not ok or not converted then
                    sampAddChatMessage("[AdminChecker] Ошибка преобразования кодировки.", 0xFF0000)
                    return
                end
                local temp_file = DATA_FOLDER .. "update_temp.lua"
                local f = io.open(temp_file, "w")
                if f then
                    f:write(converted)
                    f:close()
                    local current_script = thisScript().path
                    -- Удаляем текущий скрипт
                    local removed, err_rem = os.remove(current_script)
                    if not removed then
                        sampAddChatMessage("[AdminChecker] Не удалось удалить текущий скрипт: " .. tostring(err_rem), 0xFF0000)
                        return
                    end
                    local success, err_ren = os.rename(temp_file, current_script)
                    if success then
                        sampAddChatMessage("[AdminChecker] Обновление загружено. Перезагружаю скрипт...", 0x00FF00)
                        wait(1000)
                        thisScript():reload()
                    else
                        sampAddChatMessage("[AdminChecker] Ошибка переименования файла: " .. tostring(err_ren), 0xFF0000)
                    end
                else
                    sampAddChatMessage("[AdminChecker] Не удалось создать временный файл.", 0xFF0000)
                end
            else
                if manual then sampAddChatMessage("[AdminChecker] У вас актуальная версия.", 0x00FF00) end
            end
        else
            if manual then
                sampAddChatMessage(string.format("[AdminChecker] Не удалось проверить обновления. Код: %s", tostring(code)), 0xFF0000)
                if err and err ~= "" then sampAddChatMessage("Ошибка: " .. err, 0xFF0000) end
            end
        end
    end)
end

-- Регистрация команд
sampRegisterChatCommand("checkupdate", function()
    check_for_updates(true)
end)

-- =============================================

-- Главная функция
function main()
    while not isSampAvailable() do wait(0) end
    wait(100)

    for key, _ in pairs(SERVERS) do
        local folder = getServerFolder(key)
        local admins_file = folder .. "admins.json"
        local f = io.open(admins_file, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local data = json.decode(content)
            if data then admins_db[key] = data end
        end
        local activity_file = folder .. "activity.json"
        f = io.open(activity_file, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local data = json.decode(content)
            if data then last_activity[key] = data end
        end
    end

    local ip, port = sampGetCurrentServerAddress()
    if ip and ip ~= "" then
        current_server_key = detectServer(ip, port)
    end

    sampRegisterChatCommand("updadmins", function() update_all_bases() end)
    sampRegisterChatCommand("reloadscript", function() thisScript():reload() end)

    -- Автоматическая проверка обновлений при старте
    lua_thread.create(function()
        check_for_updates(false)
    end)

    while true do
        copas.step(0)

        -- Обновление онлайн-админов (с фильтром по view_mode)
        if sampGetGamestate() == 3 and current_server_key and admins_db[current_server_key] then
            local admin_set = admins_db[current_server_key]
            local new_online = {}
            for i = 0, sampGetMaxPlayerId(false) do
                if sampIsPlayerConnected(i) then
                    local name = sampGetPlayerNickname(i)
                    local normalized = normalizeNick(name)
                    
                    if admin_set[u8(normalized)] then
                        local afk = afk_status[i]
                        local last_act = last_activity[current_server_key] and last_activity[current_server_key][normalized]
                        local now = os.time()
                        local active = last_act and (now - last_act <= settings.recent_activity_threshold * 60)
                        local include = false
                        if settings.view_mode == 1 then include = true
                        elseif settings.view_mode == 2 then include = (not afk or not afk.afk)
                        elseif settings.view_mode == 3 then include = active
                        elseif settings.view_mode == 4 then include = active and (not afk or not afk.afk)
                        end
                        if include then
                            table.insert(new_online, {
                                id = i,
                                name = name,
                                afk = afk and afk.afk,
                                minutes = afk and afk.minutes,
                                seconds = afk and afk.seconds,
                                total = afk and afk.total,
                                last_activity = last_act,
                                active = active
                            })
                        end
                    end
                end
            end
            online_admins = new_online
        elseif sampGetGamestate() == 3 and current_server_key == "Test" then
            local new_online = {}
            for i = 0, sampGetMaxPlayerId(false) do
                if sampIsPlayerConnected(i) then
                    local name = sampGetPlayerNickname(i)
                    local normalized = normalizeNick(name)
                    local afk = afk_status[i]
                    local include = false
                    if settings.view_mode == 1 then include = true
                    elseif settings.view_mode == 2 then include = (not afk or not afk.afk)
                    elseif settings.view_mode == 3 then include = active
                    elseif settings.view_mode == 4 then include = active and (not afk or not afk.afk)
                    end
                    if include then
                        table.insert(new_online, {
                            id = i,
                            name = name,
                            afk = afk and afk.afk,
                            minutes = afk and afk.minutes,
                            seconds = afk and afk.seconds,
                            total = afk and afk.total,
                            last_act = nil,
                            active = nil
                        })
                    end
                end
            end
            online_admins = new_online
        else
            online_admins = {}
        end

        -- Определение сервера, если не определён
        if current_server_key == nil then
            local ip, port = sampGetCurrentServerAddress()
            local key = detectServer(ip, port)
            if key then
                current_server_key = key
                online_admins = {}
            end
            afk_status = {}
            auto_afk_check_active = false
            start_quest = false
            dialog_active = false
            last_afk_check = os.time()
        end

        -- Сброс dialog_active
        if not sampIsDialogActive() and not auto_afk_check_active then
            dialog_active = false
        end

        -- AFK проверка по таймеру
        if current_server_key and sampGetPlayerScore(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))) > 0 then
            if settings.afk_check_interval > 0 and os.time() - last_afk_check >= settings.afk_check_interval then
                if not start_quest and not dialog_active and not auto_afk_check_active then
                    if not sampIsDialogActive() and not isTextdrawActive() and os.time() - dialog_delay >= 5 then
                        lua_thread.create(function()
                            if checkAfkForAdmins() then
                                last_afk_check = os.time()
                            end
                        end)
                    else
                        if sampIsDialogActive() or isTextdrawActive() then
                            dialog_delay = os.time()
                        end
                    end
                end
            end
        end

        -- Обновление базы админов по таймеру (в минутах)
        if current_server_key and os.time() - settings.last_admin_update_time >= settings.admin_base_interval * 60 then
            settings.last_admin_update_time = os.time()
            save_settings()
            lua_thread.create(function() update_admins_database(current_server_key) end)
        end

        -- Проверка новых записей в чат (каждые settings.chat_alerts_interval секунд)
        if current_server_key and settings.enable_chat_alerts and os.time() - last_chat_check_time >= settings.chat_alerts_interval then
            last_chat_check_time = os.time()
            lua_thread.create(function() check_new_chat_alerts(current_server_key) end)
        end

        wait(10)
    end
end

-- Инициализация шрифтов
imgui.OnInitialize(function()
    themeExample()
    imgui.GetIO().IniFilename = nil

    local glyph_ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    local config = imgui.ImFontConfig()
    local iconRanges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)

    config.MergeMode = true
    font_settings_font = imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', 14, nil, glyph_ranges)
    font_main = imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', settings.font_size_main, nil, glyph_ranges)
    font_icon = imgui.GetIO().Fonts:AddFontFromFileTTF('moonloader/resource/fonts/fa-solid-900.ttf', settings.font_size_icon, config, iconRanges)
    font_title = imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', settings.font_size_title, nil, glyph_ranges)
end)

local cogColor = imgui.ImVec4(1,1,1,1)

-- Основное окно
imgui.OnFrame(function() return show_window[0] end, function(this)
    this.HideCursor = true

    imgui.SetNextWindowPos(imgui.ImVec2(settings.window_pos_x, settings.window_pos_y), imgui.Cond.Always, imgui.ImVec2(0.5, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(settings.window_width, 0), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(settings.window_alpha)
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.AlwaysAutoResize

    if imgui.Begin("AdminOnline", show_window, flags) then
        imgui.PushFont(font_title)
        if current_server_key then
            local text = current_server_key == "Test" and u8("Игроки в сети") or u8("Админы в сети")
            imgui.TextColored(imgui.ImVec4(1,1,1,1), text)
            imgui.SameLine(imgui.CalcTextSize(text).x + 10)
            local server_color = { 
                ["Platinum"] = imgui.ImVec4(0.3,1,1,1), 
                ["Titanium"] = imgui.ImVec4(0.3,1,0.3,1), 
                ["Chromium"] = imgui.ImVec4(1,0.3,1,1), 
                ["Aurum"]    = imgui.ImVec4(1,1,0.3,1), 
                ["Lithium"]  = imgui.ImVec4(0.6,0.6,1,1),
                ["Test"]     = imgui.ImVec4(1,0.3,0.3,1)
            }
            imgui.TextColored(server_color[current_server_key], "(" .. current_server_key .. "):")
        else
            imgui.TextColored(imgui.ImVec4(1,0,0,1), u8("Сервер не определён"))
        end
        imgui.SameLine(settings.window_width - (settings.font_size_icon * 3))

        -- Иконка режима отображения
        imgui.PushFont(font_icon)
        local view_icon = fa.ICON_FA_EYE
        imgui.TextColored(view_mode_icon_color[settings.view_mode], view_icon)
        if imgui.IsItemClicked() then
            settings.view_mode = settings.view_mode % 4 + 1
            save_settings()
        end
        if imgui.IsItemHovered() then
            local tips = { "Все админы", "Только не в AFK", "Только активные", "Активные не в AFK" }
            ShowTooltip(u8(tips[settings.view_mode]))
        end
        imgui.SameLine(settings.window_width - (settings.font_size_icon * 1.5))

        -- Иконка настроек
        imgui.TextColored(cogColor, fa.ICON_FA_COG)
        if imgui.IsItemClicked() then
            cogColor = imgui.ImVec4(1,0.325,0.325,1)
            show_settings[0] = not show_settings[0]
        end
        if imgui.IsItemHovered() then
            cogColor = imgui.ImVec4(0.325,0.325,0.325,1)
        else
            cogColor = imgui.ImVec4(1,1,1,1)
        end
        imgui.PopFont()
        imgui.PopFont()

        imgui.Separator()
        imgui.PushFont(font_main)
        if #online_admins == 0 then
            imgui.TextDisabled(u8("Никого нет"))
        else
            for _, adm in ipairs(online_admins) do
                local displayName = normalizeNick(adm.name)
                local utf8_text = string.format("[%d] %s", adm.id, u8(displayName))
                local color
                if settings.colored_nicks then
                    local r, g, b = hexToRGB(sampGetPlayerColor(adm.id))
                    color = (adm.afk and settings.afk_check_interval ~= 0) and imgui.ImVec4(r, g, b, 0.4) or imgui.ImVec4(r, g, b, 1.0)
                else
                    color = (adm.afk and settings.afk_check_interval ~= 0) and imgui.ImVec4(0.5, 0.5, 0.5, 0.5) or imgui.ImVec4(1, 1, 1, 1)
                end
                imgui.PushStyleColor(imgui.Col.Text, color)
                if imgui.Selectable(utf8_text) then
                    auto_afk_check_active = false
                    sampSendClickPlayer(adm.id, 0)
                    if current_server_key ~= "Test" then
                        selected_admin.nick = displayName
                        selected_admin.actions = {}
                        selected_admin.loading = false
                        show_history[0] = true
                    end
                end
                imgui.PopStyleColor()
                local text_size = imgui.CalcTextSize(utf8_text)
                if adm.last_activity then
                    local now = os.time()
                    local diff = now - adm.last_activity
                    if diff <= settings.recent_activity_threshold * 60 then
                        text_size.x = text_size.x + 10
                        imgui.SameLine(text_size.x)
                        if adm.afk and settings.afk_check_interval ~= 0 then
                            imgui.TextColored(imgui.ImVec4(0,1,0,0.5), "[!]")
                        else
                            imgui.TextColored(imgui.ImVec4(0,1,0,1), "[!]")
                        end
                    end
                end
                if adm.afk and settings.afk_check_interval ~= 0 then
                    imgui.SameLine(text_size.x + 10)
                    if adm.minutes and adm.minutes > 0 then
                        imgui.TextColored(imgui.ImVec4(0.6,0.325,0.325,1), "| AFK: " .. adm.minutes .. u8("м ") .. adm.seconds .. u8("с"))
                    elseif adm.seconds and adm.seconds > 0 then
                        imgui.TextColored(imgui.ImVec4(0.6,0.325,0.325,1), "| AFK: " .. adm.seconds .. u8("с"))
                    else
                        imgui.TextColored(imgui.ImVec4(0.6,0.325,0.325,1), "| AFK")
                    end
                end
            end
        end
        if is_updating then
            imgui.Separator()
            imgui.TextColored(imgui.ImVec4(1,1,0,1), u8("Обновление базы..."))
        end
        if start_quest then
            imgui.Separator()
            imgui.TextColored(imgui.ImVec4(0,1,0,1), u8("Не мешаем начальному квесту..."))
        end
        if os.time() - dialog_delay <= 5 or sampIsDialogActive() then
            imgui.Separator()
            if os.time() - dialog_delay == 0 or os.time() - dialog_delay == 1 then
                imgui.TextColored(imgui.ImVec4(1,0.3,0.3,0.6), u8("Открыт диалог. АФК не проверяется"))
            else
                imgui.TextColored(imgui.ImVec4(1,0.3,0.3,0.6), u8("Задержка после диалогов: ") .. (os.time() - dialog_delay) - 1 .. u8(" с"))
            end
        end
        if os.time() - last_afk_check >= 10 then
            imgui.Separator()
            imgui.TextColored(imgui.ImVec4(1,0,0,0.8), u8("Последнее обновление АФК: ") .. os.time() - last_afk_check .. u8(" с"))
        end
        if big_ping then
            imgui.Separator()
            imgui.TextColored(imgui.ImVec4(1,0,0,1), u8("Большой пинг (Могут быть баги)"))
        end
        imgui.End()
    end
end)

-- Окно истории с асинхронной загрузкой
imgui.OnFrame(function() return show_history[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw/2, 400), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 1))
    imgui.SetNextWindowSize(imgui.ImVec2(600, 400), imgui.Cond.FirstUseEver)
    if imgui.Begin(u8("История: ") .. u8(selected_admin.nick), show_history) then
        imgui.Text(u8("Параметры запроса:"))
        imgui.PushItemWidth(100)
        imgui.SameLine(); imgui.InputInt(u8("Год"), history_year, 1, 100)
        imgui.SameLine(); imgui.InputInt(u8("Месяц"), history_month, 1, 12)
        imgui.SameLine(); imgui.InputInt(u8("Кол-во"), history_count, 10, 5000)
        imgui.PopItemWidth()
        imgui.InputTextWithHint("##search", u8("Поиск по тексту"), history_search, 256)
        if imgui.Button(u8("Загрузить")) then
            if current_server_key and selected_admin.nick ~= "" then
                selected_admin.loading = true
                selected_admin.actions = {}
                fetch_admin_history(current_server_key, selected_admin.nick, history_year[0], history_month[0], history_count[0],
                    function(actions)
                        selected_admin.actions = actions
                        selected_admin.loading = false
                        selected_admin.last_loaded_nick = selected_admin.nick
                    end
                )
            end
        end
        imgui.Separator()
        imgui.BeginChild("##actions_scroll")
        if selected_admin.loading then
            imgui.Text(u8("Загрузка..."))
        else
            -- Автоматическая загрузка при первом открытии или смене ника
            if current_server_key and selected_admin.nick ~= "" and (not selected_admin.last_loaded_nick or selected_admin.last_loaded_nick ~= selected_admin.nick) then
                lua_thread.create(function()
                    selected_admin.loading = true
                    selected_admin.actions = {}
                    fetch_admin_history(current_server_key, selected_admin.nick, history_year[0], history_month[0], history_count[0],
                        function(actions)
                            selected_admin.actions = actions
                            selected_admin.loading = false
                            selected_admin.last_loaded_nick = selected_admin.nick
                        end
                    )
                end)
            end
            local filter = ffi.string(history_search)
            for _, act in ipairs(selected_admin.actions) do
                local action_utf8 = u8:decode(u8(act.action))
                if filter == "" or action_utf8:lower():find(filter:lower(), 1, true) then
                    imgui.TextDisabled(act.date)
                    imgui.TextWrapped(action_utf8)
                    imgui.Separator()
                end
            end
        end
        imgui.EndChild()
        imgui.End()
    end
end)

-- Окно настроек
imgui.OnFrame(function() return show_settings[0] end, function()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 1))
    imgui.SetNextWindowSize(imgui.ImVec2(560, 0), imgui.Cond.Always)
    imgui.PushFont(font_settings_font)
    if imgui.Begin(u8("Настройки AdminChecker"), show_settings, imgui.WindowFlags.NoCollapse) then
        imgui.PushItemWidth(320)
        local changed = false

        if imgui.CollapsingHeader(u8("Внешний вид")) then
            local val_font_main = imgui.new.int(settings.font_size_main)
            if imgui.SliderInt(u8("Размер основного шрифта"), val_font_main, 8, 24) then
                settings.font_size_main = val_font_main[0]
                changed = true
            end

            local val_font_icon = imgui.new.int(settings.font_size_icon)
            if imgui.SliderInt(u8("Размер шрифта иконок"), val_font_icon, 8, 24) then
                settings.font_size_icon = val_font_icon[0]
                changed = true
            end

            local val_font_title = imgui.new.int(settings.font_size_title)
            if imgui.SliderInt(u8("Размер заголовка"), val_font_title, 8, 24) then
                settings.font_size_title = val_font_title[0]
                changed = true
            end

            local val_width = imgui.new.int(settings.window_width)
            if imgui.SliderInt(u8("Ширина окна"), val_width, 150, 500) then
                settings.window_width = val_width[0]
                changed = true
            end

            local val_pos_x = imgui.new.int(settings.window_pos_x)
            if imgui.SliderInt(u8("Позиция X"), val_pos_x, 0, 1920) then
                settings.window_pos_x = val_pos_x[0]
                changed = true
            end

            local val_pos_y = imgui.new.int(settings.window_pos_y)
            if imgui.SliderInt(u8("Позиция Y"), val_pos_y, 0, 1080) then
                settings.window_pos_y = val_pos_y[0]
                changed = true
            end

            local val_alpha = imgui.new.float(settings.window_alpha)
            if imgui.SliderFloat(u8("Прозрачность окна"), val_alpha, 0.1, 1.0, "%.2f") then
                settings.window_alpha = val_alpha[0]
                changed = true
            end

            local val_colored = imgui.new.bool(settings.colored_nicks)
            if imgui.Checkbox(u8("Цветные ники"), val_colored) then
                settings.colored_nicks = val_colored[0]
                changed = true
            end
            if imgui.Button(u8("Применить размеры шрифтов \n(ПЕРЕЗАГРУЗКА СКРИПТА)")) then
                thisScript():reload()
            end
        end

        if imgui.CollapsingHeader(u8("Интервалы и обработка")) then
            local val_afk = imgui.new.int(settings.afk_check_interval)
            if imgui.SliderInt(u8("Интервал AFK проверок (сек)"), val_afk, 0, 120) then
                settings.afk_check_interval = val_afk[0]
                changed = true
            end
            local val_afk_delay = imgui.new.int(settings.afk_dialog_delay)
            if imgui.SliderInt(u8("Задержка между диалогами (сек)"), val_afk_delay, 0, 200) then
                settings.afk_dialog_delay = val_afk_delay[0]
                changed = true
            end
            imgui.SameLine()
            imgui.TextQuestion("Чем меньше значение - тем больше багов с появляющимися диалогами")
            local val_ping_check = imgui.new.bool(settings.ping_check)
            if imgui.Checkbox(u8("Дополнительная задержка AFK (Меньше багов с диалогами)"), val_ping_check) then
                settings.ping_check = val_ping_check[0]
            end
            local val_admin_interval = imgui.new.int(settings.admin_base_interval)
            if imgui.SliderInt(u8("Обновление базы админов (мин)"), val_admin_interval, 1, 60) then
                settings.admin_base_interval = val_admin_interval[0]
                changed = true
            end
            local val_chat_interval = imgui.new.int(settings.chat_alerts_interval)
            if imgui.SliderInt(u8("Проверка читмир-сообщений (сек)"), val_chat_interval, 1, 60) then
                settings.chat_alerts_interval = val_chat_interval[0]
                changed = true
            end
            local val_days = imgui.new.int(settings.days_to_keep_admins)
            if imgui.SliderInt(u8("Порог бездействия админов (дни)"), val_days, 1, 60) then
                settings.days_to_keep_admins = val_days[0]
                changed = true
            end
            imgui.SameLine()
            imgui.TextQuestion("Сколько дней должен бездействовать админ, чтобы он перестал считатся админом (Не будет показываться в меню)")
            local val_recent = imgui.new.int(settings.recent_activity_threshold)
            if imgui.SliderInt(u8("Порог активности админа (мин)"), val_recent, 0, 360) then
                settings.recent_activity_threshold = val_recent[0]
                changed = true
            end
            local val_chat_alerts = imgui.new.bool(settings.enable_chat_alerts)
            if imgui.Checkbox(u8("Выводить читмир-сообщения в чат"), val_chat_alerts) then
                settings.enable_chat_alerts = val_chat_alerts[0]
                changed = true
            end
        end

        if imgui.CollapsingHeader(u8("Обновления")) then
            imgui.Text(u8("Текущая версия: ") .. CURRENT_VERSION)
            if imgui.Button(u8("Проверить обновления сейчас")) then
                lua_thread.create(function() check_for_updates(true) end)
            end
            imgui.Separator()
            imgui.Text(u8("История изменений:"))
            imgui.BeginChild("##changelog", imgui.ImVec2(0, 150))
            if #CHANGELOG == 0 then
                imgui.TextDisabled(u8("Нет данных"))
            else
                for _, entry in ipairs(CHANGELOG) do
                    if imgui.CollapsingHeader(u8(entry.version)) then
                        imgui.TextWrapped(u8(entry.changes or ""))
                    end
                end
            end
            imgui.EndChild()
        end

        if changed then
            save_settings()
        end

        imgui.Separator()
        if imgui.Button(u8("Закрыть")) then
            show_settings[0] = false
        end
        imgui.SameLine()
        imgui.TextDisabled(u8("Зажмите CTRL для более точной настройки / Ники в интерфейсе кликабельны"))
        imgui.TextColored(imgui.ImVec4(0,1,0,0.9), u8("[!]"))
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(1,1,1,1), u8("- означает, что админ был активен недавно, в заданном интервале"))
        imgui.End()
    end
    imgui.PopFont()
end)

function imgui.TextQuestion(text)
    imgui.TextDisabled('(?)')
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.PushTextWrapPos(450)
        imgui.TextUnformatted(u8(text))
        imgui.PopTextWrapPos()
        imgui.EndTooltip()
    end
end

function ShowTooltip(text)
    local mouse_pos = imgui.GetMousePos()
    local mouse_x = mouse_pos.x
    local mouse_y = mouse_pos.y
    local text_size = imgui.CalcTextSize(text)
    local text_w = text_size.x
    local text_h = text_size.y
    local io = imgui.GetIO()
    local display_w = io.DisplaySize.x
    local display_h = io.DisplaySize.y

    local tooltip_x = mouse_x
    local tooltip_y = mouse_y - 40

    if tooltip_x + (text_w + 20) > display_w then
        tooltip_x = mouse_x - text_w
    end
    if tooltip_y + text_h > display_h then
        tooltip_y = mouse_y - (text_h + 40)
    end
    if tooltip_x < 0 then tooltip_x = 0 end
    if tooltip_y < 0 then tooltip_y = 0 end

    local pos = imgui.ImVec2(tooltip_x, tooltip_y)
    imgui.SetNextWindowPos(pos)
    imgui.BeginTooltip()
    imgui.Text(text)
    imgui.EndTooltip()
end

function hexToRGB(hex)
    local r = bit.band(bit.rshift(hex, 16), 0xFF) / 255
    local g = bit.band(bit.rshift(hex, 8), 0xFF) / 255
    local b = bit.band(hex, 0xFF) / 255
    return r, g, b
end

function themeExample()
    local style = imgui.GetStyle();
    local colors = style.Colors;
    imgui.SwitchContext()
    style.ButtonTextAlign = imgui.ImVec2(0.50, 0.50);
    style.SelectableTextAlign = imgui.ImVec2(0.00, 0.00);
    colors[imgui.Col.Text] = imgui.ImVec4(1.00, 1.00, 1.00, 1.00);
    colors[imgui.Col.TextDisabled] = imgui.ImVec4(0.67, 0.62, 0.62, 1.00);
    colors[imgui.Col.WindowBg] = imgui.ImVec4(0.00, 0.00, 0.00, 1.00);
    colors[imgui.Col.ChildBg] = imgui.ImVec4(0.00, 0.00, 0.00, 1.00);
    colors[imgui.Col.PopupBg] = imgui.ImVec4(0.08, 0.08, 0.08, 0.94);
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.07, 0.08, 0.08, 1.00);
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.03, 0.03, 0.03, 0.40);
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.10, 0.10, 0.11, 0.67);
    colors[imgui.Col.TitleBg] = imgui.ImVec4(0.04, 0.04, 0.04, 1.00);
    colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.00, 0.00, 0.00, 1.00);
    colors[imgui.Col.TitleBgCollapsed] = imgui.ImVec4(0.00, 0.00, 0.00, 0.51);
    colors[imgui.Col.MenuBarBg] = imgui.ImVec4(0.14, 0.14, 0.14, 1.00);
    colors[imgui.Col.ScrollbarBg] = imgui.ImVec4(0.02, 0.02, 0.02, 0.53);
    colors[imgui.Col.ScrollbarGrab] = imgui.ImVec4(0.31, 0.31, 0.31, 1.00);
    colors[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(0.41, 0.41, 0.41, 1.00);
    colors[imgui.Col.ScrollbarGrabActive] = imgui.ImVec4(0.51, 0.51, 0.51, 1.00);
    colors[imgui.Col.CheckMark] = imgui.ImVec4(0.33, 0.42, 0.53, 1.00);
    colors[imgui.Col.SliderGrab] = imgui.ImVec4(0.32, 0.33, 0.35, 1.00);
    colors[imgui.Col.SliderGrabActive] = imgui.ImVec4(0.24, 0.26, 0.27, 1.00);
    colors[imgui.Col.Button] = imgui.ImVec4(0.25, 0.28, 0.32, 0.39);
    colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.17, 0.18, 0.20, 1.00);
    colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.21, 0.22, 0.24, 1.00);
    colors[imgui.Col.Header] = imgui.ImVec4(0.19, 0.21, 0.23, 0.31);
    colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.16, 0.17, 0.18, 0.80);
    colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.13, 0.15, 0.17, 1.00);
    colors[imgui.Col.ResizeGrip] = imgui.ImVec4(0.35, 0.37, 0.40, 0.25);
    colors[imgui.Col.ResizeGripHovered] = imgui.ImVec4(0.09, 0.10, 0.10, 0.67);
    colors[imgui.Col.ResizeGripActive] = imgui.ImVec4(0.10, 0.11, 0.12, 0.95);
    colors[imgui.Col.Tab] = imgui.ImVec4(0.07, 0.07, 0.08, 0.92);
    colors[imgui.Col.TabHovered] = imgui.ImVec4(0.05, 0.06, 0.06, 0.80);
    colors[imgui.Col.TabActive] = imgui.ImVec4(0.10, 0.10, 0.11, 1.00);
    colors[imgui.Col.TabUnfocused] = imgui.ImVec4(0.08, 0.09, 0.09, 0.97);
    colors[imgui.Col.TabUnfocusedActive] = imgui.ImVec4(0.13, 0.14, 0.16, 1.00);
    colors[imgui.Col.PlotLines] = imgui.ImVec4(0.61, 0.61, 0.61, 1.00);
    colors[imgui.Col.PlotLinesHovered] = imgui.ImVec4(0.24, 0.20, 0.20, 1.00);
    colors[imgui.Col.PlotHistogram] = imgui.ImVec4(0.90, 0.70, 0.00, 1.00);
    colors[imgui.Col.PlotHistogramHovered] = imgui.ImVec4(1.00, 0.60, 0.00, 1.00);
    colors[imgui.Col.TextSelectedBg] = imgui.ImVec4(0.32, 0.32, 0.35, 0.55);
    colors[imgui.Col.DragDropTarget] = imgui.ImVec4(1.00, 1.00, 0.00, 0.90);
    colors[imgui.Col.NavHighlight] = imgui.ImVec4(0.08, 0.09, 0.10, 1.00);
    colors[imgui.Col.NavWindowingHighlight] = imgui.ImVec4(1.00, 1.00, 1.00, 0.70);
    colors[imgui.Col.NavWindowingDimBg] = imgui.ImVec4(0.80, 0.80, 0.80, 0.20);
    colors[imgui.Col.ModalWindowDimBg] = imgui.ImVec4(0.80, 0.80, 0.80, 0.35);
end

function table.size(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end
