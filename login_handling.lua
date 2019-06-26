local function table_is_empty(t)
    for _ in pairs(t) do return false end
    return true
end

local USING_VERIFICATION_JAIL = verbana.settings.verification_jail and verbana.settings.verification_jail_period

local timer = 0
local verification_jail = verbana.settings.verification_jail
local check_player_privs = minetest.check_player_privs
local spawn_pos = verbana.settings.spawn_pos
local verification_pos = verbana.settings.verification_pos
local verification_jail_period = verbana.settings.verification_jail_period

local function should_rejail(player)
    local name = player:get_player_name()
    if not check_player_privs(name, {unverified = true}) then
        return false
    end
    local pos = player:get_pos()
    return not (
        verification_jail.x[1] <= pos.x and pos.x <= verification_jail.x[2] and
        verification_jail.y[1] <= pos.y and pos.y <= verification_jail.y[2] and
        verification_jail.z[1] <= pos.z and pos.z <= verification_jail.z[2]
    )
end

local function should_unjail(player)
    local name = player:get_player_name()
    if check_player_privs(name, {unverified = true}) then
        return false
    end
    local pos = player:get_pos()
    return (
        verification_jail.x[1] <= pos.x and pos.x <= verification_jail.x[2] and
        verification_jail.y[1] <= pos.y and pos.y <= verification_jail.y[2] and
        verification_jail.z[1] <= pos.z and pos.z <= verification_jail.z[2]
    )
end

if USING_VERIFICATION_JAIL then
    minetest.register_globalstep(function(dtime)
        timer = timer + dtime;
        if timer < verification_jail_period then
            return
        end
        timer = 0
        for _, player in ipairs(minetest.get_connected_players()) do
            if should_rejail(player) then
                player:set_pos(verification_pos)
            end
        end
    end)
end

minetest.register_on_prejoinplayer(function(name, ipstr)
    -- return a string w/ the reason for refusal; otherwise return nothing
    verbana.log('action', 'prejoin: %s %s', name, ipstr)
    local ipint = verbana.ip.ipstr_to_ipint(ipstr)
    local asn, asn_description = verbana.asn.lookup(ipint)

    local player_id = verbana.data.get_player_id(name, true) -- will create one if none exists
    local player_status = verbana.data.get_player_status(player_id, true)
    local ip_status = verbana.data.get_ip_status(ipint, true) -- will create one if none exists
    local asn_status = verbana.data.get_asn_status(asn, true) -- will create one if none exists

    -- check and clear temporary statuses
    local now = os.time()
    if player_status.name == 'tempbanned' then
        local expires = player_status.expires or now
        if now >= expires then
            verbana.data.unban_player(player_id, player_status.executor_id, 'temp ban expired')
            player_status = verbana.data.get_player_status(player_id) -- refresh player status
        end
    end
    if ip_status.name == 'tempblocked' then
        local expires = ip_status.expires or now
        if now >= expires then
            verbana.data.unblock_ip(ipint, ip_status.executor_id, 'temp block expired')
            ip_status = verbana.data.get_ip_status(ipint) -- refresh ip status
        end
    end
    if asn_status.name == 'tempblocked' then
        local expires = asn_status.expires or now
        if now >= expires then
            verbana.data.unblock_asn(asn, asn_status.executor_id, 'temp block expired')
            asn_status = verbana.data.get_asn_status(asn) -- refresh asn status
        end
    end

    local player_privs = minetest.get_player_privs(name)
    local is_new_player = table_is_empty(player_privs) and player_status.name == 'unknown'

    local suspicious = false
    local return_value

    if player_status.name == 'whitelisted' then
        -- if the player is whitelisted, let them in.
    elseif verbana.settings.privs_to_whitelist and minetest.check_player_privs(name, verbana.settings.privs_to_whitelist) then
        -- if the player has a whitelisted priv, let them in.
    elseif player_status.name == 'banned' then
        local reason = player_status.reason
        if reason and reason ~= '' then
            return_value = ('Account %q is banned because %q.'):format(name, reason)
        else
            return_value = ('Account %q is banned.'):format(name)
        end
    elseif player_status.name == 'locked' then
        local reason = player_status.reason
        if reason and reason ~= '' then
            return_value = ('Account %q is locked because %q.'):format(name, reason)
        else
            return_value = ('Account %q is locked.'):format(name)
        end
    elseif player_status.name == 'tempbanned' then
        local expires = os.date("%c", player_status.expires or now)
        local reason = player_status.reason
        if reason and reason ~= '' then
            return_value = ('Account %q is banned until %s because %q.'):format(name, expires, reason)
        else
            return_value = ('Account %q is banned until %s.'):format(name, expires)
        end
    elseif ip_status.name == 'trusted' then
        -- let them in
    elseif ip_status.name == 'suspicious' then
        suspicious = true
    elseif ip_status.name == 'blocked' then
        local reason = ip_status.reason
        if reason and reason ~= '' then
            return_value = ('IP %q is blocked because %q.'):format(ipstr, reason)
        else
            return_value = ('IP %q is blocked.'):format(ipstr)
        end
    elseif ip_status.name == 'tempblocked' then
        local expires = os.date("%c", ip_status.expires or now)
        local reason = ip_status.reason
        if reason and reason ~= '' then
            return_value = ('IP %q is blocked until %s because %q.'):format(ipstr, expires, reason)
        else
            return_value = ('IP %q is blocked until %s.'):format(ipstr, expires)
        end
    elseif asn_status.name == 'suspicious' then
        suspicious = true
    elseif asn_status.name == 'blocked' then
        local reason = asn_status.reason
        if reason and reason ~= '' then
            return_value = ('Network %s (%s) is blocked because %q.'):format(asn, asn_description, reason)
        else
            return_value = ('Network %s (%s) is blocked.'):format(asn, asn_description)
        end
    elseif asn_status.name == 'tempblocked' then
        local expires = os.date("%c", asn_status.expires or now)
        local reason = asn_status.reason
        if reason and reason ~= '' then
            return_value = ('Network %s (%s) is blocked until %s because %q.'):format(
                asn, asn_description, expires, reason
            )
        else
            return_value = ('Network %s (%s) is blocked until %s.'):format(asn, asn_description, expires)
        end
    end

    if suspicious and not is_new_player then
        -- if the player is new, let them in (truly new players will require verification)
        -- else if the player has never connected from this ip/asn, prevent them from connecting
        -- else let them in (mods will get an alert)
        local has_assoc = verbana.data.has_asn_assoc(player_id, asn) or verbana.data.has_ip_assoc(player_id, ipint)
        if not has_assoc then
            -- note: if 'suspicious' is true, then 'return_value' should be nil before this
            return_value = 'Suspicious activity detected.'
        end
    end

    if return_value then
        verbana.data.log(player_id, ipint, asn, false)
        verbana.log('action', 'Connection of %s from %s (A%s) denied because %q', name, ipstr, asn, return_value)
        return return_value
    else
        verbana.log('action', 'Connection of %s from %s (A%s) allowed', name, ipstr, asn)
        verbana.data.log(player_id, ipint, asn, true)
        verbana.data.assoc(player_id, ipint, asn)
    end
end)

