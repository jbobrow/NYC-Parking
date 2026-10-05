// A live, simplified version of the app's map, with its two views:
//  - Cleaning days: every block face as a curb stripe split by restricted day,
//    with day pills along the street when zoomed in and runs of day-colored
//    dots when zoomed out.
//  - Days until move: one line per block, colored by how soon a car parked
//    there now would have to move, with countdown pills when zoomed in.
// Block data comes from data/blocks.json and ASP holidays from
// data/holidays.json (both built by scripts/build_web_data.py).

const DAYS = [
  { key: "MON",   short: "MON", letter: "M",  name: "Mon", css: "mon", color: "#3d85f5" },
  { key: "TUES",  short: "TUE", letter: "T",  name: "Tue", css: "tue", color: "#f5802e" },
  { key: "WED",   short: "WED", letter: "W",  name: "Wed", css: "wed", color: "#33c780" },
  { key: "THURS", short: "THU", letter: "TH", name: "Thu", css: "thu", color: "#ad52eb" },
  { key: "FRI",   short: "FRI", letter: "F",  name: "Fri", css: "fri", color: "#f04352" },
  { key: "SAT",   short: "SAT", letter: "SA", name: "Sat", css: "sat", color: "#f0bd1f" },
  { key: "SUN",   short: "SUN", letter: "SU", name: "Sun", css: "sun", color: "#4dc2e6" },
];
const DAY_INDEX = Object.fromEntries(DAYS.map((d, i) => [d.key, i]));

// Days-until-move scale, one step per day (7 = a week or more, or nothing
// scheduled). Same hand-tuned hue/saturation/brightness steps as the app.
const URGENCY = [
  [355, 0.82, 0.95], [12, 0.85, 0.96], [30, 0.88, 0.97], [48, 0.88, 0.97],
  [68, 0.80, 0.92], [88, 0.72, 0.86], [115, 0.66, 0.76], [140, 0.72, 0.64],
].map(([h, s, b]) => hsbToColor(h, s, b));
const MAX_LEVEL = URGENCY.length - 1;

const PILL_ZOOM = 15.5;   // pills + stripes at and above, dot runs below
const CLINTON_HILL = [-73.9662, 40.6885];
const FONT = 'ui-rounded, "SF Pro Rounded", "Nunito", system-ui, -apple-system, sans-serif';
const DEFAULT_READOUT = "Tap any block to see when street cleaning happens.";
const LAYERS = {
  days: ["stripes", "dots", "pills"],
  countdown: ["countdown-lines", "countdown-pills"],
};

const readout = document.getElementById("readout");
let blocks = null;
let mode = "countdown";
let selected = -1;
let refreshTimer = null;

const map = new maplibregl.Map({
  container: "map",
  style: "https://tiles.openfreemap.org/styles/dark",
  center: CLINTON_HILL,
  zoom: 16.2,
  minZoom: 10,
  maxPitch: 0,
  maxBounds: [[-74.35, 40.45], [-73.6, 40.95]],
  attributionControl: { compact: true },
});
map.addControl(new maplibregl.NavigationControl({ visualizePitch: false }), "top-right");
map.addControl(new maplibregl.GeolocateControl({
  positionOptions: { enableHighAccuracy: true },
  fitBoundsOptions: { maxZoom: 16.5 },
}), "top-right");
map.touchPitch.disable();
// The card is sized by flex layout; keep the canvas matched to it.
new ResizeObserver(() => map.resize()).observe(map.getContainer());

const dataPromise = Promise.all([
  fetch("data/blocks.json").then((r) => r.json()),
  fetch("data/holidays.json").then((r) => (r.ok ? r.json() : [])).catch(() => []),
]).then(([data, holidays]) => decode(data, holidays));

