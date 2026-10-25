// Chart definitions for the public impact page.
//
// Each chart: { id, title, subtitle, render(ctx), table(data) }
//   ctx = { Plot, d3, data, width, document }
//   data = every site/data/*.json file, keyed by name (e.g. data.hosts_by_term)
// This file has no imports so it runs both in the browser and in tests.
//
// To add a chart: create a reporting.site_<name> view (db/030_site_views.sql),
// then add an entry to CHARTS below. Its id becomes the embed URL: ?chart=<id>

// Colors (validated for color-blind separation). Swap these for CC brand colors if needed,
// keeping one color per meaning across all charts.
export const COLORS = {
  externship: "#2a78d6",
  externshipLight: "#86b6ef",
  cerc: "#eb6834",
  cercGroups: ["#1baf7a", "#eda100", "#e87ba4", "#008300"],
  likert: ["#e34948", "#f2a7a6", "#c9c8c3", "#86b6ef", "#2a78d6"],
  neutral: "#a3a29c",
  ink: "#0b0b0b",
  muted: "#52514e",
};

const PROGRAM_LABEL = { "Externship": "Externship", "CERC (course-based)": "CERC" };
const PROGRAM_COLOR = { "Externship": COLORS.externship, "CERC": COLORS.cerc };

// Two-line tick label for narrow screens: "Summer 2024" -> "Sum\n'24"
const stackedTerm = (label) => shortTerm(label).replace(" ", "\n");
const fmtInt = (n) => (n == null ? "–" : Math.round(n).toLocaleString("en-US"));
const fmtUsd = (n) => (n == null ? "–" : "$" + Math.round(n).toLocaleString("en-US"));
const fmtPct = (n) => (n == null ? "–" : Math.round(n * 100) + "%");
const byKey = (rows, key = "sort_key") => [...rows].sort((a, b) => a[key] - b[key]);
const uniq = (xs) => [...new Set(xs)];
const SEASON_SHORT = { Spring: "Spr", Summer: "Sum", Fall: "Fall" };
const shortTerm = (label) => label.replace(/^(\w+) \d{2}(\d{2})$/, (_, s, y) => `${SEASON_SHORT[s] ?? s} '${y}`); // Summer 2024 -> Sum '24

function base(ctx, opts) {
  return {
    document: ctx.document,
    width: ctx.width,
    style: { fontFamily: "inherit", fontSize: "12px", color: COLORS.muted, background: "transparent", overflow: "visible" },
    ...opts,
  };
}

function html(doc, tag, attrs = {}, children = []) {
  const el = doc.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) k === "text" ? (el.textContent = v) : el.setAttribute(k, v);
  for (const c of [].concat(children)) if (c) el.append(c);
  return el;
}

function legend(doc, items) {
  return html(doc, "div", { class: "legend" },
    items.map(([label, color]) =>
      html(doc, "span", { class: "legend-item" }, [
        html(doc, "span", { class: "swatch", style: `background:${color}` }),
        html(doc, "span", { text: label }),
      ])));
}

function wrap(doc, ...nodes) {
  return html(doc, "div", { class: "chart-body" }, nodes);
}

// ---------------------------------------------------------------------------

