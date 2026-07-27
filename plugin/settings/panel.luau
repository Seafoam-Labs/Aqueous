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
local monitorDrafts = {}
local customKeybindDrafts = {}
local inputRevisions = {}
local activeCategory = "overview"
local activeFile = "wm"
local busy = false
local status = "loading"
local statusMessage = ""
local dataDir = nil
local requestSerial = 0
local workspaceLayouts = {
	{ value = "tile", label = "Tile" },
	{ value = "monocle", label = "Monocle" },
	{ value = "grid", label = "Grid" },
	{ value = "rows", label = "Rows" },
	{ value = "dwindle", label = "Dwindle" },
	{ value = "scrolling", label = "Scrolling" },
	{ value = "float", label = "Float" },
	{ value = "game-mode", label = "Game Mode" },
}
local panelOutput = ""
local workspaceLayout = ""
local workspaceNumber = 0
local workspaceLayoutBusy = false
local workspaceLayoutMessage = ""

local render
local sectionTitle
local fieldCard

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

local function runAqueousctl(arguments, callback)
	if not noctalia.commandExists("aqueousctl") then
		callback(nil, { message = tr("overview.workspace_layout.missing") })
		return
	end
	local accepted = noctalia.runAsync("aqueousctl " .. arguments, function(result)
		local stdout, stderr, exitCode = resultText(result)
		local decoded = noctalia.json.decode(stdout)
		if type(decoded) ~= "table" then
			callback(nil, { message = stderr ~= "" and stderr or tr("error.invalid_response") })
			return
		end
		if decoded.ok ~= true or exitCode ~= 0 then
			callback(nil, {
				message = decoded.status or stderr or tr("overview.workspace_layout.unavailable"),
			})
			return
		end
		callback(decoded, nil)
	end)
	if not accepted then
		callback(nil, { message = tr("error.launch_failed") })
	end
end

local function queryWorkspaceLayout()
	workspaceLayout = ""
	workspaceNumber = 0
	if panelOutput == "" then
		workspaceLayoutMessage = tr("overview.workspace_layout.no_output")
		render()
		return
	end
	workspaceLayoutBusy = true
	workspaceLayoutMessage = tr("overview.workspace_layout.loading")
	render()
	runAqueousctl("layout --output " .. shellQuote(panelOutput) .. " --json", function(response, err)
		workspaceLayoutBusy = false
		if err then
			workspaceLayoutMessage = err.message or tr("overview.workspace_layout.unavailable")
		else
			workspaceLayout = response.layout or ""
			workspaceNumber = tonumber(response.workspace) or 0
			workspaceLayoutMessage = ""
		end
		render()
	end)
end

local function setWorkspaceLayout(layout)
	if workspaceLayoutBusy or panelOutput == "" or layout == workspaceLayout then
		return
	end
	workspaceLayoutBusy = true
	workspaceLayoutMessage = tr("overview.workspace_layout.changing")
	render()
	runAqueousctl(
		"layout --output " .. shellQuote(panelOutput) .. " --set " .. shellQuote(layout) .. " --json",
		function(response, err)
			workspaceLayoutBusy = false
			if err then
				workspaceLayoutMessage = err.message or tr("overview.workspace_layout.unavailable")
			else
				workspaceLayout = response.layout or layout
				workspaceNumber = tonumber(response.workspace) or workspaceNumber
				workspaceLayoutMessage = tr("overview.workspace_layout.changed")
			end
			render()
		end
	)
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
	for _id, _monitor in pairs(monitorDrafts) do
		return true
	end
	for _id, _keybind in pairs(customKeybindDrafts) do
		return true
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
	for _id, _monitor in pairs(monitorDrafts) do
		count += 1
	end
	for _id, _keybind in pairs(customKeybindDrafts) do
		count += 1
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
	if next(monitorDrafts) ~= nil and snapshot.files.wm and snapshot.files.wm.writable == false then
		return true
	end
	if next(customKeybindDrafts) ~= nil and snapshot.files.wm and snapshot.files.wm.writable == false then
		return true
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
	monitorDrafts = {}
	customKeybindDrafts = {}
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
	local monitorChanges = {}
	for _id, monitor in pairs(monitorDrafts) do
		table.insert(monitorChanges, {
			id = monitor.id,
			name = monitor.name,
			x = monitor.x,
			y = monitor.y,
			transform = monitor.transform,
		})
	end
	table.sort(monitorChanges, function(a, b)
		return a.id < b.id
	end)
	local customKeybindChanges = {}
	for _id, keybind in pairs(customKeybindDrafts) do
		table.insert(customKeybindChanges, {
			id = keybind.id,
			chord = keybind.chord,
			command = keybind.command,
		})
	end
	table.sort(customKeybindChanges, function(a, b)
		return a.id < b.id
	end)
	local request = {
		protocol = PROTOCOL,
		expected_generation = snapshot.generation,
		raw_files = rawFiles,
		backup_dir = dataDir .. "/backups",
		create_user_override = true,
	}
	-- Empty Luau tables are encoded as JSON objects by Noctalia. Only include
	-- list-valued request members when they contain an item, otherwise the
	-- helper would receive `{}` where the protocol expects `[]`.
	if #changes > 0 then
		request.changes = changes
	end
	if #monitorChanges > 0 then
		request.monitor_changes = monitorChanges
	end
	if #customKeybindChanges > 0 then
		request.custom_keybind_changes = customKeybindChanges
	end
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

