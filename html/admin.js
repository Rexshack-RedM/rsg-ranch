'use strict';
// Ranch admin panel (/ranchadmin). Reuses helpers from app.js:
// $, t, esc, post, money, duration, bar, toast, openModal, closeModal, confirmModal, ICONS, applyStaticText

const adm = {
    open: false,
    overview: null,
    ranchid: null,
    detail: null,
    tab: 'info',
    search: '',
    animalFilter: 'all',
};

function admPost(name, data) { return post(name, data || {}); }

function admDate(ts) {
    ts = Number(ts) || 0;
    if (!ts) return '—';
    const d = new Date(ts * 1000);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function admPill(text, cls) { return `<span class="pill ${cls || ''}">${esc(text)}</span>`; }

function admModelLabel(model) {
    const map = { a_c_cow: 'sv_animal_cow', a_c_bull_01: 'sv_animal_bull', a_c_pig_01: 'sv_animal_pig', a_c_sheep_01: 'sv_animal_sheep' };
    return t(map[model] || 'sv_animal_generic');
}

function admWeight(g) {
    g = Number(g) || 0;
    return g >= 1000 ? `${(g / 1000).toLocaleString()} kg` : `${g} g`;
}

function admGradeLabel(g) {
    const d = adm.detail;
    const found = d && (d.grades || []).find((x) => Number(x.grade) === Number(g));
    return found ? found.label : String(g);
}

// Custom dropdown. Native select popups crash RedM's NUI, so never use them here.
// A hidden input keeps the id, so $(id).value works like a select.
function admSelect(id, options, selected, style) {
    const cur = options.find((o) => String(o.value) === String(selected)) || options[0] || { value: '', label: '' };
    return `<div class="adm-select" ${style ? `style="${style}"` : ''}>
        <input type="hidden" id="${id}" value="${esc(cur.value)}">
        <div class="adm-sel-btn"><span class="adm-sel-text">${esc(cur.label)}</span><span class="adm-sel-arrow">&#9662;</span></div>
        <div class="adm-sel-list hidden">${options.map((o) =>
            `<div class="adm-sel-opt ${String(o.value) === String(cur.value) ? 'active' : ''}" data-value="${esc(o.value)}">${esc(o.label)}</div>`).join('')}</div>
    </div>`;
}

function admGradeSelect(id, selected) {
    return admSelect(id, (adm.detail.grades || []).map((g) => ({ value: g.grade, label: `${g.grade} · ${g.label}` })), selected);
}

document.addEventListener('click', (e) => {
    const opt = e.target.closest('.adm-sel-opt');
    const btn = e.target.closest('.adm-sel-btn');
    const box = e.target.closest('.adm-select');
    document.querySelectorAll('.adm-select .adm-sel-list').forEach((l) => { if (!box || !box.contains(l)) l.classList.add('hidden'); });
    if (opt && box) {
        box.querySelector('input').value = opt.dataset.value;
        box.querySelector('.adm-sel-text').textContent = opt.textContent;
        box.querySelectorAll('.adm-sel-opt').forEach((o) => o.classList.toggle('active', o === opt));
        box.querySelector('.adm-sel-list').classList.add('hidden');
    } else if (btn && box) {
        box.querySelector('.adm-sel-list').classList.toggle('hidden');
    }
});

function admField(label, inner, full) {
    return `<div class="field ${full ? 'full' : ''}"><label>${esc(label)}</label>${inner}</div>`;
}

function admNum(id, value, min, max) {
    return `<input type="number" id="${id}" value="${esc(value)}" ${min !== undefined ? `min="${min}"` : ''} ${max !== undefined ? `max="${max}"` : ''}>`;
}

function admFix(n) { return (Number(n) || 0).toFixed(1); }

// ---------- player picker (searches the players table on the server) ----------
function admPlayerPicker(id) {
    return `<div class="adm-picker" style="flex:1">
        <input type="hidden" id="${id}" value="">
        <input type="text" class="adm-pick-input" placeholder="${esc(t('ui_adm_search_player'))}" autocomplete="off">
        <div class="adm-pick-list hidden"></div>
    </div>`;
}

let admPickTimer = null;
let admPickSeq = 0;

async function admPickSearch(box) {
    const input = box.querySelector('.adm-pick-input');
    const list = box.querySelector('.adm-pick-list');
    const seq = ++admPickSeq;
    list.innerHTML = `<div class="adm-pick-empty">${esc(t('ui_adm_searching'))}</div>`;
    list.classList.remove('hidden');
    const results = await admPost('admin:searchPlayers', { query: input.value.trim() });
    if (seq !== admPickSeq) return;
    const rows = Array.isArray(results) ? results : [];
    list.innerHTML = rows.map((p, i) => `
        <div class="adm-pick-opt" data-i="${i}">
            <div class="adm-pick-name">${esc(p.name)} ${p.online ? admPill(t('ui_adm_online') + (p.serverId ? ' · ' + p.serverId : ''), 'good') : ''}</div>
            <div class="adm-pick-meta"><span class="mono">${esc(p.citizenid)}</span> · ${esc(p.job)}${p.grade ? ' (' + esc(p.grade) + ')' : ''}</div>
        </div>`).join('') || `<div class="adm-pick-empty">${esc(t(input.value.trim() ? 'ui_adm_no_players' : 'ui_adm_nobody_online'))}</div>`;
    list.querySelectorAll('.adm-pick-opt').forEach((el) => {
        el.onclick = () => {
            const p = rows[Number(el.dataset.i)];
            box.querySelector('input[type=hidden]').value = p.citizenid;
            input.value = `${p.name} (${p.citizenid})`;
            box.dataset.name = p.name;
            list.classList.add('hidden');
        };
    });
}

document.addEventListener('input', (e) => {
    const box = e.target.closest && e.target.closest('.adm-picker');
    if (!box || !e.target.classList.contains('adm-pick-input')) return;
    box.querySelector('input[type=hidden]').value = '';
    clearTimeout(admPickTimer);
    admPickTimer = setTimeout(() => admPickSearch(box), 300);
});

document.addEventListener('focusin', (e) => {
    const box = e.target.closest && e.target.closest('.adm-picker');
    if (box && e.target.classList.contains('adm-pick-input') && !box.querySelector('input[type=hidden]').value) admPickSearch(box);
});

document.addEventListener('click', (e) => {
    document.querySelectorAll('.adm-picker .adm-pick-list').forEach((l) => { if (!l.parentElement.contains(e.target)) l.classList.add('hidden'); });
});

// ---------- server calls ----------
async function admRefreshOverview() {
    const data = await admPost('admin:overview');
    if (data && data.ranches) adm.overview = data;
    renderAdmSide();
}

async function admLoadRanch(ranchid, keepTab) {
    adm.ranchid = ranchid;
    if (!keepTab) { adm.tab = 'info'; adm.animalFilter = 'all'; }
    renderAdmSide();
    const data = await admPost('admin:getRanch', { ranchid });
    if (!adm.open || adm.ranchid !== ranchid) return;
    if (!data || !data.ranch) { toast(t('ui_adm_load_failed'), 'error'); return; }
    adm.detail = data;
    renderAdmMain();
}

async function admAction(kind, data) {
    const res = await admPost('admin:action', { ranchid: adm.ranchid, kind, data: data || {} });
    if (res && res.msg) toast(res.msg, res.ok ? 'success' : 'error');
    if (res && res.ok) {
        await admLoadRanch(adm.ranchid, true);
        admRefreshOverview();
    }
    return res && res.ok;
}

// confirm dialogs opened from inside another modal need a tick so the first one can close
function admConfirm(title, text, label, fn) {
    setTimeout(() => confirmModal(title, text, label, () => { fn(); }, true), 0);
}

// ---------- sidebar ----------
function renderAdmSide() {
    const o = adm.overview;
    if (!o || !o.ranches) return;
    const owned = o.ranches.filter((r) => r.owner).length;
    const animals = o.ranches.reduce((n, r) => n + (r.animals || 0), 0);
    $('adm-sub').textContent = t('ui_adm_subtitle', o.ranches.length, owned, animals);

    const q = adm.search.trim().toLowerCase();
    const list = o.ranches.filter((r) => !q || r.name.toLowerCase().includes(q) || r.ranchid.toLowerCase().includes(q) || (r.ownerName || '').toLowerCase().includes(q));
    $('adm-ranches').innerHTML = list.map((r) => `
        <div class="adm-ranch ${r.ranchid === adm.ranchid ? 'active' : ''}" data-rid="${esc(r.ranchid)}">
            <div class="nm"><span>${esc(r.name)}${r.custom ? ' <span class="mono">&#9733;</span>' : ''}</span>${r.owner ? admPill(t('ui_adm_owned'), 'good') : admPill(t('ui_adm_for_sale'), 'warn')}</div>
            <div class="ow">${r.owner ? esc(r.ownerName || r.owner) + (r.ownerOnline ? ' · ' + esc(t('ui_adm_online')) : '') : esc(money(r.price))}</div>
            <div class="ct">${esc(t('ui_adm_counts', r.animals, o.maxAnimals, r.staff, r.storages))}</div>
        </div>`).join('') || `<div class="empty">${esc(t('ui_adm_no_results'))}</div>`;
    $('adm-ranches').querySelectorAll('.adm-ranch').forEach((el) => { el.onclick = () => admLoadRanch(el.dataset.rid); });
}

// ---------- main ----------
const ADM_TABS = [
    ['info', '&#9873;', 'ui_adm_tab_info'],
    ['staff', '&#9733;', 'ui_adm_tab_staff'],
    ['animals', '&#10022;', 'ui_adm_tab_animals'],
    ['props', '&#9881;', 'ui_adm_tab_props'],
    ['storage', '&#9635;', 'ui_adm_tab_storage'],
    ['orders', '&#9998;', 'ui_adm_tab_orders'],
    ['settings', '&#9874;', 'ui_adm_tab_settings'],
];

function renderAdmMain() {
    if (!adm.detail) {
        $('adm-tabs').innerHTML = '';
        $('adm-content').innerHTML = `<div class="empty">${esc(t('ui_adm_pick_ranch'))}</div>`;
        return;
    }
    $('adm-tabs').innerHTML = ADM_TABS.map(([id, icon, key]) =>
        `<div class="tab ${adm.tab === id ? 'active' : ''}" data-tab="${id}"><span class="icon">${icon}</span>${esc(t(key))}</div>`).join('');
    $('adm-tabs').querySelectorAll('.tab').forEach((el) => { el.onclick = () => { adm.tab = el.dataset.tab; renderAdmMain(); }; });

    const views = { info: admViewInfo, staff: admViewStaff, animals: admViewAnimals, props: admViewProps, storage: admViewStorage, orders: admViewOrders, settings: admViewSettings };
    const scroll = $('adm-content').scrollTop;
    $('adm-content').innerHTML = (views[adm.tab] || admViewInfo)();
    $('adm-content').scrollTop = scroll;
    admBind();
}

// ----- info / ownership -----
function admViewInfo() {
    const d = adm.detail, r = d.ranch, o = d.owner;
    const tiles = [
        { v: `${d.animals.length}/${d.maxAnimals}`, l: t('ui_animals') },
        { v: d.staff.length, l: t('ui_adm_staff') },
        { v: d.feedtroughs.length + d.watertroughs.length, l: t('ui_adm_troughs') },
        { v: d.coops.length, l: t('ui_adm_coops') },
        { v: d.storages.length, l: t('ui_adm_storages') },
        { v: d.orders.length, l: t('ui_adm_orders') },
        { v: money(r.price), l: t('ui_price') },
        { v: r.showblip ? t('ui_adm_yes') : t('ui_adm_no'), l: t('ui_adm_blip') },
    ];
    const ownerBlock = o
        ? `<div class="row"><div class="badge-icon">&#9819;</div><div class="row-main">
                <div class="row-title">${esc(o.name)} ${o.online ? admPill(t('ui_adm_online'), 'good') : admPill(t('ui_adm_offline'))}</div>
                <div class="row-desc"><span class="mono">${esc(o.citizenid)}</span> · ${esc(t('ui_adm_since', admDate(o.purchased_at)))}</div>
            </div><div class="row-actions"><button class="wood-btn small danger" data-act="removeOwner">${esc(t('ui_adm_remove_owner'))}</button></div></div>`
        : `<div class="empty">${esc(t('ui_adm_no_owner'))}</div>`;

    return `<div class="tiles">${tiles.map((x) => `<div class="tile"><div class="value">${esc(x.v)}</div><div class="label">${esc(x.l)}</div></div>`).join('')}</div>
        <div class="section-title"><span>${esc(t('ui_owner'))}</span></div>
        <div class="list">${ownerBlock}</div>
        <div class="adm-card spaced">
            <div class="row-title">${esc(o ? t('ui_adm_transfer_owner') : t('ui_adm_assign_owner'))}</div>
            <div class="row-desc">${esc(t('ui_adm_owner_hint'))}</div>
            <div class="adm-inline">${admPlayerPicker('adm-owner-target')}
            <button class="wood-btn" data-act="setOwner">${esc(t('ui_adm_set_owner'))}</button></div>
        </div>
        <div class="adm-card">
            <div class="row-title">${esc(t('ui_adm_location'))}</div>
            <div class="row-desc"><span class="mono">${esc(r.ranchid)}</span> · ${esc(t('ui_adm_job', r.jobaccess))} · <span class="mono">${admFix(r.coords.x)}, ${admFix(r.coords.y)}, ${admFix(r.coords.z)}</span></div>
            <div class="adm-inline">
                ${r.spawn ? `<button class="wood-btn small" data-tp="spawn">${esc(t('ui_adm_tp_spawn'))}</button>` : ''}
                ${r.custom ? `<button class="wood-btn small" data-act="setNpcHere">${esc(t('ui_adm_npc_here'))}</button>
                <button class="wood-btn small" data-act="setSpawnHere">${esc(t('ui_adm_spawn_here'))}</button>` : ''}
            </div>
            ${r.custom ? `<div class="row-desc spaced">${esc(t('ui_adm_custom_hint'))}</div>` : ''}
        </div>
        <div class="adm-card danger">
            <div class="row-title">${esc(t('ui_adm_reset_title'))}</div>
            <div class="row-desc">${esc(t('ui_adm_reset_desc'))}</div>
            <button class="wood-btn danger" data-act="resetRanch">${esc(t('ui_adm_reset_btn'))}</button>
        </div>
        ${r.custom ? `<div class="adm-card danger">
            <div class="row-title">${esc(t('ui_adm_delete_ranch'))}</div>
            <div class="row-desc">${esc(t('ui_adm_delete_ranch_desc'))}</div>
            <button class="wood-btn danger" data-act="deleteRanch">${esc(t('ui_adm_delete_ranch'))}</button>
        </div>` : ''}`;
}

// ----- staff -----
function admViewStaff() {
    const d = adm.detail;
    const ownerCid = d.owner && d.owner.citizenid;
    const rows = d.staff.map((s) => `
        <div class="row"><div class="badge-icon">${s.citizenid === ownerCid ? '&#9819;' : '&#9733;'}</div>
            <div class="row-main">
                <div class="row-title">${esc(s.name)} ${s.online ? admPill(t('ui_adm_online'), 'good') : admPill(t('ui_adm_offline'))} ${s.citizenid === ownerCid ? admPill(t('ui_owner'), 'warn') : ''}</div>
                <div class="row-desc"><span class="mono">${esc(s.citizenid)}</span>${s.online ? ' · ID ' + esc(s.serverId) : ''} · ${esc(s.gradeLabel || admGradeLabel(s.grade))}</div>
            </div>
            <div class="row-actions">
                <button class="wood-btn small" data-grade="${esc(s.citizenid)}" data-cur="${esc(s.grade)}" data-name="${esc(s.name)}">${esc(t('ui_adm_set_grade'))}</button>
                ${s.citizenid !== ownerCid ? `<button class="wood-btn small danger" data-fire="${esc(s.citizenid)}" data-name="${esc(s.name)}">${esc(t('ui_adm_fire'))}</button>` : ''}
            </div>
        </div>`).join('');
    return `<div class="adm-card">
            <div class="row-title">${esc(t('ui_adm_hire_title'))}</div>
            <div class="row-desc">${esc(t('ui_adm_owner_hint'))}</div>
            <div class="adm-inline">${admPlayerPicker('adm-hire-target')}
            ${admGradeSelect('adm-hire-grade', 0)}
            <button class="wood-btn" data-act="hire">${esc(t('ui_adm_hire'))}</button></div>
        </div>
        <div class="section-title"><span>${esc(t('ui_adm_staff'))} (${d.staff.length})</span>
            ${d.staff.length > 1 ? `<button class="wood-btn small danger" data-act="fireAll">${esc(t('ui_adm_fire_all'))}</button>` : ''}</div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_adm_no_staff'))}</div>`}</div>`;
}

// ----- animals -----
function admViewAnimals() {
    const d = adm.detail;
    const models = [...new Set(d.animals.map((a) => a.model))];
    const filters = [['all', t('ui_filter_all')], ...models.map((m) => [m, admModelLabel(m)]), ['care', t('ui_filter_care')]];
    const list = d.animals.filter((a) => adm.animalFilter === 'all' ? true
        : adm.animalFilter === 'care' ? (a.health < 50 || a.hunger < 30 || a.thirst < 30) : a.model === adm.animalFilter);
    const rows = list.map((a) => `
        <div class="row clickable" data-animal="${esc(a.animalid)}">
            <div class="badge-icon">${(typeof ICONS !== 'undefined' && ICONS[a.model]) || '&#10022;'}</div>
            <div class="row-main">
                <div class="row-title">${esc(admModelLabel(a.model))} <span class="row-desc">#${esc(a.animalid)} · ${esc(t('ui_gender_' + a.gender))} · ${esc(t('ui_age_days', a.age))}</span></div>
                <div class="stats">${bar(t('ui_health'), a.health)}${bar(t('ui_hunger'), a.hunger)}${bar(t('ui_thirst'), a.thirst)}</div>
            </div>
            <div class="row-actions col">${a.pregnant ? admPill(t('ui_pregnant'), 'warn') : ''}${a.product_ready ? admPill(t('ui_product'), 'good') : ''}</div>
        </div>`).join('');
    return `<div class="section-title"><span>${esc(t('ui_animals'))} (${d.animals.length}/${d.maxAnimals})</span>
            <span class="adm-inline">
                ${d.animals.length ? `<button class="wood-btn small" data-act="healAll">${esc(t('ui_adm_heal_all'))}</button>
                <button class="wood-btn small danger" data-act="deleteAllAnimals">${esc(t('ui_adm_delete_all'))}</button>` : ''}
            </span></div>
        <div class="filters">${filters.map(([k, l]) => `<div class="chip ${adm.animalFilter === k ? 'active' : ''}" data-afilter="${esc(k)}">${esc(l)}</div>`).join('')}</div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_no_animals'))}</div>`}</div>`;
}