map.on("load", async () => {
  blocks = await dataPromise;
  updateCountdowns();
  tuneBasemap();
  addDayImages(blocks.keys);
  addCountdownImages();

  map.addSource("stripes", { type: "geojson", data: blocks.stripes });
  map.addSource("blocks", { type: "geojson", data: blocks.faces });

  // Lines sit above roads and buildings but under street names, so the names
  // stay legible.
  const layers = map.getStyle().layers;
  const firstLabel = (layers.find((l) => l.id.startsWith("highway_name"))
    ?? layers.find((l) => l.type === "symbol" && l.id.startsWith("place")))?.id;
  const lineWidth = (from) => ["interpolate", ["exponential", 2], ["zoom"],
    ...(from < PILL_ZOOM ? [10, 1, 13, 1.5] : []), PILL_ZOOM, 2.5, 17, 4, 18, 6, 19, 10, 20, 16];
  const symbolAlongStreet = (image) => ({
    "symbol-placement": "line-center",
    "icon-image": image,
    "icon-rotation-alignment": "map",
    "icon-keep-upright": true,
    "icon-padding": 3,
    "icon-size": ["interpolate", ["linear"], ["zoom"], PILL_ZOOM, 0.72, 16.5, 0.9, 17.5, 1],
  });

  map.addLayer({
    id: "selected",
    type: "line",
    source: "blocks",
    filter: ["==", ["get", "i"], -1],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: {
      "line-color": "#ffffff",
      "line-opacity": 0.85,
      "line-width": ["interpolate", ["exponential", 2], ["zoom"], 12, 5, 15.5, 7, 18, 12, 20, 22],
      "line-blur": 1,
    },
  }, firstLabel);
  map.addLayer({
    id: "stripes",
    type: "line",
    source: "stripes",
    minzoom: PILL_ZOOM,
    layout: { "line-cap": "butt", "line-join": "round" },
    paint: {
      "line-color": ["match", ["get", "d"], ...DAYS.flatMap((d, i) => [i, d.color]), "#888"],
      "line-width": lineWidth(PILL_ZOOM),
    },
  }, firstLabel);
  map.addLayer({
    id: "countdown-lines",
    type: "line",
    source: "blocks",
    layout: {
      "line-cap": "butt",
      "line-join": "round",
      // Greener lines draw on top where lines overlap at far zoom.
      "line-sort-key": ["get", "u"],
      visibility: "none",
    },
    paint: {
      "line-color": ["match", ["get", "u"], ...URGENCY.flatMap((u, i) => [i, u.hex]), "#888"],
      "line-width": lineWidth(10),
    },
  }, firstLabel);
  map.addLayer({
    id: "dots",
    type: "symbol",
    source: "blocks",
    minzoom: 11.5,
    maxzoom: PILL_ZOOM,
    layout: {
      "symbol-placement": "line-center",
      "icon-image": ["concat", "dots:", ["get", "k"]],
      "icon-rotation-alignment": "map",
      "icon-allow-overlap": true,
      "icon-ignore-placement": true,
      "icon-size": ["interpolate", ["linear"], ["zoom"], 11.5, 0.35, 13, 0.55, 14.5, 0.8, PILL_ZOOM, 1],
    },
  });
  map.addLayer({
    id: "pills",
    type: "symbol",
    source: "blocks",
    minzoom: PILL_ZOOM,
    layout: symbolAlongStreet(["concat", "pill:", ["get", "k"]]),
  });
  map.addLayer({
    id: "countdown-pills",
    type: "symbol",
    source: "blocks",
    minzoom: PILL_ZOOM,
    layout: { ...symbolAlongStreet(["concat", "cd:", ["to-string", ["get", "u"]]]), visibility: "none" },
  });

  const legend = document.querySelector(".legend.countdown");
  URGENCY.forEach((u, level) => {
    const chip = document.createElement("span");
    chip.className = "u";
    chip.style.background = u.hex;
    chip.style.color = u.ink;
    chip.textContent = level === MAX_LEVEL ? "7+" : String(level);
    legend.append(chip);
  });

  // Start with the attribution collapsed to its (i) button.
  map.getContainer().querySelector(".maplibregl-ctrl-attrib")?.classList.remove("maplibregl-compact-show");
  document.querySelectorAll(".modes button").forEach((button) => {
    button.addEventListener("click", () => setMode(button.dataset.mode));
  });
  setMode(mode);
  readout.textContent = DEFAULT_READOUT;

  const tappable = [...LAYERS.days, ...LAYERS.countdown];
  map.on("click", (e) => {
    const r = 14;
    const hit = map.queryRenderedFeatures(
      [[e.point.x - r, e.point.y - r], [e.point.x + r, e.point.y + r]],
      { layers: LAYERS[mode] },
    ).find((f) => f.properties.i !== undefined);
    select(hit ? hit.properties.i : -1);
  });
  for (const layer of tappable) {
    map.on("mouseenter", layer, () => { map.getCanvas().style.cursor = "pointer"; });
    map.on("mouseleave", layer, () => { map.getCanvas().style.cursor = ""; });
  }
});

