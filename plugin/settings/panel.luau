--!nonstrict

local PROTOCOL = 1
local categories = {
	{ id = "overview", label = "Overview", glyph = "info-circle" },
	{ id = "appearance", label = "Appearance", glyph = "sparkles" },
	{ id = "layouts", label = "Layouts", glyph = "layout-grid" },
	{ id = "input", label = "Input", glyph = "mouse" },
	{ id = "displays", label = "Displays", glyph = "device-desktop" },
	{ id = "rules", label = "Rules", glyph = "filter" },
	{ id = "keybinds", label = "Keybinds", glyph = "keyboard" },
	{ id = "advanced", label = "Advanced", glyph = "code" },
}
local fileOrder = { "wm", "layout", "input", "outputs", "rules" }

local snapshot = nil
local drafts = {}
local rawDrafts = {}
local rawDirty = {}
local inputRevisions = {}
local activeCategory = "overview"
local activeFile = "wm"
local busy = false
local status = "loading"
local statusMessage = ""
local dataDir = nil
local requestSerial = 0

local render

local function tr(key)
	return noctalia.tr(key)
end

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function helperPath()
	local configured = noctalia.getConfig("helper_path") or "aqueous-config"
	if configured:sub(1, 1) == "~" then
		configured = noctalia.expandPath(configured)
	end
	return configured
end

local function helperAvailable(path)
	if path:find("/", 1, true) then
		return noctalia.fileExists(path)
	end
	return noctalia.commandExists(path)
end

local function resultText(result)
	if type(result) == "table" then
		return result.stdout or "", result.stderr or "", result.exitCode or -1
	end
	return tostring(result or ""), "", 0
end

local function runHelper(arguments, callback)
	local helper = helperPath()
	if not helperAvailable(helper) then
		callback(nil, {
			code = "helper_missing",
			message = tr("error.helper_missing") .. " (" .. helper .. ")",
		})
		return
	end
	local command = shellQuote(helper) .. " " .. arguments
	local accepted = noctalia.runAsync(command, function(result)
		local stdout, stderr, exitCode = resultText(result)
		local decoded = noctalia.json.decode(stdout)
		if type(decoded) ~= "table" then
			callback(nil, {
				code = "invalid_response",
				message = stderr ~= "" and stderr or tr("error.invalid_response"),
			})
			return
		end
		if decoded.ok ~= true or exitCode ~= 0 then
			callback(nil, decoded)
			return
		end
		callback(decoded, nil)
	end)
	if not accepted then
		callback(nil, { code = "launch_failed", message = tr("error.launch_failed") })
	end
end

local function hasDrafts()
	for _id, _value in pairs(drafts) do
		return true
	end
	for _file, dirty in pairs(rawDirty) do
		if dirty then
			return true
		end
	end
	return false
end

local function draftCount()
	local count = 0
	for _id, _value in pairs(drafts) do
		count += 1
	end
	for _file, dirty in pairs(rawDirty) do
		if dirty then
			count += 1
		end
	end
	return count
end

local function needsUserOverride()
	if snapshot == nil or snapshot.files == nil then
		return false
	end
	for _, field in ipairs(snapshot.fields or {}) do
		if drafts[field.id] ~= nil and snapshot.files[field.file] and snapshot.files[field.file].writable == false then
			return true
		end
	end
	for file, dirty in pairs(rawDirty) do
		if dirty and snapshot.files[file] and snapshot.files[file].writable == false then
			return true
		end
	end
	return false
end

local function currentValue(field)
	local value = drafts[field.id]
	if value ~= nil then
		return value
	end
	return field.value
end

local function setDraft(field, value, shouldRender)
	if value == field.value then
		drafts[field.id] = nil
	else
		drafts[field.id] = value
	end
	status = hasDrafts() and "dirty" or "ready"
	statusMessage = ""
	if shouldRender ~= false then
		render()
	end
end

local function resetFromSnapshot(newSnapshot)
	snapshot = newSnapshot
	drafts = {}
	rawDrafts = {}
	rawDirty = {}
	inputRevisions = {}
	for file, source in pairs(snapshot.raw_files or {}) do
		rawDrafts[file] = source
	end
	status = "ready"
	statusMessage = ""
end

local function loadSnapshot(force)
	if busy then
		return
	end
	if hasDrafts() and not force then
		status = "dirty"
		render()
		return
	end
	busy = true
	status = "loading"
	statusMessage = tr("status.loading")
	render()
	runHelper("snapshot --json", function(response, err)
		busy = false
		if err then
			status = "error"
			statusMessage = err.message or err.code or tr("error.generic")
		else
			resetFromSnapshot(response)
		end
		render()
	end)