function admEditAnimal(id) {
    const a = adm.detail.animals.find((x) => String(x.animalid) === String(id));
    if (!a) return;
    const extra = a.pregnant && a.gestation_end_time ? `<div class="row-desc full">${esc(t('ui_due_in', duration(a.gestation_end_time - adm.detail.now)))}</div>` : '';
    openModal(`${admModelLabel(a.model)} #${a.animalid}`, `
        <div class="adm-grid">
            ${admField(t('ui_health'), admNum('aa-health', a.health, 0, 100))}
            ${admField(t('ui_hunger'), admNum('aa-hunger', a.hunger, 0, 100))}
            ${admField(t('ui_thirst'), admNum('aa-thirst', a.thirst, 0, 100))}
            ${admField(t('ui_adm_age'), admNum('aa-age', a.age, 0))}
            <label class="check full"><input type="checkbox" id="aa-product" ${a.product_ready ? 'checked' : ''}> ${esc(t('ui_adm_product_ready'))}</label>
            <div class="row-desc full mono">${admFix(a.pos_x)}, ${admFix(a.pos_y)}, ${admFix(a.pos_z)}</div>
            ${extra}
        </div>`, [
        { label: t('ui_cancel'), muted: true },
        { label: t('ui_adm_teleport'), muted: true, onClick: () => { admPost('admin:teleport', { x: a.pos_x, y: a.pos_y, z: a.pos_z }); } },
        { label: t('ui_adm_delete'), danger: true, onClick: () => { admConfirm(t('ui_adm_delete'), t('ui_adm_confirm_delete_animal', a.animalid), t('ui_adm_delete'), () => admAction('deleteAnimal', { animalid: a.animalid })); } },
        { label: t('ui_adm_save'), onClick: () => { admAction('updateAnimal', {
            animalid: a.animalid, health: $('aa-health').value, hunger: $('aa-hunger').value, thirst: $('aa-thirst').value,
            age: $('aa-age').value, product_ready: $('aa-product').checked,
        }); } },
    ]);
}