// ── Views ────────────────────────────────────────────────────────────────────

function setMode(next) {
  mode = next;
  for (const [view, ids] of Object.entries(LAYERS)) {
    for (const id of ids) map.setLayoutProperty(id, "visibility", view === mode ? "visible" : "none");
  }
  document.querySelectorAll(".modes button").forEach((b) => {
    b.setAttribute("aria-pressed", String(b.dataset.mode === mode));
  });
  document.querySelector(".legend.days").hidden = mode !== "days";
  document.querySelector(".legend.countdown").hidden = mode !== "countdown";

  // Countdowns shift at midnight and as restrictions end; refresh while shown.
  clearInterval(refreshTimer);
  if (mode === "countdown") {
    if (updateCountdowns()) map.getSource("blocks").setData(blocks.faces);
    refreshTimer = setInterval(() => {
      if (updateCountdowns()) map.getSource("blocks").setData(blocks.faces);
      if (selected >= 0) select(selected);
    }, 5 * 60 * 1000);
  }
  if (selected >= 0) select(selected);
}

// ── Countdowns ───────────────────────────────────────────────────────────────

/** Recomputes each block's days until move; returns whether any changed. */
function updateCountdowns() {
  const cal = nycCalendar(blocks.holidays);
  blocks.countdowns = blocks.ruleSets.map((rules) => nextRestriction(rules, cal));
  let changed = false;
  for (const f of blocks.faces.features) {
    const c = blocks.countdowns[f.properties.r];
    const level = Math.min(c ? c.days : MAX_LEVEL, MAX_LEVEL);
    if (f.properties.u !== level) {
      f.properties.u = level;
      changed = true;
    }
  }
  return changed;
}

/** Today and the next seven days in New York, whatever the visitor's timezone. */
function nycCalendar(holidays) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", year: "numeric", month: "numeric", day: "numeric",
    hour: "numeric", minute: "numeric", hourCycle: "h23",
  }).formatToParts(new Date()).map((p) => [p.type, Number(p.value)]));
  const days = [];
  for (let offset = 0; offset <= 7; offset++) {
    const date = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + offset, 12));
    days.push({
      day: (date.getUTCDay() + 6) % 7,   // 0 = Monday
      holiday: holidays.has(date.toISOString().slice(0, 10)),
    });
  }
  return { minute: parts.hour * 60 + parts.minute, days };
}

/** Next restriction for a rule set, skipping holidays; null if none this week.
 *  A restriction still under way today counts as today (mirrors the app). */
function nextRestriction(rules, cal) {
  for (let offset = 0; offset < cal.days.length; offset++) {
    const { day, holiday } = cal.days[offset];
    if (holiday) continue;
    let best = null;
    for (const rule of rules) {
      if (!rule.days.includes(day) || rule.start === null) continue;
      if (offset === 0 && rule.end !== null) {
        const end = rule.end <= rule.start ? rule.end + 1440 : rule.end;
        if (cal.minute >= end) continue;
      }
      if (!best || rule.start < best.start) best = { days: offset, day, start: rule.start, end: rule.end };
    }
    if (best) return { ...best, now: offset === 0 && cal.minute >= best.start };
  }
  return null;
}

// ── Data ─────────────────────────────────────────────────────────────────────