export const CHARTS = [
  {
    id: "kpis",
    title: "Our impact at a glance",
    subtitle: "All cohorts since the 2018 externship pilot",
    render({ data, document: doc }) {
      const k = data.kpis[0];
      const r = (data.feedback_ratings || []).find((d) => d.question === "likely_to_recommend");
      const tiles = [
        [fmtInt(k.extern_placements), "extern placements"],
        [fmtInt(k.host_organizations), "host organizations"],
        [fmtInt(k.cerc_undergrad_placements), "CERC student placements"],
        [fmtInt(k.community_partners), "community partners"],
        [fmtUsd(k.stipends_paid), "in stipends paid"],
        [fmtInt(k.support_hours), "hours of data & PD support"],
      ];
      if (r) tiles.push([`${r.average.toFixed(1)}/10`, `average likelihood externs would recommend us (${r.responses} responses)`]);
      return html(doc, "div", { class: "kpis" },
        tiles.map(([v, l]) => html(doc, "div", { class: "kpi" }, [
          html(doc, "div", { class: "kpi-value", text: v }),
          html(doc, "div", { class: "kpi-label", text: l }),
        ])));
    },
    table: ({ kpis }) => ({
      columns: ["Measure", "Value"],
      rows: Object.entries(kpis[0]).map(([k, v]) => [k.replaceAll("_", " "), k.includes("stipend") ? fmtUsd(v) : fmtInt(v)]),
    }),
  },

  {
    id: "externs",
    title: "Externs per cohort",
    subtitle: "Externship placements each term (Fall 2018 and Spring 2019 were pilots)",
    render(ctx) {
      const rows = byKey(ctx.data.externs_by_term);
      return wrap(ctx.document, ctx.Plot.plot(base(ctx, {
        height: 260,
        marginTop: 24,
        marginBottom: ctx.width < 560 ? 40 : 30,
        x: { label: null, domain: rows.map((d) => d.term), tickFormat: ctx.width < 560 ? stackedTerm : undefined },
        y: { label: "Externs", grid: true, nice: true },
        marks: [
          ctx.Plot.barY(rows, { x: "term", y: "externs", fill: COLORS.externship, ry1: 4, insetLeft: 6, insetRight: 6,
            tip: { format: { x: true, y: true } } }),
          ctx.Plot.text(rows, { x: "term", y: "externs", text: (d) => d.externs, dy: -9, fill: COLORS.ink, fontWeight: 600 }),
          ctx.Plot.ruleY([0], { stroke: COLORS.neutral }),
        ],
      })));
    },
    table: ({ externs_by_term }) => ({
      columns: ["Term", "Externs"],
      rows: byKey(externs_by_term).map((d) => [d.term + (d.is_pilot ? " (pilot)" : ""), d.externs]),
    }),
  },

  {
    id: "hosts",
    title: "Host organizations per cohort",
    subtitle: "New host organizations and organizations returning to host again",
    render(ctx) {
      const rows = byKey(ctx.data.hosts_by_term);
      const terms = uniq(rows.map((d) => d.term));
      const totals = terms.map((t) => ({ term: t, hosts: rows.filter((d) => d.term === t).reduce((s, d) => s + d.hosts, 0) }));
      return wrap(ctx.document,
        legend(ctx.document, [["New", COLORS.externship], ["Returning", COLORS.externshipLight]]),
        ctx.Plot.plot(base(ctx, {
          height: 260,
          marginTop: 24,
          marginBottom: ctx.width < 560 ? 40 : 30,
          x: { label: null, domain: terms, tickFormat: ctx.width < 560 ? stackedTerm : undefined },
          y: { label: "Host organizations", grid: true, nice: true },
          color: { domain: ["New", "Returning"], range: [COLORS.externship, COLORS.externshipLight] },
          marks: [
            ctx.Plot.barY(rows, { x: "term", y: "hosts", fill: "status", order: ["New", "Returning"],
              stroke: "white", strokeWidth: 1, insetLeft: 6, insetRight: 6, tip: true }),
            ctx.Plot.text(totals, { x: "term", y: "hosts", text: "hosts", dy: -9, fill: COLORS.ink, fontWeight: 600 }),
            ctx.Plot.ruleY([0], { stroke: COLORS.neutral }),
          ],
        })));
    },
    table: ({ hosts_by_term }) => {
      const terms = uniq(byKey(hosts_by_term).map((d) => d.term));
      const get = (t, s) => hosts_by_term.find((d) => d.term === t && d.status === s)?.hosts ?? 0;
      return { columns: ["Term", "New", "Returning", "Total"], rows: terms.map((t) => [t, get(t, "New"), get(t, "Returning"), get(t, "New") + get(t, "Returning")]) };
    },
  },

  {
    id: "cerc",
    title: "CERC participants per semester",
    subtitle: "Course-based cohorts with Huston-Tillotson University (HTU) and Texas State",
    render(ctx) {
      const rows = byKey(ctx.data.cerc_by_term);
      const groups = ["Undergraduate", "Nonprofit mentor", "Developer", "Grad student"].filter((g) => rows.some((d) => d.participant_group === g));
      const terms = uniq(rows.map((d) => d.term));
      const uni = Object.fromEntries(rows.map((d) => [d.term, d.university]));
      const totals = terms.map((t) => ({ term: t, n: rows.filter((d) => d.term === t).reduce((s, d) => s + d.headcount, 0) }));
      const range = COLORS.cercGroups.slice(0, groups.length);
      return wrap(ctx.document,
        legend(ctx.document, groups.map((g, i) => [g, range[i]])),
        ctx.Plot.plot(base(ctx, {
          height: 280,
          marginTop: 24,
          marginBottom: ctx.width < 640 ? 58 : 44,
          x: { label: null, domain: terms, tickFormat: (t) => (ctx.width < 640 ? stackedTerm(t) : t) + "\n" + (ctx.width < 640 ? (uni[t] ?? "").replace("TX State", "TXST") : uni[t] ?? "") },
          y: { label: "Participants", grid: true, nice: true },
          color: { domain: groups, range },
          marks: [
            ctx.Plot.barY(rows, { x: "term", y: "headcount", fill: "participant_group", order: groups,
              stroke: "white", strokeWidth: 1, insetLeft: 4, insetRight: 4, tip: true }),
            ctx.Plot.text(totals, { x: "term", y: "n", text: "n", dy: -9, fill: COLORS.ink, fontWeight: 600 }),
            ctx.Plot.ruleY([0], { stroke: COLORS.neutral }),
          ],
        })));
    },
    table: ({ cerc_by_term }) => ({
      columns: ["Semester", "University", "Group", "Participants"],
      rows: byKey(cerc_by_term).map((d) => [d.term, d.university ?? "", d.participant_group, d.headcount]),
    }),
  },

  {
    id: "hours",
    title: "Hours of data and professional development support",
    subtitle: "Data work plus professional development (PD) hours delivered, by year",
    render(ctx) { return programByYear(ctx, ctx.data.hours_by_year, "total_hours", "Hours", fmtInt); },
    table: ({ hours_by_year }) => ({
      columns: ["Year", "Program", "Data hours", "PD hours", "Total"],
      rows: [...hours_by_year].sort((a, b) => a.year - b.year)
        .map((d) => [d.year, PROGRAM_LABEL[d.program] ?? d.program, fmtInt(d.data_hours), fmtInt(d.pd_hours), fmtInt(d.total_hours)]),
    }),
  },

  {
    id: "stipends",
    title: "Stipends paid to participants",
    subtitle: "Externship and CERC stipends, by year",
    render(ctx) { return programByYear(ctx, ctx.data.stipends_by_year, "stipends_paid", "Stipends ($)", fmtUsd); },
    table: ({ stipends_by_year }) => ({
      columns: ["Year", "Program", "Stipends paid"],
      rows: [...stipends_by_year].sort((a, b) => a.year - b.year).map((d) => [d.year, PROGRAM_LABEL[d.program] ?? d.program, fmtUsd(d.stipends_paid)]),
    }),
  },

  {
    id: "partners",
    title: "Our partner organizations over time",
    subtitle: "Each dot is a term a partner worked with us; lines show how long the relationship has lasted",
    render(ctx) {
      const rows = ctx.data.partner_timeline.map((d) => ({ ...d, program: PROGRAM_LABEL[d.program] ?? d.program }));
      const terms = uniq(byKey(rows).map((d) => d.term));
      const spans = Object.values(rows.reduce((acc, d) => {
        const s = (acc[d.partner] ??= { partner: d.partner, first: d, last: d, n: new Set() });
        if (d.sort_key < s.first.sort_key) s.first = d;
        if (d.sort_key > s.last.sort_key) s.last = d;
        s.n.add(d.term);
        return acc;
      }, {})).map((s) => ({ partner: s.partner, first: s.first.term, last: s.last.term, firstKey: s.first.sort_key, terms: s.n.size }));
      const order = spans.sort((a, b) => a.firstKey - b.firstKey || b.terms - a.terms || a.partner.localeCompare(b.partner)).map((s) => s.partner);
      const narrow = ctx.width < 640;
      const truncate = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
      return wrap(ctx.document,
        legend(ctx.document, [["Externship", COLORS.externship], ["CERC", COLORS.cerc]]),
        ctx.Plot.plot(base(ctx, {
          height: order.length * 17 + 90,
          marginLeft: narrow ? 150 : 250,
          marginTop: 70,
          x: { type: "point", domain: terms, axis: "top", label: null, tickRotate: -45, tickFormat: shortTerm, padding: 0.4 },
          y: { domain: order, label: null, tickFormat: (s) => truncate(s, narrow ? 20 : 34), tickSize: 0 },
          color: { domain: ["Externship", "CERC"], range: [COLORS.externship, COLORS.cerc] },
          marks: [
            ctx.Plot.gridX({ stroke: "#ecebe7", strokeOpacity: 1 }),
            ctx.Plot.ruleY(spans, { y: "partner", x1: "first", x2: "last", stroke: "#bdbcb6", strokeWidth: 2 }),
            ctx.Plot.dot(rows, { x: "term", y: "partner", fill: "program", r: 5, stroke: "white", strokeWidth: 1.5,
              channels: { Partner: "partner", Term: "term", Program: "program", Role: "role" },
              tip: { format: { x: false, y: false, fill: false } } }),
          ],
        })));
    },
    table: ({ partner_timeline }) => ({
      columns: ["Partner", "Term", "Program", "Role"],
      rows: [...partner_timeline].sort((a, b) => a.partner.localeCompare(b.partner) || a.sort_key - b.sort_key)
        .map((d) => [d.partner, d.term, PROGRAM_LABEL[d.program] ?? d.program, d.role]),
    }),
  },

  {
    id: "sectors",
    title: "Partners by area of focus",
    subtitle: "Number of partner organizations in each focus area, where recorded",
    render(ctx) {
      const unknown = ctx.data.partners_by_sector.find((d) => d.sector === "Not specified")?.partners ?? 0;
      const rows = ctx.data.partners_by_sector.filter((d) => d.sector !== "Not specified")
        .sort((a, b) => b.partners - a.partners || a.sector.localeCompare(b.sector));
      const label = (s) => s.charAt(0).toUpperCase() + s.slice(1);
      return wrap(ctx.document, ctx.Plot.plot(base(ctx, {
        height: rows.length * 22 + 40,
        marginLeft: ctx.width < 520 ? 150 : 190,
        marginRight: 28,
        x: { label: "Partners", grid: true, axis: "top", tickFormat: "d", ticks: Math.max(1, ...rows.map((d) => d.partners)) },
        y: { domain: rows.map((d) => d.sector), label: null, tickFormat: label, tickSize: 0 },
        marks: [
          ctx.Plot.barX(rows, { y: "sector", x: "partners", rx2: 4, insetTop: 3, insetBottom: 3, fill: COLORS.externship, tip: true }),
          ctx.Plot.text(rows, { y: "sector", x: "partners", text: "partners", dx: 10, fill: COLORS.ink }),
          ctx.Plot.ruleX([0], { stroke: COLORS.neutral }),
        ],
      })),
      unknown ? html(ctx.document, "p", { class: "note", text: `${unknown} partners do not have a focus area recorded yet.` }) : null);
    },
    table: ({ partners_by_sector }) => ({
      columns: ["Area of focus", "Partners"],
      rows: [...partners_by_sector].sort((a, b) => b.partners - a.partners).map((d) => [d.sector, d.partners]),
    }),
  },

  {
    id: "demographics",
    title: "Who we serve",
    subtitle: "Share of participants by self-identified ethnicity and gender. People may select more than one ethnicity, so shares can add up to more than 100%. Groups smaller than 3 are combined.",
    render(ctx) {
      const doc = ctx.document;
      const panels = [
        ["Externs: ethnicity", ctx.data.extern_demographics, "ethnicity", COLORS.externship],
        ["Externs: gender", ctx.data.extern_demographics, "gender", COLORS.externship],
        ["CERC undergraduates: ethnicity", ctx.data.cerc_demographics, "ethnicity", COLORS.cerc],
        ["CERC undergraduates: gender", ctx.data.cerc_demographics, "gender", COLORS.cerc],
      ];
      const cols = ctx.width >= 720 ? 2 : 1;
      const w = Math.floor((ctx.width - (cols - 1) * 32) / cols);
      return html(doc, "div", { class: "panels", style: `grid-template-columns:repeat(${cols},1fr)` },
        panels.map(([title, all, cat, color]) => {
          const rows = all.filter((d) => d.category === cat)
            .sort((a, b) => a.value.startsWith("Another") - b.value.startsWith("Another") || b.share - a.share);
          const note = all.find((d) => d.total_respondents)?.total_respondents;
          return html(doc, "div", { class: "panel" }, [
            html(doc, "h3", { text: title + (note ? ` (${note} survey responses)` : "") }),
            ctx.Plot.plot(base({ ...ctx, width: w }, {
              height: rows.length * 30,
              marginTop: 0,
              marginBottom: 0,
              marginLeft: 170,
              marginRight: 44,
              x: { domain: [0, 1], axis: null },
              y: { domain: rows.map((d) => d.value), label: null, tickSize: 0 },
              marks: [
                ctx.Plot.barX(rows, { y: "value", x: 1, fill: "#f0efec", insetTop: 5, insetBottom: 5 }),
                ctx.Plot.barX(rows, { y: "value", x: "share", fill: color, rx2: 4, insetTop: 5, insetBottom: 5,
                  channels: { Count: (d) => d.respondents ?? d.students }, tip: { format: { x: (v) => fmtPct(v) } } }),
                ctx.Plot.text(rows, { y: "value", x: "share", text: (d) => fmtPct(d.share), dx: 8, textAnchor: "start", fill: COLORS.ink }),
              ],
            })),
          ]);
        }));
    },
    table: ({ extern_demographics, cerc_demographics }) => ({
      columns: ["Group", "Category", "Value", "Count", "Share"],
      rows: [
        ...extern_demographics.map((d) => ["Externs", d.category, d.value, d.respondents, fmtPct(d.share)]),
        ...cerc_demographics.map((d) => ["CERC undergraduates", d.category, d.value, d.students, fmtPct(d.share)]),
      ],
    }),
  },

  {
    id: "feedback",
    title: "What externs say about the experience",
    subtitle: "Anonymous end-of-externship survey. Bars are centered on neutral: agreement to the right, disagreement to the left.",
    render(ctx) {
      const doc = ctx.document;
      const labels = ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"];
      const statements = uniq(ctx.data.feedback_likert.map((d) => d.statement));
      const items = statements.map((s) => {
        const rows = ctx.data.feedback_likert.filter((d) => d.statement === s);
        const n = rows.reduce((t, d) => t + d.responses, 0);
        const share = (score) => (rows.find((d) => d.score === score)?.responses ?? 0) / n;
        const p = [1, 2, 3, 4, 5].map(share);
        let x = -(p[0] + p[1] + p[2] / 2);
        const segs = p.map((v, i) => { const seg = { x1: x, x2: x + v, score: i + 1, label: labels[i], share: v }; x += v; return seg; });
        return { statement: s, n, segs, agree: p[3] + p[4], negative: rows[0]?.negatively_worded };
      }).sort((a, b) => b.agree - a.agree);

      return html(doc, "div", {}, [
        legend(doc, labels.map((l, i) => [l, COLORS.likert[i]])),
        ...items.map((it) => html(doc, "div", { class: "likert-row" }, [
          html(doc, "div", { class: "likert-label", text: it.statement + (it.negative ? " *" : "") }),
          ctx.Plot.plot(base(ctx, {
            height: 34,
            marginTop: 2, marginBottom: 2, marginLeft: 0, marginRight: 0,
            x: { domain: [-1, 1], axis: null },
            y: { axis: null },
            color: { domain: [1, 2, 3, 4, 5], range: COLORS.likert },
            marks: [
              ctx.Plot.barX(it.segs.filter((d) => d.share > 0), { x1: "x1", x2: "x2", fill: "score", stroke: "white", strokeWidth: 1,
                channels: { Response: "label", Share: (d) => fmtPct(d.share) }, tip: { format: { x1: false, x2: false, fill: false } } }),
              ctx.Plot.text(it.segs.filter((d) => d.share >= 0.12), { x: (d) => (d.x1 + d.x2) / 2, text: (d) => fmtPct(d.share),
                fill: (d) => (d.score === 5 || d.score === 1 ? "white" : COLORS.ink), fontSize: 11 }),
              ctx.Plot.ruleX([0], { stroke: COLORS.ink, strokeOpacity: 0.5 }),
            ],
          })),
        ])),
        html(doc, "p", { class: "note", text: `About ${items[0]?.n ?? 0} responses per statement; "N/A or prefer not to respond" excluded.` +
          (items.some((d) => d.negative) ? " * Asked in the negative (\"...was NOT a good use of my time\"); answers are reversed here so agreement reads the same way as the other statements." : "") }),
      ]);
    },
    table: ({ feedback_likert }) => ({
      columns: ["Statement", "Response", "Responses"],
      rows: [...feedback_likert].sort((a, b) => a.statement.localeCompare(b.statement) || a.score - b.score).map((d) => [d.statement, d.response, d.responses]),
    }),
  },
];