// ----- troughs & coops -----
function admViewProps() {
    const d = adm.detail;
    const trough = (kind, x) => `
        <div class="row"><div class="badge-icon">${kind === 'feed' ? '&#127806;' : '&#128167;'}</div>
            <div class="row-main"><div class="row-title">${esc(x.id)}</div>
                <div class="row-desc">${esc(t('ui_adm_placed', admDate(x.created_at)))}${x.placed_by ? ' · ' + esc(x.placed_by) : ''}</div></div>
            <div class="row-actions">
                <input type="number" class="qty" min="0" max="255" value="${esc(x.uses)}" id="tu-${kind}-${esc(x.id)}" title="${esc(t('ui_adm_uses'))}">
                <button class="wood-btn small" data-tuses="${kind}" data-id="${esc(x.id)}">${esc(t('ui_adm_save'))}</button>
                <button class="wood-btn small muted" data-tpx="${esc(x.pos_x)}" data-tpy="${esc(x.pos_y)}" data-tpz="${esc(x.pos_z)}" title="${esc(t('ui_adm_teleport'))}">&#10148;</button>
                <button class="wood-btn small danger" data-tdel="${kind}" data-id="${esc(x.id)}" title="${esc(t('ui_adm_delete'))}">&#10005;</button>
            </div></div>`;
    const coop = (c) => `
        <div class="row clickable" data-coop="${esc(c.coopid)}"><div class="badge-icon">&#128020;</div>
            <div class="row-main"><div class="row-title">${esc(c.coopid)}</div>
                <div class="row-desc">${esc(t('ui_adm_coop_line', c.chickens, c.eggs_stored))}</div>
                <div class="stats single">${bar(t('ui_adm_feed'), c.feed_level)}</div></div></div>`;
    return `<div class="section-title"><span>${esc(t('ui_adm_feedtroughs'))} (${d.feedtroughs.length})</span></div>
        <div class="list">${d.feedtroughs.map((x) => trough('feed', x)).join('') || `<div class="empty">${esc(t('ui_adm_none'))}</div>`}</div>
        <div class="section-title"><span>${esc(t('ui_adm_watertroughs'))} (${d.watertroughs.length})</span></div>
        <div class="list">${d.watertroughs.map((x) => trough('water', x)).join('') || `<div class="empty">${esc(t('ui_adm_none'))}</div>`}</div>
        <div class="section-title"><span>${esc(t('ui_adm_coops'))} (${d.coops.length})</span></div>
        <div class="list">${d.coops.map(coop).join('') || `<div class="empty">${esc(t('ui_adm_none'))}</div>`}</div>`;
}