local function configuredMonitorByName()
	local result = {}
	for _, monitor in ipairs(snapshot.monitors or {}) do
		result[monitor.name] = monitor
	end
	return result
end

local function monitorLayout()
	local result = {}
	local seen = {}
	local configured = configuredMonitorByName()
	for _, live in ipairs(noctalia.outputs() or {}) do
		local saved = configured[live.name]
		local monitor = {
			id = saved and saved.id or "live:" .. live.name,
			name = live.name,
			description = live.description or "",
			x = saved and saved.positioned and saved.x or live.x or 0,
			y = saved and saved.positioned and saved.y or live.y or 0,
			width = live.width or (saved and saved.width) or 1920,
			height = live.height or (saved and saved.height) or 1080,
			transform = saved and saved.transform or "normal",
			configured = saved ~= nil,
			connected = true,
			focused = live.focused == true,
		}
		if monitorDrafts[monitor.id] then
			monitor.x = monitorDrafts[monitor.id].x
			monitor.y = monitorDrafts[monitor.id].y
			monitor.transform = monitorDrafts[monitor.id].transform
		end
		table.insert(result, monitor)
		seen[live.name] = true
	end
	for _, saved in ipairs(snapshot.monitors or {}) do
		if not seen[saved.name] then
			local monitor = {
				id = saved.id,
				name = saved.name,
				description = "",
				x = saved.positioned and saved.x or 0,
				y = saved.positioned and saved.y or 0,
				width = saved.width or 1920,
				height = saved.height or 1080,
				transform = saved.transform or "normal",
				configured = true,
				connected = false,
				focused = false,
			}
			if monitorDrafts[monitor.id] then
				monitor.x = monitorDrafts[monitor.id].x
				monitor.y = monitorDrafts[monitor.id].y
				monitor.transform = monitorDrafts[monitor.id].transform
			end
			table.insert(result, monitor)
		end
	end
	table.sort(result, function(a, b)
		if a.y == b.y then
			return a.x < b.x
		end
		return a.y < b.y
	end)
	return result
end

local function setMonitorDraft(monitor, x, y, transform)
	monitorDrafts[monitor.id] = {
		id = monitor.id,
		name = monitor.name,
		x = math.floor((tonumber(x) or monitor.x) + 0.5),
		y = math.floor((tonumber(y) or monitor.y) + 0.5),
		transform = transform or monitor.transform or "normal",
	}
	status = "dirty"
	statusMessage = ""
	render()
end

local function monitorDimensions(monitor)
	local transform = monitor.transform or "normal"
	local rotated = transform == "90" or transform == "270" or transform == "flipped-90" or transform == "flipped-270"
	if rotated then
		return monitor.height, monitor.width
	end
	return monitor.width, monitor.height
