verbana.commands = {}

local mod_priv = verbana.privs.moderator
local admin_priv = verbana.privs.admin

minetest.register_chatcommand('import_sban', {
    params='<filename>',
    description='import records from sban',
    privs={[admin_priv]=true},
    func=function (_, filename)
        if not filename or filename == '' then
            filename = minetest.get_worldpath() .. '/sban.sqlite'
        end
        if not io.open(filename, 'r') then
            return false, ('Could not open file %q.'):format(filename)
        elseif verbana.data.import_from_sban(filename) then
            return true, 'Successfully imported.'
        else
            return false, 'Error importing SBAN db (see server log)'
        end
    end
})

minetest.register_chatcommand('get_asn', {
    params='<name> | <IP>',
    description='get the ASN associated with an IP or player name',
    privs={[mod_priv]=true},
    func = function(_, name_or_ipstr)
        local ipstr

        if verbana.ip.is_valid_ip(name_or_ipstr) then
            ipstr = name_or_ipstr
        else
            ipstr = minetest.get_player_ip(name_or_ipstr)
        end

        if not ipstr or ipstr == '' then
            return false, ('"%s" is not a valid ip nor a connected player'):format(name_or_ipstr)
        end

        local asn, description = verbana.asn.lookup(ipstr)
        if not asn or asn == 0 then
            return false, ('could not find ASN for "%s"'):format(ipstr)
        end

        description = description or ''

        return true, ('A%u (%s)'):format(asn, description)
    end
})

local function parse_status_params(params)
    local name, reason = params:match('^([a-zA-Z0-9_-]+)%s+(.*)$')
    if not name then
        name = params:match('^([a-zA-Z0-9_-]+)$')
    end
    if not name or name:len() > 20 then
        return nil, nil, nil, ('Invalid argument(s): %q'):format(params)
    end
    local player_id = verbana.data.get_player_id(name)
    if not player_id then
        return nil, nil, nil, ('Unknown player: %s'):format(name)
    end
    local player_status = verbana.data.get_player_status(player_id, true)
    return player_id, name, player_status, reason
end

local function parse_timed_status_params(params)
    local name, timespan_str, reason = params:match('^([a-zA-Z0-9_-]+)%s+(%d+%w)%s+(.*)$')
    if not name then
        name, timespan_str = params:match('^([a-zA-Z0-9_-]+)%s+(%d+%w)$')
    end
    if not name or name:len() > 20 then
        return nil, nil, nil, nil, ('Invalid argument(s): %q'):format(params)
    end
    local timespan = verbana.util.parse_time(timespan_str)
    if not timespan then
        return nil, nil, nil, nil, ('Invalid argument(s): %q'):format(params)
    end
    local player_id = verbana.data.get_player_id(name)
    if not player_id then
        return nil, nil, nil, nil, ('Unknown player: %s'):format(name)
    end
    local player_status = verbana.data.get_player_status(player_id, true)
    local expires = os.time() + timespan
    return player_id, name, player_status, expires, reason
end

local function has_suspicious_connection(player_name)
    local connection_log = verbana.data.get_player_connection_log(player_name, 1)
    if not connection_log or #connection_log ~= 1 then
        verbana.log('warning', 'player %s exists but has no connection log?', player_name)
        return true
    end
    local last_login = connection_log[1]
    if last_login.ip_status_id == verbana.data.ip_status.trusted.id then
        return false
    elseif last_login.ip_status_id ~= verbana.data.ip_status.default.id then
        return true
    elseif last_login.asn_status_id == verbana.data.asn_status.default.id then
        return false
    end
    return true