// Stacked bars by program and year (hours, stipends).
function programByYear(ctx, raw, field, yLabel, fmt) {
  const rows = raw.map((d) => ({ ...d, program: PROGRAM_LABEL[d.program] ?? d.program }));
  const years = uniq(rows.map((d) => d.year)).sort();
  const totals = years.map((y) => ({ year: y, v: rows.filter((d) => d.year === y).reduce((s, d) => s + (d[field] ?? 0), 0) }));
  const compact = (v) => (field.includes("stipend") ? "$" + Math.round(v / 1000) + "k" : fmtInt(v));
  return wrap(ctx.document,
    legend(ctx.document, [["Externship", COLORS.externship], ["CERC", COLORS.cerc]]),
    ctx.Plot.plot(base(ctx, {
      height: 280,
      marginTop: 24,
      marginLeft: 56,
      x: { label: null, domain: years, tickFormat: (y) => String(y) },
      y: { label: yLabel, grid: true, nice: true, tickFormat: field.includes("stipend") ? (v) => "$" + v / 1000 + "k" : "~s" },
      color: { domain: ["Externship", "CERC"], range: [COLORS.externship, COLORS.cerc] },
      marks: [
        ctx.Plot.barY(rows, { x: "year", y: field, fill: "program", order: ["Externship", "CERC"], stroke: "white", strokeWidth: 1,
          insetLeft: 6, insetRight: 6, channels: { Year: "year", Program: "program" },
          tip: { format: { x: false, fill: false, y: (v) => fmt(v) } } }),
        ctx.Plot.text(totals, { x: "year", y: "v", text: (d) => compact(d.v), dy: -9, fill: COLORS.ink, fontWeight: 600 }),
        ctx.Plot.ruleY([0], { stroke: COLORS.neutral }),
      ],
    })));
}