end

local function monitorCanvasGeometry(monitors)
	local canvasWidth = 550
	local canvasHeight = 250
	local minX, minY = monitors[1].x, monitors[1].y
	local firstWidth, firstHeight = monitorDimensions(monitors[1])
	local maxX = monitors[1].x + firstWidth
	local maxY = monitors[1].y + firstHeight
	for _, monitor in ipairs(monitors) do
		local width, height = monitorDimensions(monitor)
		minX = math.min(minX, monitor.x)
		minY = math.min(minY, monitor.y)
		maxX = math.max(maxX, monitor.x + width)
		maxY = math.max(maxY, monitor.y + height)
	end
	local layoutWidth = math.max(1, maxX - minX)
	local layoutHeight = math.max(1, maxY - minY)
	local horizontalReserve = 24 + (#monitors * 8)
	local scale = math.min((canvasWidth - horizontalReserve) / layoutWidth, (canvasHeight - 30) / layoutHeight)
	return {
		width = canvasWidth,
		height = canvasHeight,
		scale = scale,
		minX = minX,
		minY = minY,
		maxX = maxX,
		maxY = maxY,
	}
end

local function findMonitor(id)
	for _, monitor in ipairs(monitorLayout()) do
		if monitor.id == id then
			return monitor
		end
	end
	return nil
end

local function dropMonitorRelative(payload, target)
	local relation, targetId = tostring(target):match("^(%a+):(.+)$")
	local moved = findMonitor(payload)
	local anchor = findMonitor(targetId)
	if moved == nil or anchor == nil or moved.id == anchor.id then
		return
	end
	local movedWidth, movedHeight = monitorDimensions(moved)
	local anchorWidth, anchorHeight = monitorDimensions(anchor)
	local x, y = anchor.x, anchor.y
	if relation == "before" then
		x = anchor.x - movedWidth
	elseif relation == "after" then
		x = anchor.x + anchorWidth
	elseif relation == "above" then
		y = anchor.y - movedHeight
	elseif relation == "below" then
		y = anchor.y + anchorHeight
	else
		return
	end
	setMonitorDraft(moved, x, y, moved.transform)
end

local function relativeDropZone(key, value, width, height, children)
	return ui.dropZone({
		key = key,
		accepts = { "monitor" },
		value = value,
		onDrop = dropMonitorRelative,
		enabled = not busy,
		expandOnDrag = false,
		hitSlop = 3,
		width = width,
		height = height,
		align = "center",
		justify = "center",
		radius = 7,
	}, children or {})
end

local function monitorCard(monitor, scale)
	local width, height = monitorDimensions(monitor)
	local cardWidth = math.max(72, math.floor(width * scale + 0.5))
	local cardHeight = math.max(46, math.floor(height * scale + 0.5))
	local contents = {
		ui.label({ text = monitor.name, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
	}
	if cardHeight >= 62 and cardWidth >= 100 then
		table.insert(contents, ui.label({
			text = tostring(width) .. "×" .. tostring(height),
			fontSize = 10,
			color = "on_surface_variant",
			maxLines = 1,
		}))
	end
	local card = ui.dragSource({
		key = "monitor-drag-" .. monitor.id,
		dragType = "monitor",
		payload = monitor.id,
		enabled = not busy,
		tooltip = tr("display.drag_hint"),
		previewAncestor = 0,
		liftFromLayout = true,
		width = cardWidth,
		height = cardHeight,
		padding = 5,
		gap = 2,
		align = "center",
		justify = "center",
		radius = 7,
		fill = monitor.focused and "secondary" or "surface_variant",
		border = monitorDrafts[monitor.id] and "primary" or "outline",
		borderWidth = monitorDrafts[monitor.id] and 2 or 1,
	}, contents)
	return relativeDropZone(
		"monitor-target-" .. monitor.id,
		"after:" .. monitor.id,
		cardWidth,
		cardHeight,
		{ card }
	)
end

local function monitorBands(monitors)
	local sorted = {}
	for _, monitor in ipairs(monitors) do
		table.insert(sorted, monitor)
	end
	table.sort(sorted, function(a, b)
		if a.y == b.y then
			return a.x < b.x
		end
		return a.y < b.y
	end)
	local bands = {}
	for _, monitor in ipairs(sorted) do
		local _width, height = monitorDimensions(monitor)
		local bottom = monitor.y + height
		local band = bands[#bands]
		if band == nil or monitor.y >= band.maxY then
			band = { minY = monitor.y, maxY = bottom, monitors = {} }
			table.insert(bands, band)
		else
			band.minY = math.min(band.minY, monitor.y)
			band.maxY = math.max(band.maxY, bottom)
		end
		table.insert(band.monitors, monitor)
	end
	for _, band in ipairs(bands) do
		table.sort(band.monitors, function(a, b)
			return a.x < b.x
		end)
	end
	return bands
end

local function monitorBand(band, geometry)
	local rowHeight = math.max(46, math.floor((band.maxY - band.minY) * geometry.scale + 0.5))
	local children = {}
	local cursorX = geometry.minX
	for _, monitor in ipairs(band.monitors) do
		local width, _height = monitorDimensions(monitor)
		local logicalGap = math.max(0, monitor.x - cursorX)
		local gapWidth = math.max(8, math.floor(logicalGap * geometry.scale + 0.5))
		table.insert(children, relativeDropZone(
			"monitor-before-" .. monitor.id,
			"before:" .. monitor.id,
			gapWidth,
			rowHeight
		))
		local topOffset = math.max(0, math.floor((monitor.y - band.minY) * geometry.scale + 0.5))
		local monitorChildren = {}
		if topOffset > 0 then
			table.insert(monitorChildren, ui.box({ width = 1, height = topOffset }))
		end
		table.insert(monitorChildren, monitorCard(monitor, geometry.scale))
		table.insert(children, ui.column({
			key = "monitor-position-" .. monitor.id,
			width = math.max(72, math.floor(width * geometry.scale + 0.5)),
			height = rowHeight,
			align = "center",
			justify = "start",
		}, monitorChildren))
		cursorX = math.max(cursorX, monitor.x + width)
	end
	local last = band.monitors[#band.monitors]
	table.insert(children, relativeDropZone(
		"monitor-after-" .. last.id,
		"after:" .. last.id,
		math.max(12, geometry.width - math.floor((cursorX - geometry.minX) * geometry.scale + 0.5) - 30),
		rowHeight
	))
	return ui.row({
		key = "monitor-band-" .. tostring(band.minY),
		width = geometry.width,
		height = rowHeight,
		align = "start",
		justify = "start",
	}, children)
end

local function monitorCanvas(monitors)
	if #monitors == 0 then
		return ui.column({
			padding = 22,
			gap = 8,
			align = "center",
			radius = 12,
			fill = "surface_variant",
		}, {
			ui.glyph({ name = "device-desktop-off", size = 30, color = "on_surface_variant" }),
			ui.label({ text = tr("display.empty"), color = "on_surface_variant" }),
		})
	end
	local geometry = monitorCanvasGeometry(monitors)
	local bands = monitorBands(monitors)
	local children = {}
	local previousMaxY = geometry.minY
	for _, band in ipairs(bands) do
		local anchor = band.monitors[1]
		local logicalGap = math.max(0, band.minY - previousMaxY)
		local gapHeight = math.max(8, math.floor(logicalGap * geometry.scale + 0.5))
		table.insert(children, relativeDropZone(
			"monitor-above-" .. anchor.id,
			"above:" .. anchor.id,
			geometry.width,
			gapHeight
		))
		table.insert(children, monitorBand(band, geometry))
		previousMaxY = band.maxY
	end
	local lastBand = bands[#bands]
	local lastAnchor = lastBand.monitors[1]
	table.insert(children, relativeDropZone(
		"monitor-below-" .. lastAnchor.id,
		"below:" .. lastAnchor.id,
		geometry.width,
		12
	))
	return ui.column({
		width = geometry.width + 20,
		minHeight = geometry.height + 20,
		padding = 10,
		align = "center",
		justify = "center",
		radius = 12,
		fill = "surface_variant",
		border = "outline",
		borderWidth = 1,
	}, children)
end

local function monitorDetails(monitor)
	local transforms = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
	local selected = 0
	for index, value in ipairs(transforms) do
		if value == monitor.transform then
			selected = index - 1
			break
		end
	end
	return ui.column({
		key = "monitor-details-" .. monitor.id,
		gap = 8,
		padding = 10,
		radius = 9,
		fill = "surface_variant",
		border = monitorDrafts[monitor.id] and "primary" or "outline",
		borderWidth = 1,
		align = "stretch",
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "device-desktop", color = monitor.connected and "primary" or "on_surface_variant" }),
			ui.label({ text = monitor.name, fontWeight = "bold", flexGrow = 1 }),
			ui.label({
				text = monitor.connected and tr("display.connected") or tr("display.offline"),
				fontSize = 11,
				color = monitor.connected and "primary" or "on_surface_variant",
			}),
		}),
		ui.label({
			text = tostring(monitor.width) .. "×" .. tostring(monitor.height) .. "  ·  "
				.. tostring(monitor.x) .. ", " .. tostring(monitor.y),
			fontSize = 11,
			color = "on_surface_variant",
		}),
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = "X", fontSize = 11 }),
			ui.input({
				key = "monitor-x-" .. monitor.id .. "-" .. tostring(monitor.x),
				value = tostring(monitor.x),
				width = 88,
				controlSize = "sm",
				onSubmit = function(value)
					setMonitorDraft(monitor, tonumber(value), monitor.y, monitor.transform)
				end,
			}),
			ui.label({ text = "Y", fontSize = 11 }),
			ui.input({
				key = "monitor-y-" .. monitor.id .. "-" .. tostring(monitor.y),
				value = tostring(monitor.y),
				width = 88,
				controlSize = "sm",
				onSubmit = function(value)
					setMonitorDraft(monitor, monitor.x, tonumber(value), monitor.transform)
				end,
			}),
			ui.label({ text = tr("display.rotation"), fontSize = 11 }),
			ui.select({
				key = "monitor-transform-" .. monitor.id,
				options = transforms,
				selectedIndex = selected,
				flexGrow = 1,
				controlSize = "sm",
				onChange = function(index, _text)
					local wanted = (tonumber(index) or 0) + 1
					setMonitorDraft(monitor, monitor.x, monitor.y, transforms[wanted] or monitor.transform)
				end,
			}),
		}),
	})