end
----------------- SET PLAYER STATUS COMMANDS -----------------
minetest.register_chatcommand('verify', {
    params='<name> [<reason>]',
    description='verify a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if player_status.status_id ~= verbana.data.player_status.unverified.id then
            return false, ('Player %s is not unverified'):format(player_name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        local status_id
        if has_suspicious_connection(player_name) then
            status_id = verbana.data.player_status.suspicious.id
        else
            status_id = verbana.data.player_status.default.id
        end
        if not verbana.data.set_player_status(player_id, executor_id, status_id, reason) then
            return false, 'ERROR setting player status'
        end
        minetest.set_player_privs(player_name, verbana.settings.verified_privs)
        local player = minetest.get_player_by_name(player_name)
        if player then
            player:set_pos(verbana.settings.spawn_pos)
        end
        if reason then
            verbana.log('action', '%s verified %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s verified %s', caller, player_name)
        end
        return true, ('Verified %s'):format(player_name)
    end
})

minetest.register_chatcommand('unverify', {
    params='<name> [<reason>]',
    description='unverify a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
                verbana.data.player_status.suspicious.id,
            }, player_status.status_id) then
            return false, ('Cannot unverify %s w/ status %s'):format(player_name, player_status.name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.unverified.id, reason) then
            return false, 'ERROR setting player status'
        end
        minetest.set_player_privs(player_name, verbana.settings.unverified_privs)
        local player = minetest.get_player_by_name(player_name)
        if player then
            player:set_pos(verbana.settings.verification_pos)
        end
        if reason then
            verbana.log('action', '%s unverified %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s unverified %s', caller, player_name)
        end
        return true, ('Unverified %s'):format(player_name)
    end
})

minetest.override_chatcommand('kick', {
    params='<name> [<reason>]',
    description='kick a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, _, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
		local player = minetest.get_player_by_name(player_name)
		if not player then
			return false, ("Player %s not in game!"):format(player_name)
		end
		if not minetest.kick_player(player_name, reason) then
			player:set_detach()
			if not minetest.kick_player(player_name, reason) then
                verbana.log('warning', 'Failed to kick player %s after detaching!', player_name)
				return false, ("Failed to kick player %s after detaching!"):format(player_name)
			end
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.kicked.id, reason, nil, true) then
            return false, 'ERROR logging player status'
        end
        if reason then
            verbana.log('action', '%s kicked %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s kicked %s', caller, player_name)
        end
        return true, ('Kicked %s'):format(player_name)
    end
})

minetest.register_chatcommand('lock', {
    params='<name> [<reason>]',
    description='lock a player\'s account',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
                verbana.data.player_status.unverified.id,
                verbana.data.player_status.suspicious.id,
            }, player_status.status_id) then
            return false, ('Cannot lock %s w/ status %s'):format(player_name, player_status.name)
        end
		local player = minetest.get_player_by_name(player_name)
        if player then
            if not minetest.kick_player(player_name, reason) then
                player:set_detach()
                if not minetest.kick_player(player_name, reason) then
                    minetest.chat_send_player(caller, ('Failed to kick player %s after detaching!'):format(player_name))
                    verbana.log('warning', 'Failed to kick player %s after detaching!', player_name)
                end
            end
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.locked.id, reason) then
            return false, 'ERROR logging player status'
        end
        if reason then
            verbana.log('action', '%s locked %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s locked %s', caller, player_name)
        end
        return true, ('Locked %s'):format(player_name)
    end
})

minetest.register_chatcommand('unlock', {
    params='<name> [<reason>]',
    description='unlock a player\'s account',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if player_status.status_id ~= verbana.data.player_status.locked.id then
            return false, ('Player %s is not locked!'):format(player_name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        local status_id
        if has_suspicious_connection(player_name) then
            status_id = verbana.data.player_status.suspicious.id
        else
            status_id = verbana.data.player_status.default.id
        end
        if not verbana.data.set_player_status(player_id, executor_id, status_id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s unlocked %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s unlocked %s', caller, player_name)
        end
        return true, ('Unlocked %s'):format(player_name)
    end
})

minetest.override_chatcommand('ban', {
    params='<name> [<reason>]',
    description='ban a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if reason then
            local first = reason:match('^(%S+)')
            if verbana.util.parse_time(first) then
                return false, ('Given reason begins with a timespan %q. Did you mean to use tempban?'):format(first)
            end
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
                verbana.data.player_status.unverified.id,
                verbana.data.player_status.suspicious.id,
            }, player_status.status_id) then
            return false, ('Cannot ban %s w/ status %s'):format(player_name, player_status.name)
        end
		local player = minetest.get_player_by_name(player_name)
        if player then
            if not minetest.kick_player(player_name, reason) then
                player:set_detach()
                if not minetest.kick_player(player_name, reason) then
                    minetest.chat_send_player(caller, ('Failed to kick player %s after detaching!'):format(player_name))
                    verbana.log('warning', 'Failed to kick player %s after detaching!', player_name)
                end
            end
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.banned.id, reason) then
            return false, 'ERROR logging player status'
        end
        if reason then
            verbana.log('action', '%s banned %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s banned %s', caller, player_name)
        end
        return true, ('Banned %s'):format(player_name)
    end
})