function admEditCoop(id) {
    const c = adm.detail.coops.find((x) => String(x.coopid) === String(id));
    if (!c) return;
    openModal(c.coopid, `<div class="adm-grid">
            ${admField(t('ui_adm_chickens'), admNum('ac-chickens', c.chickens, 0))}
            ${admField(t('ui_adm_eggs'), admNum('ac-eggs', c.eggs_stored, 0))}
            ${admField(t('ui_adm_feed'), admNum('ac-feed', c.feed_level, 0, 100), true)}
        </div>`, [
        { label: t('ui_cancel'), muted: true },
        { label: t('ui_adm_teleport'), muted: true, onClick: () => { admPost('admin:teleport', { x: c.pos_x, y: c.pos_y, z: c.pos_z }); } },
        { label: t('ui_adm_delete'), danger: true, onClick: () => { admConfirm(t('ui_adm_delete'), t('ui_adm_confirm_delete', c.coopid), t('ui_adm_delete'), () => admAction('coopDelete', { coopid: c.coopid })); } },
        { label: t('ui_adm_save'), onClick: () => { admAction('coopUpdate', { coopid: c.coopid, chickens: $('ac-chickens').value, eggs_stored: $('ac-eggs').value, feed_level: $('ac-feed').value }); } },
    ]);
}

