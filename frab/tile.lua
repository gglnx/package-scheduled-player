local api, CHILDS, CONTENTS = ...

local json = require "json"
local helper = require "helper"
local anims = require(api.localized "anims")

local font, info_font
local white = resource.create_colored_texture(1,1,1)
local fallback_track_background = resource.create_colored_texture(.5,.5,.5,1)

local schedule = {}
local tracks = {}
local rooms = {}
local next_talks = {}
local current_room
local current_talk
local other_talks = {}
local last_check_min = 0
local day = 0
local show_language_tags = true

local M = {}

util.data_mapper{
    [api.localized "day"] = function(new_day)
        day = new_day
    end;
}

function M.updated_config_json(config)
    font = resource.load_font(api.localized(config.font.asset_name))
    info_font = resource.load_font(api.localized(config.info_font.asset_name))
    show_language_tags = config.show_language_tags

    rooms = {}
    for idx, room in ipairs(config.rooms) do
        if room.serial == sys.get_env "SERIAL" then
            print("found my room")
            current_room = room
        end
        if room.name_short == "" then
            room.name_short = room.name
        end
        rooms[room.name] = room
    end

    if current_room then
        local info_lines = {}
        for line in string.gmatch(current_room.info.."\n", "([^\n]*)\n") do
            local split = string.find(line, ",")
            if not split then
                info_lines[#info_lines+1] = "splitter"
            else
                info_lines[#info_lines+1] = {
                    name = string.sub(line, 1, split-1),
                    value = string.sub(line, split+1),
                }
            end
        end
        current_room.info_lines = info_lines
    end

    tracks = {}
    for idx, track in ipairs(config.tracks) do
        tracks[track.name] = {
            name = track.name_short,
            background = resource.create_colored_texture(unpack(track.color.rgba)),
        }
    end
    pp(tracks)
end

function M.updated_schedule_json(new_schedule)
    print "new schedule"
    schedule = new_schedule
    for idx = #schedule, 1, -1 do
        local talk = schedule[idx]
        if not rooms[talk.place] then
            table.remove(schedule, idx)
        else
            if talk.lang ~= "" then
                if show_language_tags then
                    talk.title = talk.title .. " (" .. talk.lang .. ")"
                else
                    talk.title = talk.title
                end
            end

            talk.track = tracks[talk.track] or {
                name = talk.track,
                background = fallback_track_background,
            }
        end
    end
end

local function wrap(str, font, size, max_w)
    local lines = {}
    local space_w = font:width(" ", size)

    local remaining = max_w
    local line = {}
    for non_space in str:gmatch("%S+") do
        local w = font:width(non_space, size)
        if remaining - w < 0 then
            lines[#lines+1] = table.concat(line, "")
            line = {}
            remaining = max_w
        end
        line[#line+1] = non_space
        line[#line+1] = " "
        remaining = remaining - w - space_w
    end
    if #line > 0 then
        lines[#lines+1] = table.concat(line, "")
    end
    return lines
end

local function check_next_talk()
    local now = api.clock.unix()
    local check_min = math.floor(now / 60)
    if check_min == last_check_min then
        return
    end
    last_check_min = check_min
    
    -- Search all next talks
    next_talks = {}
    local room_next = {}
    for idx = 1, #schedule do
        local talk = schedule[idx]

        -- Find next talk
        if current_room and (current_room.group == "*" or current_room.group == talk.group) then
            if not room_next[talk.place] and 
                talk.start_unix > now - 25 * 60 then
                room_next[talk.place] = talk
            end
        end

        -- Just started?
        if now > talk.start_unix and 
           now < talk.end_unix and
           talk.start_unix + 15 * 60 > now
        then
           next_talks[#next_talks+1] = talk
        end

        -- Starting soon
        if talk.start_unix > now and #next_talks < 20 then
            next_talks[#next_talks+1] = talk
        end
    end

    if not current_room then
        return
    end

    -- Find current/next talk for my room
    current_talk = room_next[current_room.name]

    -- Prepare talks for other rooms
    other_talks = {}
    for room, talk in pairs(room_next) do
        if not current_talk or room ~= current_talk.place then
            other_talks[#other_talks + 1] = talk
        end
    end

    local function sort_talks(a, b)
        return a.start_unix < b.start_unix or (a.start_unix == b.start_unix and a.place < b.place)
    end
    table.sort(other_talks, sort_talks)
    print("found " .. #other_talks .. " other talks")
    pp(next_talks)
end

local function view_talk(talk, starts, ends, config, x1, y1, x2, y2)
    local font_size = config.font_size or 70
    local align = config.next_align or "left"
    local abstract = config.next_abstract
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local function info_text(...)
        return a.add(anims.moving_font(S, E, info_font, ...))
    end

    local x, y = 0, 0

    local col1, col2

    local time_size = font_size
    local relative_time_size = math.floor(font_size * 0.8)
    local title_size = math.floor(font_size * 0.9)
    local abstract_size = math.floor(font_size * 0.8)
    local speaker_size = math.floor(font_size * 0.8)

    local dummy = "in XXX Std."
    if align == "left" then
        col1 = 0
        col2 = 0 + info_font:width(dummy, time_size)
    else
        col1 = -info_font:width(dummy, time_size)
        col2 = 0
    end

    if not talk then
        text(col2, y, "Das war's.", time_size, r,g,b,1)
    else
        -- Time
        text(col1, y, talk.start_str, time_size, r,g,b,1)

        -- Delta
        local delta = talk.start_unix - api.clock.unix()
        local talk_time
        if delta > 180*60 then
            talk_time = string.format("in %d Std.", math.floor(delta/3600))
        elseif delta > 0 then
            talk_time = string.format("in %d Min.", math.floor(delta/60)+1)
        else
            talk_time = "Jetzt"
        end

        local y_time = y+time_size+20
        info_text(col1, y_time, talk_time, relative_time_size, r,g,b,0.8)

        -- Title
        local lines = wrap(talk.title, font, title_size, a.width - col2)
        for idx = 1, math.min(5, #lines) do
            text(col2, y, lines[idx], title_size, r,g,b,1)
            y = y + title_size
        end
        y = y + 20

        -- Abstract
        if abstract then
            local lines = wrap(talk.abstract, font, abstract_size, a.width - col2)
            for idx = 1, math.min(5, #lines) do
                text(col2, y, lines[idx], abstract_size, r,g,b,1)
                y = y + abstract_size
            end
            y = y + 20
        end

        -- Speakers
        for idx = 1, #talk.speakers do
            info_text(col2, y, talk.speakers[idx], speaker_size, r,g,b,.8)
            y = y + speaker_size
        end
    end

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_next_talk(starts, ends, config, x1, y1, x2, y2)
    view_talk(current_talk, starts, ends, config, x1, y1, x2, y2)
end

local function view_other_talks(starts, ends, config, x1, y1, x2, y2)
    view_talk(other_talks[1], starts, ends, config, x1, y1, x2, y2)
end

local function view_room_info(starts, ends, config, x1, y1, x2, y2)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local x, y = 0, 0

    local info_lines = current_room.info_lines

    local w = 0
    for idx = 1, #info_lines do 
        local line = info_lines[idx]
        w = math.max(w, font:width(line.name, font_size))
    end
    for idx = 1, #info_lines do 
        local line = info_lines[idx]
        if line == "splitter" then
            y = y + math.floor(font_size/2)
        else
            text(x, y, line.name, font_size, r,g,b,1)
            text(x + w + 40, y, line.value, font_size, r,g,b,1)
            y = y + font_size
        end
    end

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_all_talks(starts, ends, config, x1, y1, x2, y2)
    local title_size = config.font_size or 70
    local align = config.all_align or "left"
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local time_size = title_size
    local info_size = math.floor(title_size * 0.8)

    local split_x
    if align == "left" then
        split_x = font:width("In 60 min", title_size)*1.5
    else
        split_x = 0
    end

    local x, y = 0, 0

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    if #next_talks == 0 and #schedule > 0 and sys.now() > 30 then
        text(split_x, y, "No more talks :(", title_size, r,g,b,1)
    end

    local now = api.clock.unix()

    for idx = 1, #next_talks do
        local talk = next_talks[idx]

        local title_lines = wrap(
            talk.title,
            font, title_size, a.width - split_x
        )

        local info_lines = wrap(
            rooms[talk.place].name_short .. " with " .. table.concat(talk.speakers, ", "), 
            font, info_size, a.width - split_x
        )

        if y + #title_lines * title_size + info_size > a.height then
            break
        end

        -- time
        local time
        local til = talk.start_unix - now
        if til > -60 and til < 60 then
            time = "Now"
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, 0,.6,0.57,1)
        elseif til > 0 and til < 15 * 60 then
            time = string.format("In %d min", math.floor(til/60))
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, 0,.6,0.57,1)
        elseif talk.start_unix > now then
            time = talk.start_str
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, r,g,b,1)
        else
            time = string.format("%d min ago", math.ceil(-til/60))
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, r,g,b,.8)
        end

        -- title
        for idx = 1, #title_lines do
            text(x+split_x, y, title_lines[idx], title_size, r,g,b,1)
            y = y + title_size
        end
        y = y + 3

        -- info
        for idx = 1, #info_lines do
            text(x+split_x, y, info_lines[idx], info_size, r,g,b,.8)
            y = y + info_size
        end
        y = y + 20
    end

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_room(starts, ends, config, x1, y1, x2, y2)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    for now in api.frame_between(starts, ends) do
        local line = current_room.name_short
        info_font:write(x1, y1, line, font_size, r,g,b)
    end
end

local function view_day(starts, ends, config, x1, y1, x2, y2)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")
    local align = config.day_align or "left"
    local template = config.day_template or "Day %d"

    for now in api.frame_between(starts, ends) do
        local line = string.format(template, day)
        if align == "left" then
            info_font:write(x1, y1, line, font_size, r,g,b)
        elseif align == "center" then
            local w = info_font:width(line, font_size)
            info_font:write((x1+x2-w) / 2, y1, line, font_size, r,g,b)
        else
            local w = info_font:width(line, font_size)
            info_font:write(x2-w, y1, line, font_size, r,g,b)
        end
    end
end

local function view_clock(starts, ends, config, x1, y1, x2, y2)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")
    local align = config.clock_align or "left"

    for now in api.frame_between(starts, ends) do
        local line = api.clock.human()
        if align == "left" then
            info_font:write(x1, y1, line, font_size, r,g,b)
        elseif align == "center" then
            local w = info_font:width(line, font_size)
            info_font:write((x1+x2-w) / 2, y1, line, font_size, r,g,b)
        else
            local w = info_font:width(line, font_size)
            info_font:write(x2-w, y1, line, font_size, r,g,b)
        end
    end
end

function M.task(starts, ends, config, x1, y1, x2, y2)
    check_next_talk()
    return ({
        next_talk = view_next_talk,
        other_talks = view_other_talks,
        room_info = view_room_info,
        all_talks = view_all_talks,

        room = view_room,
        day = view_day,
        clock = view_clock,
    })[config.mode or 'all_talks'](starts, ends, config, x1, y1, x2, y2)
end

return M