minetest.register_chatcommand('tempban', {
    params='<name> <timespan> [<reason>]',
    description='ban a player for a length of time',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, expires, reason = parse_timed_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
                verbana.data.player_status.unverified.id,
                verbana.data.player_status.suspicious.id,
            }, player_status.status_id) then
            return false, ('Cannot ban %s w/ status %s'):format(player_name, player_status.name)
        end
		local player = minetest.get_player_by_name(player_name)
        if player then
            if not minetest.kick_player(player_name, reason) then
                player:set_detach()
                if not minetest.kick_player(player_name, reason) then
                    minetest.chat_send_player(caller, ('Failed to kick player %s after detaching!'):format(player_name))
                    verbana.log('warning', 'Failed to kick player %s after detaching!', player_name)
                end
            end
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.tempbanned.id, reason, expires) then
            return false, 'ERROR logging player status'
        end
        local expires_str = os.date("%c", expires)
        if reason then
            verbana.log('action', '%s tempbanned %s until %s because %s', caller, player_name, expires_str, reason)
        else
            verbana.log('action', '%s tempbanned %s until %s', caller, player_name, expires_str)
        end
        return true, ('Temporarily banned %s until %s'):format(player_name, expires_str)
    end
})

minetest.override_chatcommand('unban', {
    params='<name> [<reason>]',
    description='unban a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.banned.id,
                verbana.data.player_status.tempbanned.id,
            }, player_status.status_id) then
            return false, ('Player %s is not banned!'):format(player_name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        local status_id
        if has_suspicious_connection(player_name) then
            status_id = verbana.data.player_status.suspicious.id
        else
            status_id = verbana.data.player_status.default.id
        end
        if not verbana.data.set_player_status(player_id, executor_id, status_id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s unbanned %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s unbanned %s', caller, player_name)
        end
        return true, ('Unbanned %s'):format(player_name)
    end
})

