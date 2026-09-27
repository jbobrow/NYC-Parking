// A live, simplified version of the app's cleaning-days map: every block face
// in the city as a curb stripe split by restricted day, with day pills along
// the street when zoomed in and runs of day-colored dots when zoomed out.
// Block data comes from data/blocks.json (scripts/build_web_data.py).

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

const PILL_ZOOM = 15.5;   // pills + stripes at and above, dot runs below
const CLINTON_HILL = [-73.9662, 40.6885];
const FONT = 'ui-rounded, "SF Pro Rounded", "Nunito", system-ui, -apple-system, sans-serif';
const DEFAULT_READOUT = "Tap any block to see when street cleaning happens.";

const readout = document.getElementById("readout");

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

const blocksPromise = fetch("data/blocks.json").then((r) => r.json()).then(decode);

map.on("load", async () => {
  const blocks = await blocksPromise;
  tuneBasemap();
  addDayImages(blocks.keys);

  map.addSource("stripes", { type: "geojson", data: blocks.stripes });
  map.addSource("blocks", { type: "geojson", data: blocks.faces });

  // Stripes sit above roads and buildings but under street names, so the
  // names stay legible.
  const layers = map.getStyle().layers;
  const firstLabel = (layers.find((l) => l.id.startsWith("highway_name"))
    ?? layers.find((l) => l.type === "symbol" && l.id.startsWith("place")))?.id;
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
      "line-width": ["interpolate", ["exponential", 2], ["zoom"], PILL_ZOOM, 2.5, 17, 4, 18, 6, 19, 10, 20, 16],
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
    layout: {
      "symbol-placement": "line-center",
      "icon-image": ["concat", "pill:", ["get", "k"]],
      "icon-rotation-alignment": "map",
      "icon-keep-upright": true,
      "icon-padding": 3,
      "icon-size": ["interpolate", ["linear"], ["zoom"], PILL_ZOOM, 0.72, 16.5, 0.9, 17.5, 1],
    },
  });

  readout.textContent = DEFAULT_READOUT;
  // Start with the attribution collapsed to its (i) button.
  map.getContainer().querySelector(".maplibregl-ctrl-attrib")?.classList.remove("maplibregl-compact-show");

  map.on("click", (e) => {
    const r = 14;
    const hit = map.queryRenderedFeatures(
      [[e.point.x - r, e.point.y - r], [e.point.x + r, e.point.y + r]],
      { layers: ["pills", "stripes", "dots"] },
    ).find((f) => f.properties.i !== undefined);
    if (!hit) {
      select(null);
      return;
    }
    select(blocks.info[hit.properties.i], hit.properties.i);
  });
  for (const layer of ["pills", "stripes", "dots"]) {
    map.on("mouseenter", layer, () => { map.getCanvas().style.cursor = "pointer"; });
    map.on("mouseleave", layer, () => { map.getCanvas().style.cursor = ""; });
  }
});

// ── Basemap ──────────────────────────────────────────────────────────────────

/** Lifts OpenFreeMap's near-black dark style toward a blue-gray palette like the
 *  app's Apple dark map, so streets read clearly under the colored stripes. */
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

// ── Data ─────────────────────────────────────────────────────────────────────

function decode(data) {
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

    faces.push({ type: "Feature", properties: { k: key, i }, geometry: { type: "LineString", coordinates: coords } });
    splitLine(coords, days.length).forEach((piece, n) => {
      stripes.push({ type: "Feature", properties: { d: days[n], i }, geometry: { type: "LineString", coordinates: piece } });
    });
    info[i] = { street: data.names[street], from: data.names[from], to: data.names[to], side, rules };
  });
  return {
    faces: { type: "FeatureCollection", features: faces },
    stripes: { type: "FeatureCollection", features: stripes },
    info,
    keys: [...keys],
  };
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

// ── Pill and dot images ──────────────────────────────────────────────────────

function addDayImages(keys) {
  const ratio = Math.max(2, Math.ceil(window.devicePixelRatio || 1));
  for (const key of keys) {
    const days = key.split(",").map((k) => DAY_INDEX[k]);
    map.addImage(`pill:${key}`, drawPill(days, ratio), { pixelRatio: ratio });
    map.addImage(`dots:${key}`, drawDots(days, ratio), { pixelRatio: ratio });
  }
}

/** The app's day pill: one colored segment per day, names for 1–2 days, letters for 3+. */
function drawPill(days, r) {
  const label = (d) => (days.length <= 2 ? DAYS[d].short : DAYS[d].letter);
  const font = `700 ${11 * r}px ${FONT}`;
  const ctx = document.createElement("canvas").getContext("2d");
  ctx.font = font;
  const widths = days.map((d, i) => ctx.measureText(label(d)).width
    + ((i === 0 ? 9 : 5) + (i === days.length - 1 ? 9 : 5)) * r);
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
  days.forEach((d, i) => {
    c.fillStyle = DAYS[d].color;
    c.fillRect(x, m, widths[i] + 0.5, h);
    c.fillStyle = "#fff";
    c.font = font;
    c.textBaseline = "middle";
    const pad = (i === 0 ? 9 : 5) * r;
    c.fillText(label(d), x + pad, m + h / 2 + 0.5 * r);
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

// ── Readout ──────────────────────────────────────────────────────────────────

const SIDES = { N: "north side", S: "south side", E: "east side", W: "west side" };

function select(block, i = -1) {
  map.setFilter("selected", ["==", ["get", "i"], i]);
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
  readout.innerHTML = `${escape(titleCase(block.street))}`
    + (where ? `<br><span class="where">${escape(where)}</span>` : "")
    + `<span class="rules">${rules}</span>`;
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