end

local function writeRequest(mode)
	if snapshot == nil or busy then
		return
	end
	dataDir = dataDir or noctalia.pluginDataDir()
	if dataDir == nil then
		status = "error"
		statusMessage = tr("error.data_dir")
		render()
		return
	end
	local changes = {}
	for id, value in pairs(drafts) do
		table.insert(changes, { id = id, value = value })
	end
	table.sort(changes, function(a, b)
		return a.id < b.id
	end)
	local rawFiles = {}
	for file, dirty in pairs(rawDirty) do
		if dirty then
			rawFiles[file] = rawDrafts[file]
		end
	end
	local request = {
		protocol = PROTOCOL,
		expected_generation = snapshot.generation,
		changes = changes,
		raw_files = rawFiles,
		backup_dir = dataDir .. "/backups",
		create_user_override = true,
	}
	local encoded = noctalia.json.encode(request)
	if encoded == nil then
		status = "error"
		statusMessage = tr("error.encode")
		render()
		return
	end
	requestSerial += 1
	local path = dataDir .. "/request-" .. requestSerial .. ".json"
	local ok, writeError = noctalia.writeFile(path, encoded)
	if not ok then
		status = "error"
		statusMessage = writeError or tr("error.request_write")
		render()
		return
	end
	busy = true
	status = mode == "apply" and "applying" or "validating"
	statusMessage = mode == "apply" and tr("status.applying") or tr("status.validating")
	render()
	runHelper(mode .. " --request " .. shellQuote(path), function(response, err)
		noctalia.removeFile(path)
		busy = false
		if err then
			if err.code == "external_change" then
				status = "conflict"
				statusMessage = tr("error.external_change")
			else
				status = "error"
				statusMessage = err.message or err.code or tr("error.generic")
			end
		else
			if mode == "apply" then
				resetFromSnapshot(response)
				status = "success"
				statusMessage = tr("status.applied")
			else
				status = "dirty"
				statusMessage = tr("status.valid")
			end
		end
		render()
	end)
end

local function categoryButton(category)
	return ui.button({
		key = "category-" .. category.id,
		text = category.label,
		glyph = category.glyph,
		variant = activeCategory == category.id and "secondary" or "ghost",
		selected = activeCategory == category.id,
		contentAlign = "start",
		onClick = function()
			activeCategory = category.id
			render()
		end,
	})
end

local function sectionTitle(title, description)
	return ui.column({ gap = 4, align = "stretch" }, {
		ui.label({ text = title, fontSize = 20, fontWeight = "bold", color = "on_surface" }),
		ui.label({ text = description, color = "on_surface_variant", maxLines = 3 }),
	})
end

local function numericControl(field, value)
	local number = tonumber(value) or tonumber(field.default) or 0
	local revision = inputRevisions[field.id] or 0
	local controls = {
		ui.input({
			key = "number-" .. field.id .. "-" .. revision,
			value = tostring(value),
			controlSize = "sm",
			width = 110,
			onChange = function(text)
				setDraft(field, text)
			end,
			onSubmit = function(text)
				setDraft(field, text)
			end,
		}),
	}
	if field.min ~= nil and field.max ~= nil and field.max - field.min <= 1024 then
		table.insert(controls, 1, ui.slider({
			key = "slider-" .. field.id,
			min = field.min,
			max = field.max,
			step = field.type == "integer" and 1 or 0.01,
			value = number,
			flexGrow = 1,
			onChange = function(text)
				local changed = tonumber(text) or number
				if field.type == "integer" then
					changed = math.floor(changed + 0.5)
				end
				inputRevisions[field.id] = revision + 1
				setDraft(field, changed)
			end,
		}))
	end
	return ui.row({ gap = 12, align = "center" }, controls)
end

local function selectControl(field, value)
	local selected = 0
	for index, option in ipairs(field.options or {}) do
		if option == value then
			selected = index - 1
			break
		end
	end
	return ui.select({
		key = "select-" .. field.id,
		options = field.options or {},
		selectedIndex = selected,
		onChange = function(index, _text)
			local wanted = (tonumber(index) or 0) + 1
			setDraft(field, field.options[wanted] or value)
		end,
	})
end

