/* t3-worker Cockpit page: renders /var/lib/t3-worker/status.json (written by lib/health.sh). */
/* global cockpit */
"use strict";

const STATUS_PATH = "/var/lib/t3-worker/status.json";
const STALE_SECONDS = 15 * 60;

const SERVICES = [
    ["tailscale", "Tailscale"],
    ["t3", "T3-Code-Dienst"],
    ["docker", "Docker"],
    ["smbd", "Samba (Time Machine, T7)"],
    ["cockpit", "Cockpit"],
];

const DISK_NAMES = {
    "/": "System (SSD)",
    "/srv/timemachine": "Time Machine (HDD)",
    "/srv/t7-mirror": "T7-Spiegel (HDD)",
    "/srv/t7": "T7 Shield",
};

const STATE_TEXT = {
    active: "läuft",
    inactive: "gestoppt",
    failed: "fehlgeschlagen",
    activating: "startet",
    deactivating: "stoppt",
    reloading: "lädt neu",
    missing: "nicht installiert",
    unknown: "unbekannt",
};

const $ = id => document.getElementById(id);

function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (k === "class") node.className = v;
        else if (k === "style") node.style.cssText = v;
        else node.setAttribute(k, v);
    }
    for (const c of children) {
        if (c !== null && c !== undefined) node.append(c);
    }
    return node;
}

function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
    return node;
}

const nf = new Intl.NumberFormat("de-DE", { maximumFractionDigits: 1 });
const num = n => (typeof n === "number" ? nf.format(n) : "–");

function formatTime(value) {
    if (!value) return "–";
    const d = typeof value === "number" ? new Date(value * 1000) : new Date(value);
    if (isNaN(d)) return String(value);
    return d.toLocaleString("de-DE", { dateStyle: "short", timeStyle: "short" });
}

function formatUptime(s) {
    if (typeof s !== "number") return "–";
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    return d > 0 ? `${d} T ${h} Std` : `${h} Std ${m} Min`;
}

function row(dl, label, value) {
    dl.append(el("dt", null, label), el("dd", null, value));
}

/* Result files of other scripts (t7-mirror.json, tool-update.json) have their own
   shape; show the common fields when present. */
function jobSummary(job) {
    if (!job || typeof job !== "object") return null;
    const ok = job.ok ?? job.success;
    const when = job.finished ?? job.last_run ?? job.ended ?? job.generated ?? job.time ?? job.started;
    const msg = job.reason ?? job.message ?? job.error ?? job.summary;
    const parts = [];
    if (ok === true) parts.push("erfolgreich");
    if (ok === false) parts.push("fehlgeschlagen");
    if (when) parts.push(formatTime(when));
    if (msg) parts.push(String(msg));
    return { ok, text: parts.length ? parts.join(", ") : "vorhanden" };
}

function renderSystem(s) {
    const dl = clear($("system"));
    row(dl, "Laufzeit", formatUptime(s.uptime_s));
    row(dl, "Last (1/5/15 Min)", Array.isArray(s.load) ? s.load.map(num).join(" / ") : "–");
    if (s.mem) row(dl, "Arbeitsspeicher", `${num(s.mem.avail_mb)} MB frei von ${num(s.mem.total_mb)} MB`);
    if (s.swap) row(dl, "Swap (zram)", `${num(s.swap.used_mb)} MB belegt von ${num(s.swap.total_mb)} MB`);
    if (s.zram && s.zram.devices > 0)
        row(dl, "zram", `${num(s.zram.data_mb)} MB Daten in ${num(s.zram.used_mb)} MB RAM`);
    if (typeof s.temperature_c === "number") row(dl, "Temperatur", `${num(s.temperature_c)} °C`);
    const tu = jobSummary(s.tool_update);
    row(dl, "Werkzeug-Update", tu ? tu.text : "noch nicht gelaufen");
}

function renderServices(s) {
    const ul = clear($("services"));
    const services = s.services || {};
    for (const [key, label] of SERVICES) {
        const state = services[key] || "unknown";
        let text = STATE_TEXT[state] || state;
        let good = state === "active";
        if (key === "tailscale" && good && services.tailscale_state && services.tailscale_state !== "Running") {
            good = false;
            text = services.tailscale_state === "NeedsLogin" ? "nicht angemeldet" : services.tailscale_state;
        }
        const dotClass = good ? "dot ok" : (state === "missing" || state === "unknown") ? "dot" : "dot bad";
        ul.append(el("li", { class: "svc" },
                     el("span", { class: dotClass, "aria-hidden": "true" }),
                     el("span", null, label),
                     el("span", { class: "state" }, text)));
    }
}