local function move_to(name, pos, max_tries)
    max_tries = max_tries or 5
    local tries = 0
    local function f()
        -- get the player again here, in case they have disconnected
        local player = minetest.get_player_by_name(name)
        if player then
            player:set_pos(pos)
        elseif tries < max_tries then
            tries = tries + 1
            minetest.after(1, f)
        end
    end
    f()
end

minetest.register_on_newplayer(function(player)
    local name = player:get_player_name()
    local ipstr = minetest.get_player_ip(name)
    local ipint = verbana.ip.ipstr_to_ipint(ipstr)
    local asn = verbana.asn.lookup(ipint)
    local player_id = verbana.data.get_player_id(name)
    local ip_status = verbana.data.get_ip_status(ipint)
    local asn_status = verbana.data.get_asn_status(asn)

    local need_to_verify = (
        verbana.settings.universal_verification or
        ip_status.name == 'suspicious' or
        (asn_status.name == 'suspicious' and ip_status.name ~= 'trusted')
    )

    if need_to_verify then
        if not verbana.data.set_player_status(player_id, verbana.data.verbana_player_id, verbana.data.player_status.unverified.id, 'new player connected from suspicious network') then
            verbana.log('error', 'error setting unverified status on %s', name)
        end
        minetest.set_player_privs(name, verbana.settings.unverified_privs)
        player:set_pos(verbana.settings.verification_pos)
        -- wait a second before moving the player to the verification area
        -- because other mods sometimes try to move them around as well
        minetest.after(1, function() move_to(name, verbana.settings.verification_pos) end)
        verbana.log('action', 'new player %s sent to verification', name)
    else
        verbana.data.set_player_status(
            player_id,
            verbana.data.verbana_player_id,
            verbana.data.player_status.default.id,
            'new player'
        )
        verbana.log('action', 'new player %s', name)
    end
end)

minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local ipstr = minetest.get_player_ip(name)
    local ipint = verbana.ip.ipstr_to_ipint(ipstr)
    local asn, asn_description = verbana.asn.lookup(ipint)
    if minetest.check_player_privs(name, {[verbana.privs.unverified]=true}) then
        verbana.chat.tell_mods(('*** Player %s from A%s (%s) is unverified.'):format(name, asn, asn_description))
    end
    if USING_VERIFICATION_JAIL then
        if should_rejail(player) then
            player:set_pos(verification_pos)
        elseif should_unjail(player) then
            player:set_pos(spawn_pos)
        end
    end
end)