function decode(data, holidayList) {
  const faces = [], stripes = [], info = [], keys = new Set();
  data.faces.forEach(([street, from, to, side, ruleSet, c], i) => {
    let x = c[0], y = c[1];
    let coords = [[x / 1e5, y / 1e5]];
    for (let j = 2; j < c.length; j += 2) {
      x += c[j]; y += c[j + 1];
      coords.push([x / 1e5, y / 1e5]);
    }
    // Reading order (east-ish), so multi-day stripes run MON→SUN left to right.
    const [a, b] = [coords[0], coords[coords.length - 1]];
    if (b[0] < a[0] || (b[0] === a[0] && b[1] < a[1])) coords = coords.reverse();

    const rules = data.rules[ruleSet];
    const days = [...new Set(rules.flatMap((r) => r[0].split(",")))]
      .map((k) => DAY_INDEX[k]).filter((d) => d !== undefined).sort((p, q) => p - q);
    if (!days.length) return;
    const key = days.map((d) => DAYS[d].key).join(",");
    keys.add(key);

    faces.push({ type: "Feature", properties: { k: key, i, r: ruleSet, u: MAX_LEVEL }, geometry: { type: "LineString", coordinates: coords } });
    splitLine(coords, days.length).forEach((piece, n) => {
      stripes.push({ type: "Feature", properties: { d: days[n], i }, geometry: { type: "LineString", coordinates: piece } });
    });
    info[i] = { street: data.names[street], from: data.names[from], to: data.names[to], side, rules, ruleSet };
  });
  // Rule sets with days and times parsed once, for the countdown math.
  const ruleSets = data.rules.map((rules) => rules.map(([days, start, end]) => ({
    days: days.split(",").map((k) => DAY_INDEX[k]).filter((d) => d !== undefined),
    start: minutes(start),
    end: minutes(end),
  })));
  return {
    faces: { type: "FeatureCollection", features: faces },
    stripes: { type: "FeatureCollection", features: stripes },
    info,
    keys: [...keys],
    ruleSets,
    holidays: new Set(holidayList.map((h) => h.date)),
  };
}

/** "8AM", "8:30AM" → minutes after midnight. */
function minutes(t) {
  const m = /^(\d{1,2})(?::(\d{2}))?\s*(AM|PM)$/i.exec(t.trim());
  if (!m) return null;
  return ((Number(m[1]) % 12) + (m[3].toUpperCase() === "PM" ? 12 : 0)) * 60 + Number(m[2] || 0);
}

/** Splits a [lon, lat] polyline into n consecutive pieces of equal length. */
function splitLine(coords, n) {
  if (n <= 1) return [coords];
  const k = Math.cos(coords[0][1] * Math.PI / 180);
  const cum = [0];
  for (let j = 1; j < coords.length; j++) {
    const dx = (coords[j][0] - coords[j - 1][0]) * k, dy = coords[j][1] - coords[j - 1][1];
    cum.push(cum[j - 1] + Math.hypot(dx, dy));
  }
  const total = cum[cum.length - 1];
  const at = (s) => {
    let j = 1;
    while (j < cum.length - 1 && cum[j] < s) j++;
    const span = cum[j] - cum[j - 1], t = span > 0 ? (s - cum[j - 1]) / span : 0;
    return [coords[j - 1][0] + (coords[j][0] - coords[j - 1][0]) * t,
            coords[j - 1][1] + (coords[j][1] - coords[j - 1][1]) * t];
  };
  const pieces = [];
  for (let p = 0; p < n; p++) {
    const s0 = total * p / n, s1 = total * (p + 1) / n;
    const piece = [at(s0)];
    for (let j = 1; j < coords.length - 1; j++) if (cum[j] > s0 && cum[j] < s1) piece.push(coords[j]);
    piece.push(at(s1));
    pieces.push(piece);
  }
  return pieces;
}

// ── Basemap ──────────────────────────────────────────────────────────────────

/** Lifts OpenFreeMap's near-black dark style toward a blue-gray palette like the
 *  app's Apple dark map, so streets read clearly under the colored lines. */