end

local function displaysView()
	local monitors = monitorLayout()
	local children = {
		sectionTitle(tr("display.title"), tr("display.description")),
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "drag-drop", color = "primary" }),
			ui.label({ text = tr("display.drag_hint"), color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
		}),
		monitorCanvas(monitors),
	}
	for _, monitor in ipairs(monitors) do
		table.insert(children, monitorDetails(monitor))
	end
	table.insert(children, ui.separator({}))
	table.insert(children, ui.label({ text = tr("display.policy"), fontWeight = "bold" }))
	for _, field in ipairs(snapshot.fields or {}) do
		if field.category == "displays" then
			table.insert(children, fieldCard(field))
		end
	end
	return ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, children)
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

sectionTitle = function(title, description)
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
			flexGrow = field.category == "keybinds" and 1 or nil,
			controlSize = field.category == "keybinds" and "lg" or nil,
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

fieldCard = function(field)
	return ui.column({
		key = "field-" .. field.id,
		gap = 8,
		padding = 12,
		radius = 10,
		fill = "surface_variant",
		border = drafts[field.id] ~= nil and "primary" or "outline",
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

local function keybindText(value)
	if type(value) == "table" then
		return table.concat(value, ", ")
	end
	return tostring(value or "")
end

local function keybindLabel(action)
	local label = tostring(action):gsub("_", " ")
	return label:sub(1, 1):upper() .. label:sub(2)
end

local function setBuiltinKeybindDraft(field, value)
	if value == keybindText(field.value) then
		drafts[field.id] = nil
	else
		drafts[field.id] = value
	end
	status = hasDrafts() and "dirty" or "ready"
	statusMessage = ""
end

local function builtinKeybindCard(field)
	local value = drafts[field.id] ~= nil and tostring(drafts[field.id]) or keybindText(field.value)
	return ui.row({
		key = "keybind-" .. field.id,
		gap = 12,
		padding = 10,
		align = "center",
		radius = 9,
		fill = "surface_variant",
		border = drafts[field.id] ~= nil and "primary" or "outline",
		borderWidth = 1,
	}, {
		ui.column({ width = 210, gap = 2, align = "stretch" }, {
			ui.label({ text = keybindLabel(field.key), fontWeight = "medium", maxLines = 1 }),
			ui.label({
				text = field.configured and tr("keybind.configured") or tr("keybind.default"),
				fontSize = 10,
				color = "on_surface_variant",
			}),
		}),
		ui.input({
			key = "keybind-input-" .. field.id,
			value = value,
			flexGrow = 1,
			controlSize = "lg",
			placeholder = tr("keybind.unbound"),
			onChange = function(text)
				setBuiltinKeybindDraft(field, text)
				render()
			end,
			onSubmit = function(text)
				setBuiltinKeybindDraft(field, text)
				render()
			end,
		}),
	})
end

local function setCustomKeybindDraft(keybind, chord, command)
	if chord == keybind.chord and command == keybind.command then
		customKeybindDrafts[keybind.id] = nil
	else
		customKeybindDrafts[keybind.id] = {
			id = keybind.id,
			chord = chord,
			command = command,
		}
	end
	status = hasDrafts() and "dirty" or "ready"
	statusMessage = ""
end

local function customKeybindCard(keybind)
	local draft = customKeybindDrafts[keybind.id]
	local chord = draft and draft.chord or keybind.chord
	local command = draft and draft.command or keybind.command
	return ui.column({
		key = "custom-keybind-" .. keybind.id,
		gap = 7,
		padding = 10,
		align = "stretch",
		radius = 9,
		fill = "surface_variant",
		border = draft and "primary" or "outline",
		borderWidth = 1,
	}, {
		ui.row({ gap = 12, align = "center" }, {
			ui.input({
				key = "custom-chord-" .. keybind.id,
				value = chord,
				width = 220,
				controlSize = "lg",
				placeholder = tr("keybind.shortcut"),
				onChange = function(text)
					local current = customKeybindDrafts[keybind.id]
					setCustomKeybindDraft(keybind, text, current and current.command or keybind.command)
					render()
				end,
			}),
			ui.input({
				key = "custom-command-" .. keybind.id,
				value = command,
				flexGrow = 1,
				controlSize = "lg",
				placeholder = tr("keybind.command"),
				onChange = function(text)
					local current = customKeybindDrafts[keybind.id]
					setCustomKeybindDraft(keybind, current and current.chord or keybind.chord, text)
					render()
				end,
			}),
		}),
	})
end

local function keybindsView()
	local children = {
		sectionTitle(tr("keybind.title"), tr("keybind.description")),
		ui.label({ text = tr("keybind.builtin"), fontWeight = "bold" }),
		ui.label({ text = tr("keybind.multiple_hint"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
	}
	for _, field in ipairs(snapshot.fields or {}) do
		if field.category == "keybinds" and field.section == "keybinds" then
			table.insert(children, builtinKeybindCard(field))
		end
	end
	table.insert(children, ui.separator({}))
	table.insert(children, ui.label({ text = tr("keybind.custom"), fontWeight = "bold" }))
	if #(snapshot.custom_keybinds or {}) == 0 then
		table.insert(children, ui.label({ text = tr("keybind.custom_empty"), color = "on_surface_variant" }))
	else
		for _, keybind in ipairs(snapshot.custom_keybinds) do
			table.insert(children, customKeybindCard(keybind))
		end
	end
	table.insert(children, ui.separator({}))
	table.insert(children, ui.label({ text = tr("keybind.commands"), fontWeight = "bold" }))
	for _, field in ipairs(snapshot.fields or {}) do
		if field.category == "keybinds" and field.section == "actions" then
			table.insert(children, fieldCard(field))
		end
	end
	return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, children)
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
			fill = "surface_variant",
		}, {
			ui.glyph({ name = "alert-triangle", color = "tertiary" }),
			ui.label({ text = warning, color = "on_surface_variant", flexGrow = 1, maxLines = 4 }),
		}))
	end
	local layoutOptions = {}
	local selectedLayout = 0
	for index, layout in ipairs(workspaceLayouts) do
		table.insert(layoutOptions, layout.label)
		if layout.value == workspaceLayout then
			selectedLayout = index - 1
		end
	end
	local workspaceDetail = ""
	if workspaceNumber > 0 then
		workspaceDetail = tr("overview.workspace_layout.workspace") .. " " .. tostring(workspaceNumber) .. " · " .. panelOutput
	end
	local layoutDetail = workspaceLayoutMessage
	if layoutDetail ~= "" and workspaceDetail ~= "" then
		layoutDetail = layoutDetail .. " · " .. workspaceDetail
	elseif layoutDetail == "" and workspaceDetail ~= "" then
		layoutDetail = workspaceDetail
	elseif layoutDetail == "" then
		layoutDetail = panelOutput
	end
	local children = {
		sectionTitle(tr("overview.title"), tr("overview.description")),
		ui.row({ gap = 16 }, {
			ui.column({ gap = 2, padding = 12, radius = 10, fill = "surface_variant", flexGrow = 1 }, {
				ui.label({ text = tostring(#(snapshot.fields or {})), fontSize = 26, fontWeight = "bold", color = "primary" }),
				ui.label({ text = tr("overview.typed_fields"), color = "on_surface_variant" }),
			}),
			ui.column({ gap = 2, padding = 12, radius = 10, fill = "surface_variant", flexGrow = 1 }, {
				ui.label({ text = snapshot.helper_version or "?", fontSize = 26, fontWeight = "bold", color = "primary" }),
				ui.label({ text = tr("overview.helper_version"), color = "on_surface_variant" }),
			}),
		}),
		ui.column({ gap = 8, padding = 12, radius = 10, fill = "surface_variant", align = "stretch" }, {
			ui.row({ gap = 10, align = "center" }, {
				ui.glyph({ name = "layout-grid", color = "primary", size = 22 }),
				ui.column({ gap = 2, flexGrow = 1 }, {
					ui.label({ text = tr("overview.workspace_layout"), fontWeight = "bold" }),
					ui.label({
						text = tr("overview.workspace_layout.description"),
						color = "on_surface_variant",
						maxLines = 2,
					}),
				}),
				ui.select({
					key = "active-workspace-layout-" .. panelOutput,
					width = 190,
					options = layoutOptions,
					selectedIndex = selectedLayout,
					enabled = not workspaceLayoutBusy and workspaceNumber > 0,
					onChange = function(index, _text)
						local wanted = workspaceLayouts[(tonumber(index) or 0) + 1]
						if wanted then
							setWorkspaceLayout(wanted.value)
						end
					end,
				}),
			}),
			ui.label({
				text = layoutDetail,
				color = workspaceLayoutMessage == "" and "on_surface_variant" or "tertiary",
				fontSize = 11,
				maxLines = 2,
			}),
		}),
		ui.label({ text = tr("overview.resolved_files"), fontWeight = "bold" }),
		ui.column({ gap = 2, padding = 10, radius = 10, fill = "surface_variant", align = "stretch" }, fileRows),
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
	elseif activeCategory == "displays" then
		body = displaysView()
	elseif activeCategory == "keybinds" then
		body = keybindsView()
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
	panelOutput = noctalia.state.get("panel_output") or ""
	if panelOutput == "" then
		panelOutput = noctalia.focusedOutputName() or ""
	end
	queryWorkspaceLayout()
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

function onIpc(event, payload)
	if event == "reload" then
		loadSnapshot(true)
	elseif event == "apply" then
		writeRequest("apply")
	elseif event == "category" then
		for _, category in ipairs(categories) do
			if category.id == payload then
				activeCategory = payload
				render()
				return
			end
		end
	end
end