function renderDisks(s) {
    const ul = clear($("disks"));
    for (const d of s.disks || []) {
        const name = DISK_NAMES[d.mount] || d.mount;
        if (!d.mounted) {
            ul.append(el("li", null,
                         el("div", { class: "disk-head" },
                            el("span", null, name), el("span", null, "nicht eingebunden"))));
            continue;
        }
        const pct = typeof d.used_pct === "number" ? d.used_pct : 0;
        const level = pct >= 90 ? "bad" : pct >= 80 ? "warn" : "";
        const bar = el("div", { class: level, style: `width: ${Math.min(pct, 100)}%` });
        ul.append(el("li", null,
                     el("div", { class: "disk-head" },
                        el("span", null, name),
                        el("span", null, `${pct} % von ${num(d.size_gb)} GB`)),
                     el("div", {
                         class: "bar", role: "progressbar", "aria-label": name,
                         "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(pct),
                     }, bar)));
    }
}

function renderT7(s) {
    const dl = clear($("t7"));
    const t7 = s.t7 || {};
    const fs = { ntfs: " (NTFS)", exfat: " (exFAT)" }[t7.fstype] || "";
    row(dl, "T7 Shield", t7.mounted ? "angeschlossen und eingebunden" + fs
        : t7.present ? "angeschlossen, nicht eingebunden" + fs : "nicht angeschlossen");
    const m = jobSummary(s.mirror);
    row(dl, "Letzte Spiegelung", m ? m.text : "noch nicht gelaufen");
    row(dl, "Zeitplan", "täglich 02:30, wenn die T7 angeschlossen ist");
}

function renderList(cardId, listId, items) {
    $(cardId).hidden = items.length === 0;
    const ul = clear($(listId));
    for (const text of items) ul.append(el("li", null, text));
}

function render(s) {
    if (!s) {
        $("nodata").hidden = false;
        $("main").hidden = true;
        $("badge").hidden = true;
        $("generated").textContent = "";
        return;
    }
    $("nodata").hidden = true;
    $("main").hidden = false;

    const generated = new Date(s.generated);
    const stale = isNaN(generated) || (Date.now() - generated.getTime()) / 1000 > STALE_SECONDS;
    const badge = $("badge");
    badge.hidden = false;
    badge.className = "badge " + (stale ? "stale" : s.ok ? "ok" : "bad");
    badge.textContent = stale ? "Status veraltet" : s.ok ? "Alles in Ordnung" : "Probleme erkannt";
    $("generated").textContent = `Stand ${formatTime(s.generated)}` + (s.hostname ? ` · ${s.hostname}` : "");

    const problems = s.problems || [];
    const pending = s.pending || [];
    $("attention-card").hidden = problems.length + pending.length === 0;
    const att = clear($("attention"));
    for (const p of problems) att.append(el("li", { class: "problem" }, p));
    for (const p of pending) att.append(el("li", null, `Offen: ${p}`));
    if (pending.length) att.append(el("li", null, "Weiter mit: ", el("code", null, "sudo t3-worker-setup")));

    renderSystem(s);
    renderServices(s);
    renderDisks(s);
    renderT7(s);
    const recent = s.recent_repairs || (s.repairs || []).map(text => ({ time: s.generated, text }));
    renderList("repairs-card", "repairs", recent.map(r => `${formatTime(r.time)}: ${r.text}`));
}

function init() {
    const file = cockpit.file(STATUS_PATH, { syntax: JSON });
    file.watch((content, tag, error) => {
        if (error) {
            $("nodata").hidden = false;
            $("nodata").textContent = `Status nicht lesbar: ${error.message || error}`;
            return;
        }
        render(content);
    });

    const button = $("refresh");
    button.addEventListener("click", () => {
        button.disabled = true;
        button.textContent = "Prüfe ...";
        /* health.sh exits 1 when something is unhealthy; the new status arrives via watch either way. */
        Promise.resolve(cockpit.spawn(["systemctl", "start", "t3-worker-health.service"],
                                      { superuser: "try", err: "ignore" }))
                .catch(() => {})
                .finally(() => {
                    button.disabled = false;
                    button.textContent = "Jetzt prüfen";
                });
    });
}

document.addEventListener("DOMContentLoaded", init);