// ----- storage -----
function admViewStorage() {
    const d = adm.detail;
    const rows = d.storages.map((s) => `
        <div class="row clickable" data-storage="${esc(s.storageid)}"><div class="badge-icon">&#9635;</div>
            <div class="row-main"><div class="row-title">${esc(s.label)} ${s.size === 'general' ? admPill(t('ui_adm_general')) : admPill(s.size)}</div>
                <div class="row-desc"><span class="mono">${esc(s.storageid)}</span> · ${esc(t('ui_adm_storage_line', s.slots, admWeight(s.maxweight), admGradeLabel(s.min_grade)))}</div></div></div>`).join('');
    const sizes = admSelect('adm-storage-size', (d.storageSizes || []).map((s) => ({ value: s.key, label: `${s.label} · ${s.slots} slots / ${admWeight(s.maxweight)}` })), null, 'flex:1');
    return `<div class="adm-card"><div class="row-title">${esc(t('ui_adm_add_storage'))}</div>
            <div class="row-desc">${esc(t('ui_adm_add_storage_desc'))}</div>
            <div class="adm-inline">${sizes}
            <button class="wood-btn" data-act="storageAdd">${esc(t('ui_adm_add'))}</button></div></div>
        <div class="section-title"><span>${esc(t('ui_adm_storages'))} (${d.storages.length})</span></div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_adm_none'))}</div>`}</div>`;
}

function admEditStorage(id) {
    const s = adm.detail.storages.find((x) => x.storageid === id);
    if (!s) return;
    const btns = [
        { label: t('ui_cancel'), muted: true },
        { label: t('ui_adm_empty'), danger: true, onClick: () => { admConfirm(t('ui_adm_empty'), t('ui_adm_confirm_empty', s.label), t('ui_adm_empty'), () => admAction('storageClear', { storageid: s.storageid })); } },
    ];
    if (s.size !== 'general') btns.push({ label: t('ui_adm_delete'), danger: true, onClick: () => { admConfirm(t('ui_adm_delete'), t('ui_adm_confirm_delete_storage', s.label), t('ui_adm_delete'), () => admAction('storageDelete', { storageid: s.storageid })); } });
    btns.push({ label: t('ui_adm_save'), onClick: () => { admAction('storageUpdate', { storageid: s.storageid, label: $('as-label').value, slots: $('as-slots').value, maxweight: $('as-weight').value, min_grade: $('as-grade').value }); } });
    openModal(s.label, `<div class="adm-grid">
            ${admField(t('ui_adm_label'), `<input type="text" id="as-label" maxlength="50" value="${esc(s.label)}">`, true)}
            ${admField(t('ui_adm_slots'), admNum('as-slots', s.slots, 1, 1000))}
            ${admField(t('ui_adm_maxweight'), admNum('as-weight', s.maxweight, 1000))}
            ${admField(t('ui_adm_access'), admGradeSelect('as-grade', s.min_grade), true)}
            <div class="row-desc full mono">${esc(s.storageid)}${s.purchased_by ? ' · ' + esc(s.purchased_by) : ''} · ${esc(admDate(s.created_at))}</div>
        </div>`, btns);
}

// ----- orders -----
function admViewOrders() {
    const d = adm.detail;
    const rows = d.orders.map((o) => {
        const left = (o.ready_at || 0) - d.now;
        return `<div class="row"><div class="badge-icon">&#9998;</div>
            <div class="row-main"><div class="row-title">${esc(o.amount)}x ${esc(o.item)} ${left > 0 ? admPill(t('ui_adm_ready_in', duration(left)), 'warn') : admPill(t('ui_adm_ready'), 'good')}</div>
                <div class="row-desc"><span class="mono">${esc(o.orderid)}</span> · ${esc(money(o.price))} · ${esc(o.citizenid || '')} · ${esc(admDate(o.ordered_at))}</div></div>
            <div class="row-actions">
                ${left > 0 ? `<button class="wood-btn small" data-oready="${esc(o.orderid)}">${esc(t('ui_adm_make_ready'))}</button>` : ''}
                <button class="wood-btn small danger" data-odel="${esc(o.orderid)}" title="${esc(t('ui_adm_delete'))}">&#10005;</button>
            </div></div>`;
    }).join('');
    return `<div class="section-title"><span>${esc(t('ui_adm_orders'))} (${d.orders.length})</span></div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_adm_none'))}</div>`}</div>`;
}