local function fieldControl(field)
	local value = currentValue(field)
	if field.type == "boolean" then
		return ui.toggle({
			key = "toggle-" .. field.id,
			checked = value == true,
			onChange = function(text)
				setDraft(field, text == "true")
			end,
		})
	elseif field.type == "integer" or field.type == "double" then
		return numericControl(field, value)
	elseif field.type == "select" then
		return selectControl(field, value)
	end
	local revision = inputRevisions[field.id] or 0
	local children = {
		ui.input({
			key = "text-" .. field.id .. "-" .. revision,
			value = tostring(value or ""),
			onChange = function(text)
				setDraft(field, text)
			end,
			onSubmit = function(text)
				setDraft(field, text)
			end,
		}),
	}
	if field.type == "color" then
		table.insert(children, 1, ui.box({
			width = 30,
			height = 30,
			radius = 8,
			fill = tostring(value),
			border = "outline",
			borderWidth = 1,
		}))
	end
	return ui.row({ gap = 10, align = "center" }, children)
end

local function fieldCard(field)
	return ui.column({
		key = "field-" .. field.id,
		gap = 8,
		padding = 12,
		radius = 10,
		fill = "surface_container",
		border = drafts[field.id] ~= nil and "primary" or "outline_variant",
		borderWidth = 1,
		align = "stretch",
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = field.label, fontWeight = "medium", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = field.file .. ".toml", fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.label({ text = field.description, fontSize = 12, color = "on_surface_variant", maxLines = 3 }),
		fieldControl(field),
	})
end

local function categoryView()
	local children = {
		sectionTitle(activeCategory:sub(1, 1):upper() .. activeCategory:sub(2), tr("category." .. activeCategory)),
	}
	local found = false
	for _, field in ipairs(snapshot.fields or {}) do
		if field.category == activeCategory then
			table.insert(children, fieldCard(field))
			found = true
		end
	end
	if not found then
		table.insert(children, ui.label({
			text = tr("category.collections_hint"),
			color = "on_surface_variant",
			maxLines = 4,
		}))
	end
	return ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, children)
end