minetest.register_chatcommand('whitelist', {
    params='<name> [<reason>]',
    description='whitelist a player',
    privs={[admin_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
                verbana.data.player_status.unverified.id,
                verbana.data.player_status.suspicious.id,
            }, player_status.status_id) then
            return false, ('Cannot whitelist %s w/ status %s'):format(player_name, player_status.name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.whitelisted.id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s whitelisted %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s whitelisted %s', caller, player_name)
        end
        return true, ('Whitelisted %s'):format(player_name)
    end
})

minetest.register_chatcommand('unwhitelist', {
    params='<name> [<reason>]',
    description='whitelist a player',
    privs={[admin_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if player_status.status_id ~= verbana.data.player_status.whitelisted.id then
            return false, ('Player %s is not locked!'):format(player_name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.default.id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s unwhitelisted %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s unwhitelisted %s', caller, player_name)
        end
        return true, ('Unwhitelisted %s'):format(player_name)
    end
})

minetest.register_chatcommand('suspect', {
    params='<name> [<reason>]',
    description='mark a player as suspicious',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if not verbana.util.table_contains({
                verbana.data.player_status.unknown.id,
                verbana.data.player_status.default.id,
            }, player_status.status_id) then
            return false, ('Cannot whitelist %s w/ status %s'):format(player_name, player_status.name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.suspicious.id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s suspected %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s suspected %s', caller, player_name)
        end
        return true, ('Suspected %s'):format(player_name)
    end
})

minetest.register_chatcommand('unsuspect', {
    params='<name> [<reason>]',
    description='unmark a player as suspicious',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local player_id, player_name, player_status, reason = parse_status_params(params)
        if not player_id then
            return false, reason
        end
        if player_status.status_id ~= verbana.data.player_status.suspicious.id then
            return false, ('Player %s is not suspicious!'):format(player_name)
        end
        local executor_id = verbana.data.get_player_id(caller)
        if not executor_id then
            return false, 'ERROR: could not get executor ID?'
        end
        if not verbana.data.set_player_status(player_id, executor_id, verbana.data.player_status.default.id, reason) then
            return false, 'ERROR setting player status'
        end
        if reason then
            verbana.log('action', '%s unsuspected %s because %s', caller, player_name, reason)
        else
            verbana.log('action', '%s unsuspected %s', caller, player_name)
        end
        return true, ('Unsuspected %s'):format(player_name)
    end
})
----------------- SET IP/ASN STATUS COMMANDS -----------------
minetest.register_chatcommand('set_ip_status', {
    params='<asn> <status>',
    description='set the status of an IP (default, dangerous, blocked)',
    privs={[admin_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

minetest.register_chatcommand('set_asn_status', {
    params='<asn> <status>',
    description='set the status of an ASN (default, dangerous, blocked)',
    privs={[admin_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})
---------------- GET LOGS ---------------
minetest.register_chatcommand('player_status_log', {
    params='<name> [<number>]',
    description='shows the status log of a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local name, numberstr = string.match(params, '^([%a%d_-]+) +(%d+)$')
        if not name then
            name = string.match(params, '^([%a%d_-]+)$')
        end
        if not name then
            return false, 'invalid arguments'
        end
        local player_id = verbana.data.get_player_id(name)
        if not player_id then
            return false, 'unknown player'
        end
        local rows = verbana.data.get_player_status_log(player_id)
        if not rows then
            return false, 'An error occurred (see server logs)'
        end
        if #rows == 0 then
            return true, 'No records found.'
        end
        local starti
        if numberstr then
            local number = tonumber(numberstr)
            starti = math.max(1, #rows - number)
        else
            starti = 1
        end
        for index = starti,#rows do
            local row = rows[index]
            local message = ('%s: %s set status to %s.'):format(os.date("%c", row.timestamp), row.executor, row.status)
            local reason = row.reason
            if reason and reason ~= '' then
                message = ('%s Reason: %s'):format(message, reason)
            end
            local expires = row.expires
            if expires then
                message = ('%s Expires: %s'):format(message, os.date("%c", expires))
            end
            minetest.chat_send_player(caller, message)
        end
        return true
    end
})

minetest.register_chatcommand('ip_status_log', {
    params='<IP> [<number>]',
    description='shows the status log of an IP',
    privs={[admin_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

minetest.register_chatcommand('asn_status_log', {
    params='<ASN> [<number>]',
    description='shows the status log of an ASN',
    privs={[admin_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

minetest.register_chatcommand('login_record', {
    params='<name> [<number>]',
    description='shows the login record of a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        local name, limit = params:match('^([a-zA-Z0-9_-]+)%s+(%d+)$')
        if not name then
            name = params:match('^([a-zA-Z0-9_-]+)$')
        end
        if not name then
            return false, 'invalid arguments'
        end
        if not limit then
            limit = 20
        end
        local player_id = verbana.data.get_player_id(name)
        if not player_id then
            return false, 'unknown player'
        end
        local rows = verbana.data.get_player_connection_log(player_id)
        if not rows then
            return false, 'An error occurred (see server logs)'
        end
        if #rows == 0 then
            return true, 'No records found.'
        end
        for _, row in ipairs(rows) do
            local message = ('%s:%s from %s<%s> A%s<%s> (%s)'):format(
                os.date("%c", row.timestamp),
                (rows.success and ' failed!') or '',
                verbana.ip.ipint_to_ipstr(row.ipint),
                row.ip_status_name,
                row.asn,
                row.asn_status_name,
                verbana.asn.get_description(row.asn)
            )
            minetest.chat_send_player(caller, message)
        end
        return true
    end
})

minetest.register_chatcommand('inspect_player', {
    params='<name>',
    description='list ips, asns and statuses associated with a player',
    privs={[mod_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

minetest.register_chatcommand('inspect_ip', {
    params='<IP>',
    description='list player accounts and statuses associated with an IP',
    privs={[mod_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

minetest.register_chatcommand('inspect_asn', {
    params='<asn>',
    description='list player accounts and statuses associated with an ASN',
    privs={[mod_priv]=true},
    func=function(caller, params)
        return false, 'TODO: implement'  -- TODO
    end
})

-- alias (for listing an account's primary, cascade status)
-- list recent bans/kicks/locks/etc
-- first_login (=b) for all players
-- asn statistics