// ----- settings -----
function admViewSettings() {
    const r = adm.detail.ranch, def = r.defaults || {};
    return `<div class="adm-card">
            <div class="row-desc">${esc(t('ui_adm_settings_desc'))}</div>
            <div class="adm-grid">
                ${admField(t('ui_adm_display_name'), `<input type="text" id="st-name" maxlength="100" value="${esc(r.name)}" placeholder="${esc(def.name || '')}">`)}
                ${admField(t('ui_adm_blip_name'), `<input type="text" id="st-blip" maxlength="100" value="${esc(r.blipname || '')}" placeholder="${esc(def.blipname || '')}">`)}
                ${admField(t('ui_adm_purchase_price'), admNum('st-price', r.price, 0))}
                <div class="field"><label>${esc(t('ui_adm_blip'))}</label><label class="check"><input type="checkbox" id="st-showblip" ${r.showblip ? 'checked' : ''}> ${esc(t('ui_adm_show_blip'))}</label></div>
                <div class="row-desc full">${esc(t('ui_adm_defaults', def.name || '', money(def.price), def.showblip ? t('ui_adm_yes') : t('ui_adm_no')))}</div>
            </div>
            <div class="actions">
                <button class="wood-btn muted" data-act="resetSettings">${esc(t('ui_adm_reset_defaults'))}</button>
                <button class="wood-btn" data-act="saveSettings">${esc(t('ui_adm_save'))}</button>
            </div>
        </div>`;
}

