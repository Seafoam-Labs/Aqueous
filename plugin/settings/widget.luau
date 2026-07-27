--!nonstrict

local PANEL_ID = "aqueous/settings:panel"

local function render()
	barWidget.setImage("aqueous.png")
	barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function update()
	render()
end

function onClick()
	noctalia.state.set("panel_output", barWidget.outputName() or noctalia.focusedOutputName() or "")
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	if noctalia.commandExists("aqueous-settings") then
		noctalia.runAsync("aqueous-settings")
	else
		noctalia.state.set("panel_output", barWidget.outputName() or noctalia.focusedOutputName() or "")
		noctalia.togglePanel(PANEL_ID)
	end
end

function onIpc(event, _payload)
	if event == "toggle" or event == "open" then
		noctalia.state.set("panel_output", barWidget.outputName() or noctalia.focusedOutputName() or "")
		noctalia.togglePanel(PANEL_ID)
	end
end