function tuneBasemap() {
  const paint = {
    background: { "background-color": "#16181e" },
    landuse_residential: { "fill-color": "#16181e", "fill-opacity": 1 },
    landuse_park: { "fill-color": "#15261e" },
    landcover_wood: { "fill-color": "#15261e" },
    water: { "fill-color": "#0f1b2b" },
    building: { "fill-color": "#1d2029", "fill-outline-color": "#252936" },
    highway_path: { "line-color": "#23262f" },
    highway_minor: { "line-color": "#2b2f3a", "line-opacity": 1 },
    highway_major_casing: { "line-color": "#343946" },
    highway_major_inner: { "line-color": "#2f3440" },
    highway_motorway_casing: { "line-color": "#3a3f4d" },
    highway_motorway_inner: { "line-color": "#333845" },
    highway_name_other: { "text-color": "#8b909c", "text-halo-color": "#16181e" },
    highway_name_motorway: { "text-color": "#8b909c" },
    water_name: { "text-color": "#4f6480" },
    place_suburb: { "text-color": "#a0a5b1", "text-halo-color": "#16181e" },
    place_other: { "text-color": "#8b909c", "text-halo-color": "#16181e" },
  };
  for (const [layer, props] of Object.entries(paint)) {
    if (!map.getLayer(layer)) continue;
    for (const [prop, value] of Object.entries(props)) map.setPaintProperty(layer, prop, value);
  }
}

// ── Pill and dot images ──────────────────────────────────────────────────────

const RATIO = Math.max(2, Math.ceil(window.devicePixelRatio || 1));

function addDayImages(keys) {
  for (const key of keys) {
    const days = key.split(",").map((k) => DAY_INDEX[k]);
    const label = (d) => (days.length <= 2 ? DAYS[d].short : DAYS[d].letter);
    const segments = days.map((d) => ({ text: label(d), fill: DAYS[d].color, ink: "#fff" }));
    map.addImage(`pill:${key}`, drawPill(segments, RATIO), { pixelRatio: RATIO });
    map.addImage(`dots:${key}`, drawDots(days, RATIO), { pixelRatio: RATIO });
  }
}

function addCountdownImages() {
  URGENCY.forEach((u, level) => {
    const segment = { text: countdownLabel(level), fill: u.hex, ink: u.ink };
    map.addImage(`cd:${level}`, drawPill([segment], RATIO), { pixelRatio: RATIO });
  });
}

function countdownLabel(level) {
  if (level >= MAX_LEVEL) return "7+ DAYS";
  return level === 0 ? "TODAY" : level === 1 ? "1 DAY" : `${level} DAYS`;
}

/** The app's pill: one colored segment per entry, in a capsule with a soft shadow. */
function drawPill(segments, r) {
  const font = `700 ${11 * r}px ${FONT}`;
  const ctx = document.createElement("canvas").getContext("2d");
  ctx.font = font;
  const widths = segments.map((s, i) => ctx.measureText(s.text).width
    + ((i === 0 ? 9 : 5) + (i === segments.length - 1 ? 9 : 5)) * r);
  const m = 3 * r, h = 21 * r, w = widths.reduce((a, b) => a + b, 0);
  const canvas = ctx.canvas;
  canvas.width = Math.ceil(w + 2 * m);
  canvas.height = Math.ceil(h + 2 * m);
  const c = canvas.getContext("2d");

  c.save();
  c.shadowColor = "rgba(0,0,0,0.35)";
  c.shadowBlur = 3 * r;
  c.shadowOffsetY = 1 * r;
  c.beginPath();
  c.roundRect(m, m, w, h, h / 2);
  c.fillStyle = "#000";
  c.fill();
  c.restore();

  c.save();
  c.beginPath();
  c.roundRect(m, m, w, h, h / 2);
  c.clip();
  let x = m;
  segments.forEach((s, i) => {
    c.fillStyle = s.fill;
    c.fillRect(x, m, widths[i] + 0.5, h);
    c.fillStyle = s.ink;
    c.font = font;
    c.textBaseline = "middle";
    c.fillText(s.text, x + (i === 0 ? 9 : 5) * r, m + h / 2 + 0.5 * r);
    x += widths[i];
  });
  c.restore();
  return c.getImageData(0, 0, canvas.width, canvas.height);
}