// ---------- bindings ----------
function admBind() {
    const c = $('adm-content'), d = adm.detail, r = d.ranch;
    const q = (sel) => c.querySelectorAll(sel);

    q('[data-act]').forEach((el) => {
        el.onclick = () => {
            const a = el.dataset.act;
            if (a === 'setOwner') {
                const v = $('adm-owner-target').value.trim();
                if (!v) return toast(t('ui_adm_pick_player'), 'error');
                const who = $('adm-owner-target').closest('.adm-picker').dataset.name || v;
                admConfirm(t('ui_adm_set_owner'), t('ui_adm_confirm_owner', who, r.name), t('ui_adm_set_owner'), () => admAction('setOwner', { target: v }));
            } else if (a === 'removeOwner') {
                admConfirm(t('ui_adm_remove_owner'), t('ui_adm_confirm_remove_owner', d.owner.name), t('ui_adm_remove_owner'), () => admAction('removeOwner'));
            } else if (a === 'resetRanch') {
                admConfirm(t('ui_adm_reset_title'), t('ui_adm_confirm_reset', r.name), t('ui_adm_reset_btn'), () => admAction('resetRanch'));
            } else if (a === 'hire') {
                const v = $('adm-hire-target').value.trim();
                if (!v) return toast(t('ui_adm_pick_player'), 'error');
                admAction('hire', { target: v, grade: $('adm-hire-grade').value });
            } else if (a === 'fireAll') {
                admConfirm(t('ui_adm_fire_all'), t('ui_adm_confirm_fire_all', r.name), t('ui_adm_fire_all'), () => admAction('fireAll'));
            } else if (a === 'healAll') {
                admAction('healAll');
            } else if (a === 'deleteAllAnimals') {
                admConfirm(t('ui_adm_delete_all'), t('ui_adm_confirm_delete_all', d.animals.length, r.name), t('ui_adm_delete_all'), () => admAction('deleteAllAnimals'));
            } else if (a === 'storageAdd') {
                admAction('storageAdd', { size: $('adm-storage-size').value });
            } else if (a === 'saveSettings') {
                admAction('saveSettings', { name: $('st-name').value.trim(), blipname: $('st-blip').value.trim(), price: $('st-price').value, showblip: $('st-showblip').checked });
            } else if (a === 'setNpcHere') {
                admConfirm(t('ui_adm_npc_here'), t('ui_adm_confirm_npc_here', r.name), t('ui_adm_npc_here'), () => admAction('setNpcHere'));
            } else if (a === 'setSpawnHere') {
                admConfirm(t('ui_adm_spawn_here'), t('ui_adm_confirm_spawn_here', r.name), t('ui_adm_spawn_here'), () => admAction('setSpawnHere'));
            } else if (a === 'deleteRanch') {
                admConfirm(t('ui_adm_delete_ranch'), t('ui_adm_confirm_delete_ranch', r.name), t('ui_adm_delete_ranch'), async () => {
                    const res = await admPost('admin:action', { ranchid: adm.ranchid, kind: 'deleteRanch', data: {} });
                    if (res && res.msg) toast(res.msg, res.ok ? 'success' : 'error');
                    if (res && res.ok) {
                        adm.ranchid = null; adm.detail = null;
                        await admRefreshOverview();
                        renderAdmMain();
                        const first = adm.overview && adm.overview.ranches[0];
                        if (first) admLoadRanch(first.ranchid);
                    }
                });
            } else if (a === 'resetSettings') {
                admConfirm(t('ui_adm_reset_defaults'), t('ui_adm_confirm_reset_settings', r.name), t('ui_adm_reset_defaults'), () => admAction('resetSettings'));
            }
        };
    });

    q('[data-tp]').forEach((el) => {
        el.onclick = () => {
            const p = el.dataset.tp === 'spawn' && r.spawn ? r.spawn : r.coords;
            admPost('admin:teleport', { x: p.x, y: p.y, z: p.z, w: p.w });
        };
    });
    q('[data-tpx]').forEach((el) => { el.onclick = () => admPost('admin:teleport', { x: el.dataset.tpx, y: el.dataset.tpy, z: el.dataset.tpz }); });

    q('[data-grade]').forEach((el) => {
        el.onclick = () => openModal(el.dataset.name, admField(t('ui_adm_grade'), admGradeSelect('sg-grade', el.dataset.cur)), [
            { label: t('ui_cancel'), muted: true },
            { label: t('ui_adm_save'), onClick: () => { admAction('setGrade', { citizenid: el.dataset.grade, grade: $('sg-grade').value }); } },
        ]);
    });
    q('[data-fire]').forEach((el) => {
        el.onclick = () => admConfirm(t('ui_adm_fire'), t('ui_adm_confirm_fire', el.dataset.name), t('ui_adm_fire'), () => admAction('fire', { citizenid: el.dataset.fire }));
    });

    q('[data-afilter]').forEach((el) => { el.onclick = () => { adm.animalFilter = el.dataset.afilter; renderAdmMain(); }; });
    q('[data-animal]').forEach((el) => { el.onclick = () => admEditAnimal(el.dataset.animal); });
    q('[data-coop]').forEach((el) => { el.onclick = () => admEditCoop(el.dataset.coop); });
    q('[data-storage]').forEach((el) => { el.onclick = () => admEditStorage(el.dataset.storage); });

    q('[data-tuses]').forEach((el) => {
        el.onclick = () => {
            const input = document.getElementById(`tu-${el.dataset.tuses}-${el.dataset.id}`);
            admAction('troughUses', { kind: el.dataset.tuses, id: el.dataset.id, uses: input ? input.value : 0 });
        };
    });
    q('[data-tdel]').forEach((el) => {
        el.onclick = () => admConfirm(t('ui_adm_delete'), t('ui_adm_confirm_delete', el.dataset.id), t('ui_adm_delete'), () => admAction('troughDelete', { kind: el.dataset.tdel, id: el.dataset.id }));
    });
    q('[data-oready]').forEach((el) => { el.onclick = () => admAction('orderReady', { orderid: el.dataset.oready }); });
    q('[data-odel]').forEach((el) => {
        el.onclick = () => admConfirm(t('ui_adm_delete'), t('ui_adm_confirm_delete', el.dataset.odel), t('ui_adm_delete'), () => admAction('orderDelete', { orderid: el.dataset.odel }));
    });
}