local function overviewView()
	local fileRows = {}
	for _, file in ipairs(fileOrder) do
		local info = snapshot.files and snapshot.files[file] or nil
		if info then
			table.insert(fileRows, ui.row({
				key = "overview-file-" .. file,
				gap = 8,
				paddingV = 6,
				align = "center",
			}, {
				ui.glyph({ name = info.writable and "file-check" or "file-lock", color = info.writable and "primary" or "error" }),
				ui.label({ text = file .. ".toml", fontWeight = "medium", width = 110 }),
				ui.label({ text = info.path, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
			}))
		end
	end
	local warningRows = {}
	for index, warning in ipairs(snapshot.warnings or {}) do
		table.insert(warningRows, ui.row({
			key = "warning-" .. index,
			gap = 8,
			padding = 10,
			radius = 8,
			fill = "surface_container_high",
		}, {
			ui.glyph({ name = "alert-triangle", color = "tertiary" }),
			ui.label({ text = warning, color = "on_surface_variant", flexGrow = 1, maxLines = 4 }),
		}))
	end
	local children = {
		sectionTitle(tr("overview.title"), tr("overview.description")),
		ui.row({ gap = 16 }, {
			ui.column({ gap = 2, padding = 12, radius = 10, fill = "surface_container", flexGrow = 1 }, {
				ui.label({ text = tostring(#(snapshot.fields or {})), fontSize = 26, fontWeight = "bold", color = "primary" }),
				ui.label({ text = tr("overview.typed_fields"), color = "on_surface_variant" }),
			}),
			ui.column({ gap = 2, padding = 12, radius = 10, fill = "surface_container", flexGrow = 1 }, {
				ui.label({ text = snapshot.helper_version or "?", fontSize = 26, fontWeight = "bold", color = "primary" }),
				ui.label({ text = tr("overview.helper_version"), color = "on_surface_variant" }),
			}),
		}),
		ui.label({ text = tr("overview.resolved_files"), fontWeight = "bold" }),
		ui.column({ gap = 2, padding = 10, radius = 10, fill = "surface_container", align = "stretch" }, fileRows),
	}
	for _, row in ipairs(warningRows) do
		table.insert(children, row)
	end
	return ui.scroll({ flexGrow = 1, gap = 14, align = "stretch" }, children)
end

local function advancedView()
	local buttons = {}
	for _, file in ipairs(fileOrder) do
		table.insert(buttons, ui.button({
			key = "raw-file-" .. file,
			text = file .. ".toml",
			variant = activeFile == file and "secondary" or "ghost",
			selected = activeFile == file,
			onClick = function()
				activeFile = file
				render()
			end,
		}))
	end
	local info = snapshot.files and snapshot.files[activeFile] or {}
	return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
		sectionTitle(tr("advanced.title"), tr("advanced.description")),
		ui.row({ gap = 6 }, buttons),
		ui.label({ text = info.path or "", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
		activeFile == "outputs" and ui.label({
			text = tr("advanced.outputs_warning"),
			color = "tertiary",
			maxLines = 3,
		}) or ui.spacer({ height = 0 }),
		ui.input({
			key = "raw-editor-" .. activeFile,
			value = rawDrafts[activeFile] or "",
			multiline = true,
			flexGrow = 1,
			onChange = function(text)
				rawDrafts[activeFile] = text
				rawDirty[activeFile] = text ~= (snapshot.raw_files[activeFile] or "")
				status = hasDrafts() and "dirty" or "ready"
				render()
			end,
		}),
	})
end

local function statusColor()
	if status == "error" or status == "conflict" then
		return "error"
	elseif status == "success" then
		return "primary"
	elseif status == "dirty" then
		return "tertiary"
	end
	return "on_surface_variant"
end

local function footer()
	local count = draftCount()
	local message = statusMessage
	if message == "" then
		if status == "dirty" then
			message = needsUserOverride() and tr("status.user_override") or tr("status.dirty"):gsub("{count}", tostring(count))
		elseif status == "ready" then
			message = tr("status.ready")
		end
	end
	local actions = {
		ui.label({ text = message, color = statusColor(), flexGrow = 1, maxLines = 2 }),
	}
	if status == "conflict" then
		table.insert(actions, ui.button({
			text = tr("action.reload"),
			glyph = "refresh",
			onClick = function()
				loadSnapshot(true)
			end,
		}))
	end
	table.insert(actions, ui.button({
		text = tr("action.discard"),
		variant = "ghost",
		enabled = hasDrafts() and not busy,
		onClick = function()
			resetFromSnapshot(snapshot)
			render()
		end,
	}))
	table.insert(actions, ui.button({
		text = tr("action.validate"),
		variant = "outline",
		enabled = hasDrafts() and not busy,
		onClick = function()
			writeRequest("validate")
		end,
	}))
	table.insert(actions, ui.button({
		text = needsUserOverride() and tr("action.create_override") or tr("action.apply"),
		glyph = "check",
		variant = "primary",
		enabled = hasDrafts() and not busy,
		onClick = function()
			writeRequest("apply")
		end,
	}))
	return ui.row({ gap = 8, align = "center" }, actions)
end

local function errorView()
	return ui.column({ flexGrow = 1, gap = 14, align = "center", justify = "center" }, {
		ui.glyph({ name = "alert-circle", size = 42, color = "error" }),
		ui.label({ text = tr("error.title"), fontSize = 20, fontWeight = "bold" }),
		ui.label({ text = statusMessage, color = "on_surface_variant", maxWidth = 560, maxLines = 6, textAlign = "center" }),
		ui.button({
			text = tr("action.retry"),
			glyph = "refresh",
			variant = "primary",
			onClick = function()
				loadSnapshot(true)
			end,
		}),
	})
end

local function loadingView()
	return ui.column({ flexGrow = 1, gap = 14, align = "center", justify = "center" }, {
		ui.glyph({ name = "loader-2", size = 40, color = "primary" }),
		ui.label({ text = statusMessage ~= "" and statusMessage or tr("status.loading"), color = "on_surface_variant" }),
	})
end

render = function()
	if snapshot == nil then
		panel.render(status == "error" and errorView() or loadingView())
		return
	end
	local navigation = {}
	for _, category in ipairs(categories) do
		table.insert(navigation, categoryButton(category))
	end
	local body
	if activeCategory == "overview" then
		body = overviewView()
	elseif activeCategory == "advanced" then
		body = advancedView()
	else
		body = categoryView()
	end
	panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "droplet", size = 22, color = "primary" }),
			ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
			ui.button({
				glyph = "refresh",
				variant = "ghost",
				tooltip = tr("action.reload"),
				enabled = not busy,
				onClick = function()
					loadSnapshot(not hasDrafts())
				end,
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = function()
				panel.close()
			end }),
		}),
		ui.separator({}),
		ui.row({ flexGrow = 1, gap = 14, align = "stretch" }, {
			ui.column({ key = "navigation", width = 160, gap = 4, align = "stretch" }, navigation),
			ui.separator({ orientation = "vertical" }),
			ui.column({ key = "content", flexGrow = 1, align = "stretch" }, { body }),
		}),
		ui.separator({}),
		footer(),
	}))
end

function onOpen(_context)
	if snapshot ~= nil and hasDrafts() then
		status = "dirty"
		render()
		return
	end
	loadSnapshot(true)
end

function onClose()
	-- Draft state intentionally remains in memory and is restored on the next open.
end

function onIpc(event, _payload)
	if event == "reload" then
		loadSnapshot(true)
	elseif event == "apply" then
		writeRequest("apply")
	end
end
