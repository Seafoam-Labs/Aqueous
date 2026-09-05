.pragma library

function parse(mode) {
    const match = /^(\d+)x(\d+)(?:@([0-9]+(?:\.[0-9]+)?))?$/.exec(mode || '');
    return match ? {resolution: match[1]+'x'+match[2], width:Number(match[1]), height:Number(match[2]), refresh:match[3] || ''} : {resolution:'',refresh:''};
}
function format(mode) {
    if (!mode || !(mode.width > 0) || !(mode.height > 0)) return '';
    return mode.width+'x'+mode.height+(mode.refresh > 0 ? '@'+Number(mode.refresh.toFixed(3)) : '');
}
function resolutions(monitor) {
    const result = [];
    for (const mode of monitor?.modes || []) {
        const resolution = mode.width+'x'+mode.height;
        if (mode.width > 0 && mode.height > 0 && !result.includes(resolution)) result.push(resolution);
    }
    const configured = parse(monitor?.mode).resolution;
    if (configured && !result.includes(configured)) result.push(configured);
    return result;
}
function rates(monitor, resolution) {
    const result = [];
    for (const mode of monitor?.modes || []) {
        const rate = mode.refresh > 0 ? String(Number(mode.refresh.toFixed(3))) : '';
        if (rate && mode.width+'x'+mode.height === resolution && !result.includes(rate)) result.push(rate);
    }
    const configured = parse(monitor?.mode);
    if (configured.resolution === resolution && configured.refresh && !result.includes(configured.refresh)) result.push(configured.refresh);
    return result.sort((a,b) => Number(b)-Number(a));
}
function compose(resolution, refresh) {
    resolution = String(resolution).trim();
    refresh = String(refresh).trim();
    const dimensions = parse(resolution);
    if (!dimensions.width || !dimensions.height || dimensions.width > 100000 || dimensions.height > 100000 || dimensions.refresh) throw new Error('Enter a resolution as WIDTHxHEIGHT.');
    if (refresh && (!Number.isFinite(Number(refresh)) || Number(refresh) < 0.001 || Number(refresh) > 1000)) throw new Error('Refresh rate must be between 0.001 and 1000 Hz.');
    return resolution + (refresh ? '@'+Number(Number(refresh).toFixed(3)) : '');
}
