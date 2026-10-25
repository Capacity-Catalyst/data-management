// Page runtime: loads data, renders charts, handles embed mode.
//   Full page:   index.html
//   One chart:   index.html?chart=<id>   (for iframes on the CC website)
import * as Plot from "https://cdn.jsdelivr.net/npm/@observablehq/plot@0.6.17/+esm";
import * as d3 from "https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm";
import { CHARTS } from "./charts.js";

const params = new URLSearchParams(location.search);
const only = params.get("chart");
const embed = Boolean(only);
document.documentElement.classList.toggle("embed", embed);

const main = document.getElementById("charts");

async function loadData() {
  if (window.CC_DATA) return window.CC_DATA; // used by offline previews
  const manifest = await (await fetch("data/manifest.json", { cache: "no-cache" })).json();
  const entries = await Promise.all(
    manifest.map(async (name) => [name, await (await fetch(`data/${name}.json`, { cache: "no-cache" })).json()]),
  );
  return Object.fromEntries(entries);
}

function table(doc, { columns, rows }) {
  const t = doc.createElement("table");
  t.innerHTML = `<thead><tr>${columns.map((c) => `<th scope="col">${c}</th>`).join("")}</tr></thead>`;
  const body = doc.createElement("tbody");
  for (const r of rows) {
    const tr = doc.createElement("tr");
    for (const v of r) {
      const td = doc.createElement("td");
      td.textContent = v ?? "";
      tr.append(td);
    }
    body.append(tr);
  }
  t.append(body);
  return t;
}

function card(chart, data) {
  const section = document.createElement("section");
  section.className = `card card-${chart.id}`;
  section.id = `chart-${chart.id}`;
  section.innerHTML = `<h2>${chart.title}</h2><p class="subtitle">${chart.subtitle}</p><div class="slot"></div>`;
  const slot = section.querySelector(".slot");

  if (chart.id !== "kpis") {
    const details = document.createElement("details");
    details.className = "data-table";
    details.innerHTML = "<summary>View data as a table</summary>";
    const wrap = document.createElement("div");
    wrap.className = "table-wrap";
    wrap.append(table(document, chart.table(data)));
    details.append(wrap);
    section.append(details);
  }

  let lastWidth = 0;
  const draw = () => {
    const width = Math.floor(slot.clientWidth);
    if (!width || Math.abs(width - lastWidth) < 8) return;
    lastWidth = width;
    try {
      slot.replaceChildren(chart.render({ Plot, d3, data, width, document }));
    } catch (err) {
      console.error(chart.id, err);
      slot.replaceChildren(Object.assign(document.createElement("p"), { className: "error", textContent: "This chart could not be drawn." }));
    }
    postHeight();
  };
  new ResizeObserver(draw).observe(slot);
  return section;
}

function postHeight() {
  if (!embed || window.parent === window) return;
  requestAnimationFrame(() =>
    window.parent.postMessage({ type: "cc-chart:height", chart: only, height: document.documentElement.scrollHeight }, "*"));
}

function embedCodes() {
  const base = location.href.split(/[?#]/)[0];
  const box = document.getElementById("embed-codes");
  for (const c of CHARTS) {
    const code = `<iframe src="${base}?chart=${c.id}" title="${c.title}" style="width:100%;border:0;" height="${c.id === "partners" ? 1200 : 480}" loading="lazy"></iframe>`;
    const row = document.createElement("div");
    row.className = "embed-row";
    row.innerHTML = `<strong>${c.title}</strong><code></code><button type="button">Copy</button>`;
    row.querySelector("code").textContent = code;
    row.querySelector("button").addEventListener("click", async (e) => {
      await navigator.clipboard.writeText(code);
      e.target.textContent = "Copied";
      setTimeout(() => (e.target.textContent = "Copy"), 1500);
    });
    box.append(row);
  }
}

try {
  const data = await loadData();
  const charts = embed ? CHARTS.filter((c) => c.id === only) : CHARTS;
  if (!charts.length) {
    main.innerHTML = `<p class="error">Unknown chart "${only}". Available: ${CHARTS.map((c) => c.id).join(", ")}.</p>`;
  } else {
    main.replaceChildren(...charts.map((c) => card(c, data)));
  }
  if (data.meta?.updated_at) {
    document.getElementById("updated").textContent =
      "Data updated " + new Date(data.meta.updated_at).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" }) + ".";
  }
  if (!embed) embedCodes();
  new ResizeObserver(postHeight).observe(document.body);
} catch (err) {
  console.error(err);
  main.innerHTML = '<p class="error">The data could not be loaded. Please try again later.</p>';
}