// ---------- open / close ----------
function admClose() {
    adm.open = false;
    adm.detail = null;
    adm.ranchid = null;
    closeModal();
    $('admin').classList.add('hidden');
    $('app').classList.add('hidden');
}

window.addEventListener('message', (e) => {
    const msg = e.data || {};
    if (msg.action === 'admin:open') {
        L = msg.locales || {};
        applyStaticText();
        document.querySelectorAll('[data-t-ph]').forEach((el) => { el.placeholder = t(el.dataset.tPh); });
        adm.open = true;
        adm.overview = msg.data;
        adm.detail = null;
        adm.search = '';
        $('adm-search').value = '';
        $('app').classList.remove('hidden');
        $('admin').classList.remove('hidden');
        renderAdmSide();
        renderAdmMain();
        const first = msg.data && msg.data.ranches && msg.data.ranches[0];
        if (first) admLoadRanch(first.ranchid);
    } else if (msg.action === 'admin:close') {
        admClose();
    }
});

// ---------- create a new ranch ----------
function admSlug(v) {
    return String(v || '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 40);
}

function admNewRanch() {
    openModal(t('ui_adm_new_ranch'), `
        <p>${esc(t('ui_adm_new_ranch_desc'))}</p>
        <div class="ink-divider"></div>
        <div class="adm-grid">
            ${admField(t('ui_adm_display_name'), `<input type="text" id="nr-name" maxlength="100" placeholder="${esc(t('ui_adm_new_name_ph'))}">`, true)}
            ${admField(t('ui_adm_ranch_id'), `<input type="text" id="nr-id" maxlength="40" placeholder="valentineranch">`)}
            ${admField(t('ui_adm_purchase_price'), admNum('nr-price', 5000, 0))}
            <div class="row-desc full">${esc(t('ui_adm_ranch_id_hint'))}</div>
        </div>`, [
        { label: t('ui_cancel'), muted: true },
        { label: t('ui_adm_create'), onClick: () => {
            const name = $('nr-name').value.trim();
            const ranchid = admSlug($('nr-id').value || name);
            if (!name) { toast(t('ui_adm_need_name'), 'error'); return false; }
            admPost('admin:createRanch', { name, ranchid, price: $('nr-price').value }).then(async (res) => {
                if (res && res.msg) toast(res.msg, res.ok ? 'success' : 'error');
                if (res && res.ok) {
                    await admRefreshOverview();
                    admLoadRanch(res.ranchid);
                }
            });
        } },
    ]);
    let idTouched = false;
    $('nr-id').addEventListener('input', () => { idTouched = true; $('nr-id').value = admSlug($('nr-id').value); });
    $('nr-name').addEventListener('input', () => { if (!idTouched) $('nr-id').value = admSlug($('nr-name').value); });
    setTimeout(() => $('nr-name').focus(), 0);
}

$('adm-new-ranch').onclick = admNewRanch;
$('adm-close').onclick = () => post('admin:close');
$('adm-search').addEventListener('input', (e) => { adm.search = e.target.value; renderAdmSide(); });

document.addEventListener('keydown', (e) => {
    if (!adm.open || e.key !== 'Escape') return;
    if (!$('modal-backdrop').classList.contains('hidden')) closeModal();
    else post('admin:close');
});