/** A row of day-colored dots, laid along the street by the symbol layer. */
function drawDots(days, r) {
  const d = 7 * r, gap = 3 * r, m = 1.5 * r;
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(days.length * d + (days.length - 1) * gap + 2 * m);
  canvas.height = Math.ceil(d + 2 * m);
  const c = canvas.getContext("2d");
  days.forEach((day, i) => {
    c.beginPath();
    c.arc(m + d / 2 + i * (d + gap), m + d / 2, d / 2, 0, Math.PI * 2);
    c.fillStyle = DAYS[day].color;
    c.fill();
  });
  return c.getImageData(0, 0, canvas.width, canvas.height);
}

/** HSB → { hex, ink }, where ink is the text color that reads on it. */
function hsbToColor(h, s, v) {
  const f = (n) => {
    const k = (n + h / 60) % 6;
    return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
  };
  const [r, g, b] = [f(5), f(3), f(1)];
  const hex = "#" + [r, g, b].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("");
  const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return { hex, ink: luminance > 0.6 ? "rgba(0,0,0,0.8)" : "#fff" };
}

// ── Readout ──────────────────────────────────────────────────────────────────

const SIDES = { N: "north side", S: "south side", E: "east side", W: "west side" };

function select(i) {
  selected = i;
  map.setFilter("selected", ["==", ["get", "i"], i]);
  const block = i >= 0 ? blocks.info[i] : null;
  if (!block) {
    readout.textContent = DEFAULT_READOUT;
    return;
  }
  const between = [block.from, block.to].filter(Boolean).map(titleCase).join(" → ");
  const where = [between, SIDES[block.side]].filter(Boolean).join(", ");
  const rules = block.rules.map(([days, start, end]) => {
    const list = days.split(",").map((k) => DAYS[DAY_INDEX[k]]).filter(Boolean);
    const pills = list.map((d) => `<span class="d ${d.css}">${list.length <= 2 ? d.short : d.letter}</span>`).join("");
    return `<span class="rule"><span class="pills">${pills}</span>${formatTime(start)}–${formatTime(end)}</span>`;
  }).join("");
  const move = mode === "countdown" ? `<span class="move">${moveText(blocks.countdowns[block.ruleSet])}</span>` : "";
  readout.innerHTML = `${escape(titleCase(block.street))}`
    + (where ? `<br><span class="where">${escape(where)}</span>` : "")
    + move
    + `<span class="rules">${rules}</span>`;
}

/** "Move by Tue 9:30am · in 4 days", with the block's countdown color. */
function moveText(c) {
  const level = Math.min(c ? c.days : MAX_LEVEL, MAX_LEVEL);
  const u = URGENCY[level];
  const chip = `<span class="u" style="background:${u.hex};color:${u.ink}">${countdownLabel(level)}</span>`;
  if (!c) return `${chip} No cleaning in the next week`;
  const time = clock(c.start);
  if (c.now) return `${chip} Cleaning now, until ${clock(c.end)}`;
  if (c.days === 0) return `${chip} Move by ${time} today`;
  if (c.days === 1) return `${chip} Move by ${time} tomorrow`;
  return `${chip} Move by ${DAYS[c.day].name} ${time}`;
}

function clock(mins) {
  const h = Math.floor(mins / 60) % 24, m = mins % 60;
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}${m ? `:${String(m).padStart(2, "0")}` : ""}${h < 12 ? "am" : "pm"}`;
}

function titleCase(s) {
  return s.toLowerCase().replace(/\b[a-z]/g, (ch) => ch.toUpperCase());
}

function formatTime(t) {
  return t.replace(/(AM|PM)$/, (m) => m.toLowerCase());
}

function escape(s) {
  return s.replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch]));
}

// The repark alarm stand-in counts down like the Lock Screen one, its bar
// filling as it goes. Starts over when it reaches zero.
(function reparkCountdown() {
  const time = document.querySelector(".activity-time");
  const bar = document.querySelector(".activity-bar span");
  if (!time || !bar || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const total = 40 * 60, start = 23 * 60 + 53;
  let left = start;
  const show = () => {
    time.textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;
    bar.style.width = `${(1 - left / total) * 100}%`;
  };
  show();
  setInterval(() => { left = left > 0 ? left - 1 : start; show(); }, 1000);
})();
