
local dt = require "util.datetime";
local base64 = require "util.encodings".base64;
local hashes = require "util.hashes";
local st = require "util.stanza";
local jid = require "util.jid";

local default_host = module:get_option_string("external_service_host", module.host);
local default_port = module:get_option_number("external_service_port");
local default_secret = module:get_option_string("external_service_secret");
local default_ttl = module:get_option_number("external_service_ttl", 86400);

local configured_services = module:get_option_array("external_services", {});

local access = module:get_option_set("external_service_access", {});

-- filter config into well-defined service records
local function prepare(item)
	if type(item) ~= "table" then
		module:log("error", "Service definition is not a table: %q", item);
		return nil;
	end

	local srv = {
		type = nil;
		transport = nil;
		host = default_host;
		port = default_port;
		username = nil;
		password = nil;
		restricted = nil;
		expires = nil;
	};

	if type(item.type) == "string" then
		srv.type = item.type;
	else
		module:log("error", "Service missing mandatory 'type' field: %q", item);
		return nil;
	end
	if type(item.transport) == "string" then
		srv.transport = item.transport;
	end
	if type(item.host) == "string" then
		srv.host = item.host;
	end
	if type(item.port) == "number" then
		srv.port = item.port;
	end
	if type(item.username) == "string" then
		srv.username = item.username;
	end
	if type(item.password) == "string" then
		srv.password = item.password;
		srv.restricted = true;
	end
	if item.restricted == true then
		srv.restricted = true;
	end
	if type(item.expires) == "number" then
		srv.expires = item.expires;
	elseif type(item.ttl) == "number" then
		srv.expires = os.time() + item.ttl;
	end
	if (item.secret == true and default_secret) or type(item.secret) == "string" then
		local ttl = default_ttl;
		if type(item.ttl) == "number" then
			ttl = item.ttl;
		end
		local expires = os.time() + ttl;
		local secret = item.secret;
		if secret == true then
			secret = default_secret;
		end
		local username;
		if type(item.username) == "string" then
			username = string.format("%d:%s", expires, item.username);
		else
			username = string.format("%d", expires);
		end
		srv.username = username;
		srv.password = base64.encode(hashes.hmac_sha1(secret, srv.username));
		srv.restricted = true;
	end
	return srv;
end

function module.load()
	-- Trigger errors on startup
	local services = configured_services / prepare;
	if #services == 0 then
		module:log("warn", "No services configured or all had errors");
	end
end

local function handle_services(event)
	local origin, stanza = event.origin, event.stanza;
	local action = stanza.tags[1];

	local user_bare = jid.bare(stanza.attr.from);
	local user_host = jid.host(user_bare);
	if not ((access:empty() and origin.type == "c2s") or access:contains(user_bare) or access:contains(user_host)) then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end

	local reply = st.reply(stanza):tag("services", { xmlns = action.attr.xmlns });
	local extras = module:get_host_items("external_service");
	local services = ( configured_services + extras ) / prepare;

	local requested_type = action.attr.type;
	if requested_type then
		services:filter(function(item)
			return item.type == requested_type;
		end);
	end

	module:fire_event("external_service/services", {
			origin = origin;
			stanza = stanza;
			reply = reply;
			requested_type = requested_type;
			services = services;
		});

	for _, srv in ipairs(services) do
		reply:tag("service", {
				type = srv.type;
				transport = srv.transport;
				host = srv.host;
				port = srv.port and string.format("%d", srv.port) or nil;
				username = srv.username;
				password = srv.password;
				expires = srv.expires and dt.datetime(srv.expires) or nil;
				restricted = srv.restricted and "1" or nil;
			}):up();
	end

	origin.send(reply);
	return true;
end

local function handle_credentials(event)
	local origin, stanza = event.origin, event.stanza;
	local action = stanza.tags[1];

	if origin.type ~= "c2s" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end

	local reply = st.reply(stanza):tag("credentials", { xmlns = action.attr.xmlns });
	local extras = module:get_host_items("external_service");
	local services = ( configured_services + extras ) / prepare;
	services:filter(function (item)
		return item.restricted;
	end)

	local requested_credentials = {};
	for service in action:childtags("service") do
		table.insert(requested_credentials, {
				type = service.attr.type;
				host = service.attr.host;
				port = tonumber(service.attr.port);
			});
	end

	module:fire_event("external_service/credentials", {
			origin = origin;
			stanza = stanza;
			reply = reply;
			requested_credentials = requested_credentials;
			services = services;
		});

	for req_srv in action:childtags("service") do
		for _, srv in ipairs(services) do
			if srv.type == req_srv.attr.type and srv.host == req_srv.attr.host
				and not req_srv.attr.port or srv.port == tonumber(req_srv.attr.port) then
				reply:tag("service", {
						type = srv.type;
						transport = srv.transport;
						host = srv.host;
						port = srv.port and string.format("%d", srv.port) or nil;
						username = srv.username;
						password = srv.password;
						expires = srv.expires and dt.datetime(srv.expires) or nil;
						restricted = srv.restricted and "1" or nil;
					}):up();
			end
		end
	end

	origin.send(reply);
	return true;
end

-- XEP-0215 v0.7
module:add_feature("urn:xmpp:extdisco:2");
module:hook("iq-get/host/urn:xmpp:extdisco:2:services", handle_services);
module:hook("iq-get/host/urn:xmpp:extdisco:2:credentials", handle_credentials);

-- COMPAT XEP-0215 v0.6
-- Those still on the old version gets to deal with undefined attributes until they upgrade.
module:add_feature("urn:xmpp:extdisco:1");
module:hook("iq-get/host/urn:xmpp:extdisco:1:services", handle_services);
module:hook("iq-get/host/urn:xmpp:extdisco:1:credentials", handle_credentials);
