'use strict';

const RESOURCE = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'rsg-ranch';

let L = {};
let state = null;
let activeTab = 'herd';
let herdFilter = 'all';
let mode = null;
let orderTimer = null;

// ---------- helpers ----------
const $ = (id) => document.getElementById(id);

function t(key, ...args) {
    let s = L[key] || key;
    args.forEach((a) => { s = s.replace(/%s|%d/, a); });
    return s.replace(/%%/g, '%');
}

function esc(v) {
    return String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function post(name, data = {}) {
    return fetch(`https://${RESOURCE}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    }).then((r) => r.json()).catch(() => null);
}

function action(type, data = {}) {
    post('action', { type, ...data });
}

function money(n) { return '$' + Number(n || 0).toLocaleString(); }

function duration(sec) {
    sec = Math.max(0, Math.floor(sec || 0));
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    if (d > 0) return t('ui_dur_dh', d, h);
    if (h > 0) return t('ui_dur_hm', h, m);
    if (m > 0) return t('ui_dur_ms', m, s);
    return t('ui_dur_s', s);
}

function bar(label, value) {
    const v = Math.max(0, Math.min(100, Number(value) || 0));
    const cls = v >= 60 ? 'stat-good' : v >= 30 ? 'stat-warn' : 'stat-bad';
    return `<div><div class="stat-label"><span>${esc(label)}</span><span>${Math.round(v)}%</span></div>
        <div class="bar"><div class="fill ${cls}" style="width:${v}%"></div></div></div>`;
}

const ICONS = { a_c_cow: '&#128004;', a_c_bull_01: '&#128002;', a_c_pig_01: '&#128022;', a_c_sheep_01: '&#128017;' };
const SPECIES_ICON = { pig: ICONS.a_c_pig_01, cow: ICONS.a_c_cow, bull: ICONS.a_c_bull_01 || ICONS.a_c_cow, sheep: ICONS.a_c_sheep_01 };

function toast(message, type = 'info') {
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.innerHTML = `<div class="toast-label">${esc(state ? state.name : t('ui_ranch'))}</div><div>${esc(message)}</div>`;
    $('toasts').appendChild(el);
    setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 250); }, 3500);
}

function applyStaticText() {
    document.querySelectorAll('[data-t]').forEach((el) => { el.textContent = t(el.dataset.t); });
    document.querySelectorAll('[data-t-title]').forEach((el) => { el.title = t(el.dataset.tTitle); });
}

// ---------- modal ----------
function openModal(title, bodyHtml, buttons) {
    $('modal-title').textContent = title;
    $('modal-body').innerHTML = bodyHtml;
    const actions = $('modal-actions');
    actions.innerHTML = '';
    buttons.forEach((b) => {
        const btn = document.createElement('button');
        btn.className = 'wood-btn' + (b.muted ? ' muted' : '') + (b.danger ? ' danger' : '');
        btn.textContent = b.label;
        btn.onclick = () => { if (b.onClick && b.onClick() === false) return; closeModal(); };
        actions.appendChild(btn);
    });
    $('modal-backdrop').classList.remove('hidden');
}

function closeModal() { $('modal-backdrop').classList.add('hidden'); }

function confirmModal(title, text, confirmLabel, onConfirm, danger = false) {
    openModal(title, `<p>${esc(text)}</p>`, [
        { label: t('ui_cancel'), muted: true },
        { label: confirmLabel, danger, onClick: onConfirm },
    ]);
}

function playerSelect(id, players) {
    return `<select id="${id}">${players.map((p) => `<option value="${p.id}">${esc(p.name)} (${Math.round(p.distance)}m)</option>`).join('')}</select>`;
}

// ---------- tabs ----------
function tabList() {
    const s = state;
    const tabs = [{ id: 'herd', icon: '&#10022;', label: t('ui_tab_herd') }];
    if (s.grade >= 1) {
        tabs.push({ id: 'storage', icon: '&#9635;', label: t('ui_tab_storage') });
        tabs.push({ id: 'market', icon: '&#9878;', label: t('ui_tab_market') });
        if (s.catalog) tabs.push({ id: 'supplies', icon: '&#9998;', label: t('ui_tab_supplies') });
    }
    if (s.canManageStaff) tabs.push({ id: 'staff', icon: '&#9733;', label: t('ui_tab_staff') });
    if (s.isOwner) tabs.push({ id: 'ranch', icon: '&#9873;', label: t('ui_tab_ranch') });
    tabs.push({ id: 'guide', icon: '?', label: t('ui_tab_guide') });
    return tabs;
}

function renderTabs() {
    const tabs = tabList();
    if (!tabs.find((x) => x.id === activeTab)) activeTab = 'herd';
    let html = tabs.map((x) => `<div class="tab ${x.id === activeTab ? 'active' : ''}" data-tab="${x.id}"><span class="icon">${x.icon}</span>${esc(x.label)}</div>`).join('');
    html += '<div class="spacer"></div>';
    if (state.herdingEnabled && state.grade >= 1) html += `<button class="wood-btn" id="btn-herding">${esc(t('ui_start_herding'))}</button>`;
    $('tabs').innerHTML = html;
    $('tabs').querySelectorAll('.tab').forEach((el) => { el.onclick = () => { activeTab = el.dataset.tab; render(); }; });
    const herd = $('btn-herding');
    if (herd) herd.onclick = () => post('openHerding');
}

function render() {
    if (!state) return;
    $('ranch-name').textContent = state.name;
    $('ranch-sub').textContent = `${state.gradeLabel || ''}${state.isOwner ? ' · ' + t('ui_owner') : ''} · ${t('ui_cash')}: ${money(state.cash)}`;
    renderTabs();
    const views = { herd: viewHerd, storage: viewStorage, market: viewMarket, supplies: viewSupplies, staff: viewStaff, ranch: viewRanch, guide: viewGuide };
    clearInterval(orderTimer);
    const scroll = $('content').scrollTop;
    $('content').innerHTML = (views[activeTab] || viewHerd)();
    $('content').scrollTop = scroll;
    bindContent();
}

// ---------- herd ----------
function needsCare(a) { return a.is_unhealthy || a.is_hungry || a.is_thirsty; }

function viewHerd() {
    const s = state, sum = s.summary || {}, animals = s.animals || [];
    const products = animals.filter((a) => a.product_ready).length;
    const gender = sum.byGender || {};
    const tiles = [
        { v: `${sum.total || 0}/${s.maxAnimals}`, l: t('ui_animals') },
        { v: sum.pregnant || 0, l: t('ui_pregnant') },
        { v: sum.ready_for_breeding || 0, l: t('ui_ready_to_breed'), c: 'good' },
        { v: products, l: t('ui_products_ready'), c: products ? 'good' : '' },
        { v: sum.hungry || 0, l: t('ui_hungry'), c: sum.hungry ? 'warn' : '' },
        { v: sum.thirsty || 0, l: t('ui_thirsty'), c: sum.thirsty ? 'warn' : '' },
        { v: sum.unhealthy || 0, l: t('ui_unhealthy'), c: sum.unhealthy ? 'bad' : '' },
        { v: `${gender.male || 0} / ${gender.female || 0}`, l: t('ui_males_females') },
    ];

    const filters = [
        ['all', t('ui_filter_all')], ['a_c_cow', t('sv_animal_cow')], ['a_c_bull_01', t('sv_animal_bull')],
        ['a_c_pig_01', t('sv_animal_pig')], ['a_c_sheep_01', t('sv_animal_sheep')], ['care', t('ui_filter_care')], ['pregnant', t('ui_pregnant')],
    ];

    const list = animals.filter((a) => {
        if (herdFilter === 'all') return true;
        if (herdFilter === 'care') return needsCare(a);
        if (herdFilter === 'pregnant') return a.pregnant;
        return a.model === herdFilter;
    });

    const rows = list.map((a) => {
        const pills = [];
        if (a.pregnant) pills.push(`<span class="pill warn">${esc(t('ui_pregnant'))}</span>`);
        else if (a.breeding_ready) pills.push(`<span class="pill good">${esc(t('ui_ready_to_breed'))}</span>`);
        if (a.product_ready) pills.push(`<span class="pill good">${esc(t('ui_product'))}</span>`);
        if (needsCare(a)) pills.push(`<span class="pill bad">${esc(t('ui_needs_care'))}</span>`);
        return `<div class="row clickable" data-animal="${esc(a.animalid)}">
            <div class="badge-icon">${ICONS[a.model] || '&#10022;'}</div>
            <div class="row-main">
                <div class="row-title">${esc(a.label)} <span class="row-desc">#${esc(a.animalid)} · ${esc(t('ui_gender_' + a.gender))} · ${esc(t('ui_age_days', a.age))}</span></div>
                <div class="stats">${bar(t('ui_health'), a.health)}${bar(t('ui_hunger'), a.hunger)}${bar(t('ui_thirst'), a.thirst)}</div>
            </div>
            <div class="row-actions col">${pills.join('')}</div>
        </div>`;
    }).join('');

    return `<div class="tiles">${tiles.map((x) => `<div class="tile ${x.c || ''}"><div class="value">${esc(x.v)}</div><div class="label">${esc(x.l)}</div></div>`).join('')}</div>
        <div class="filters">${filters.map(([k, l]) => `<div class="chip ${herdFilter === k ? 'active' : ''}" data-filter="${k}">${esc(l)}</div>`).join('')}</div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_no_animals'))}</div>`}</div>`;
}

function showAnimal(id) {
    const a = (state.animals || []).find((x) => String(x.animalid) === String(id));
    if (!a) return;
    let status = t('ui_not_ready');
    if (a.pregnant) status = a.dueIn > 0 ? t('ui_due_in', duration(a.dueIn)) : t('ui_due_now');
    else if (a.breedingCooldown > 0) status = t('ui_breeding_cooldown', duration(a.breedingCooldown));
    else if (a.breeding_ready) status = t('ui_ready_to_breed');

    openModal(`${a.label} #${a.animalid}`, `
        <div class="detail-grid">
            <div><div class="k">${esc(t('ui_gender'))}</div>${esc(t('ui_gender_' + a.gender))}</div>
            <div><div class="k">${esc(t('ui_age'))}</div>${esc(t('ui_age_days', a.age))}</div>
            <div><div class="k">${esc(t('ui_breeding'))}</div>${esc(status)}</div>
            <div><div class="k">${esc(t('ui_product'))}</div>${esc(a.product_ready ? t('ui_ready') : t('ui_not_ready'))}</div>
        </div>
        <div class="stats single">${bar(t('ui_health'), a.health)}${bar(t('ui_hunger'), a.hunger)}${bar(t('ui_thirst'), a.thirst)}</div>
        <p class="spaced">${esc(t('ui_animal_hint'))}</p>`,
        [{ label: t('ui_close'), muted: true }]);
}

// ---------- storage ----------
function viewStorage() {
    const s = state, storages = s.storages || [];
    const levels = s.accessLevels || [];
    const levelLabel = (g) => (levels.find((l) => l.grade === g) || {}).label || '';

    const rows = storages.map((st) => {
        const general = st.storageid === s.ranchid;
        let manage = '';
        if (s.isOwner) {
            manage += `<button class="wood-btn small muted" data-rename="${esc(st.storageid)}" data-label="${esc(st.label)}">${esc(t('ui_rename'))}</button>`;
            if (!general && levels.length) {
                manage += `<select data-access="${esc(st.storageid)}">${levels.map((l) => `<option value="${l.grade}" ${l.grade === st.min_grade ? 'selected' : ''}>${esc(l.label)}</option>`).join('')}</select>`;
            }
        }
        const locked = s.grade < (st.min_grade || 0);
        const access = levelLabel(st.min_grade);
        return `<div class="row ${locked ? 'disabled' : ''}">
            <div class="badge-icon">&#9635;</div>
            <div class="row-main"><div class="row-title">${esc(st.label)}</div>
            <div class="row-desc">${esc(t('ui_storage_desc', st.slots, Math.round((st.maxweight || 0) / 1000)))}${access ? ' · ' + esc(access) : ''}</div></div>
            <div class="row-actions">${manage}<button class="wood-btn small" data-open="${esc(st.storageid)}" ${locked ? 'disabled' : ''}>${esc(t('ui_open'))}</button></div>
        </div>`;
    }).join('');

    let buy = '';
    if (s.isOwner && s.storageSizes) {
        buy = `<div class="section-title">${esc(t('ui_buy_storage'))}</div><div class="list">` + s.storageSizes.map((z) => `
            <div class="row"><div class="badge-icon">+</div>
            <div class="row-main"><div class="row-title">${esc(z.label)}</div><div class="row-desc">${esc(t('ui_storage_desc', z.slots, Math.round(z.maxweight / 1000)))}</div></div>
            <div class="row-actions"><span class="pill">${money(z.price)}</span><button class="wood-btn small" data-buystorage="${esc(z.key)}" data-price="${z.price}" data-name="${esc(z.label)}">${esc(t('ui_buy'))}</button></div></div>`).join('') + '</div>';
    }

    return `<div class="section-title">${esc(t('ui_tab_storage'))}</div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_no_storage'))}</div>`}</div>${buy}`;
}

// ---------- market ----------
function viewMarket() {
    const list = state.market || [];
    const rows = list.map((m) => `<div class="row ${m.canSell ? '' : 'disabled'}">
        <div class="badge-icon">${SPECIES_ICON[m.species] || '&#10022;'}</div>
        <div class="row-main"><div class="row-title">${esc(m.label)} <span class="row-desc">#${esc(m.animalid)}</span></div>
        <div class="row-desc">${esc(t('ui_gender_' + m.gender))} · ${esc(t('ui_age_days', m.age))} · ${esc(m.ageCategory)} · ${esc(t('ui_health'))} ${Math.round(m.health)}%</div></div>
        <div class="row-actions"><span class="pill ${m.canSell ? 'good' : ''}">${m.canSell ? money(m.salePrice) : esc(t('ui_too_young'))}</span>${m.directSalePct != null && m.canSell ? `<span class="pill" title="${esc(t('ui_direct_sale_hint', m.directSalePct))}">${esc(t('ui_direct_sale', m.directSalePct))}</span>` : ''}
            <button class="wood-btn small" data-sell="${esc(m.animalid)}" data-species="${m.species}" data-price="${m.salePrice}" ${m.canSell ? '' : 'disabled'}>${esc(t('ui_sell'))}</button>
            ${m.canSlaughter === false ? '' : `<button class="wood-btn small danger" data-slaughter="${esc(m.animalid)}" data-species="${m.species}" ${m.canSell ? '' : 'disabled'}>${esc(t('ui_slaughter'))}</button>`}
        </div></div>`).join('');
    return `<div class="section-title">${esc(t('ui_market_title'))}</div>
        <p class="italic hint">${esc(t('ui_market_hint'))}</p>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_no_market'))}</div>`}</div>`;
}

// ---------- supplies ----------
const ITEM_IMG_PATH = 'nui://rsg-inventory/html/images/';
function itemIcon(item, fallback) {
    return `<div class="badge-icon item-icon"><img src="${ITEM_IMG_PATH}${esc(item)}.png" alt="" onerror="this.style.display='none';this.nextElementSibling.style.display='inline'"><span class="fb">${fallback}</span></div>`;
}
function viewSupplies() {
    const s = state;
    const catalog = (s.catalog || []).map((c) => `<div class="row">
        ${itemIcon(c.item, '&#9998;')}
        <div class="row-main"><div class="row-title">${esc(c.label)}</div><div class="row-desc">${esc(t('ui_delivery_in', duration(c.deliveryTime)))}</div></div>
        <div class="row-actions"><span class="pill">${money(c.price)} ${esc(t('ui_each'))}</span>
            <input class="qty" type="number" min="1" max="${s.maxPerOrder}" value="1" id="qty-${esc(c.item)}">
            <button class="wood-btn small" data-order="${esc(c.item)}" data-price="${c.price}" data-name="${esc(c.label)}">${esc(t('ui_order'))}</button></div></div>`).join('');

    const orders = (s.orders || []).map((o) => `<div class="row">
        ${itemIcon(o.item, '&#9744;')}
        <div class="row-main"><div class="row-title">${esc(o.amount)}x ${esc(o.label)}</div>
        <div class="row-desc" data-countdown="${o.secondsLeft}">${o.ready ? esc(t('ui_ready_collect')) : esc(t('ui_arrives_in', duration(o.secondsLeft)))}</div></div>
        <div class="row-actions"><button class="wood-btn small" data-collect="${esc(o.orderid)}" ${o.ready ? '' : 'disabled'}>${esc(t('ui_collect'))}</button></div></div>`).join('');

    return `<div class="section-title">${esc(t('ui_orders'))}</div>
        <div class="list">${orders || `<div class="empty">${esc(t('ui_no_orders'))}</div>`}</div>
        <div class="section-title">${esc(t('ui_catalog'))}</div><div class="list">${catalog}</div>`;
}

// ---------- staff ----------
function viewStaff() {
    const s = state, staff = s.staff || [];
    const rows = staff.map((e) => {
        const protectedRank = e.grade >= s.grade;
        const canPromote = e.is_online && e.grade < s.grade && (s.isBoss || e.grade + 1 < s.grade);
        const canDemote = e.is_online && e.grade > 0 && !protectedRank;
        return `<div class="row">
            <div class="badge-icon">&#9733;</div>
            <div class="row-main"><div class="row-title">${esc(e.name)}</div><div class="row-desc">${esc(e.grade_label)} · ${esc(e.is_online ? t('ui_online') : t('ui_offline'))}</div></div>
            <div class="row-actions">
                <button class="wood-btn small muted" data-promote="${esc(e.citizenid)}" ${canPromote ? '' : 'disabled'}>${esc(t('ui_promote'))}</button>
                <button class="wood-btn small muted" data-demote="${esc(e.citizenid)}" ${canDemote ? '' : 'disabled'}>${esc(t('ui_demote'))}</button>
                <button class="wood-btn small danger" data-fire="${esc(e.citizenid)}" data-name="${esc(e.name)}" ${protectedRank ? 'disabled' : ''}>${esc(t('ui_fire'))}</button>
            </div></div>`;
    }).join('');
    return `<div class="section-title"><span>${esc(t('ui_staff_count', staff.length, s.maxStaff))}</span>
        <button class="wood-btn small" id="btn-hire">${esc(t('ui_hire'))}</button></div>
        <div class="list">${rows || `<div class="empty">${esc(t('ui_no_staff'))}</div>`}</div>`;
}

async function hireFlow() {
    const players = await post('getNearbyPlayers') || [];
    if (!players.length) { toast(t('ui_no_nearby'), 'error'); return; }
    const grades = [{ g: 0, l: t('ui_grade_0') }, { g: 1, l: t('ui_grade_1') }].filter((x) => x.g < state.grade);
    openModal(t('ui_hire'), `
        <div class="field"><label>${esc(t('ui_player'))}</label>${playerSelect('hire-player', players)}</div>
        <div class="field"><label>${esc(t('ui_grade'))}</label><select id="hire-grade">${grades.map((x) => `<option value="${x.g}">${esc(x.l)}</option>`).join('')}</select></div>`,
        [{ label: t('ui_cancel'), muted: true },
         { label: t('ui_hire'), onClick: () => action('hire', { id: $('hire-player').value, grade: $('hire-grade').value }) }]);
}

// ---------- ranch (owner) ----------
function viewRanch() {
    const s = state, refund = s.sellRefund ?? Math.floor(s.ranchPrice * s.sellRefundPct / 100);
    const graceLeft = s.sellGraceLeft || 0;
    const graceTxt = graceLeft > 0 ? ' ' + t('ui_sell_ranch_grace', Math.floor(graceLeft / 3600) + 'h ' + Math.floor((graceLeft % 3600) / 60) + 'm') : '';
    return `<div class="section-title">${esc(t('ui_tab_ranch'))}</div><div class="list">
        <div class="row"><div class="badge-icon">&#8644;</div>
            <div class="row-main"><div class="row-title">${esc(t('ui_transfer'))}</div><div class="row-desc">${esc(t('ui_transfer_desc'))}</div></div>
            <div class="row-actions"><button class="wood-btn small" id="btn-transfer">${esc(t('ui_transfer'))}</button></div></div>
        <div class="row"><div class="badge-icon">!</div>
            <div class="row-main"><div class="row-title">${esc(t('ui_sell_ranch'))}</div><div class="row-desc">${esc(t('ui_sell_ranch_desc', money(refund), s.sellRefundPct) + graceTxt)}</div></div>
            <div class="row-actions"><button class="wood-btn small danger" id="btn-sellranch" data-refund="${refund}">${esc(t('ui_sell_ranch'))}</button></div></div>
    </div>`;
}

async function transferFlow() {
    const players = await post('getNearbyPlayers') || [];
    if (!players.length) { toast(t('ui_no_nearby'), 'error'); return; }
    openModal(t('ui_transfer'), `<p>${esc(t('ui_transfer_warn'))}</p>
        <div class="field spaced"><label>${esc(t('ui_player'))}</label>${playerSelect('transfer-player', players)}</div>`,
        [{ label: t('ui_cancel'), muted: true },
         { label: t('ui_transfer'), danger: true, onClick: () => { post('transferRanch', { id: $('transfer-player').value }); } }]);
}

// ---------- guide ----------
function viewGuide() {
    const cards = ['feed', 'water', 'products', 'breeding', 'herding', 'selling'].map((k) => `
        <div class="row guide-card"><div class="badge-icon">?</div>
        <div class="row-main"><div class="row-title">${esc(t('ui_guide_' + k + '_title'))}</div><div class="row-desc">${esc(t('ui_guide_' + k))}</div></div></div>`).join('');
    return `<div class="section-title">${esc(t('ui_tab_guide'))}</div><div class="list">${cards}</div>`;
}

// ---------- bindings ----------
function bind(selector, handler, evt = 'onclick') {
    $('content').querySelectorAll(selector).forEach((el) => { el[evt] = () => handler(el); });
}

function bindContent() {
    bind('[data-filter]', (el) => { herdFilter = el.dataset.filter; render(); });
    bind('[data-animal]', (el) => showAnimal(el.dataset.animal));

    bind('[data-open]', (el) => post('openStorage', { storageid: el.dataset.open }));
    bind('[data-rename]', (el) => openModal(t('ui_rename'),
        `<div class="field"><label>${esc(t('ui_name'))}</label><input id="rename-input" maxlength="50" value="${esc(el.dataset.label)}"></div>`,
        [{ label: t('ui_cancel'), muted: true },
         { label: t('ui_save'), onClick: () => { const v = $('rename-input').value.trim(); if (!v) return false; action('renameStorage', { storageid: el.dataset.rename, label: v }); } }]));
    bind('[data-access]', (el) => action('storageAccess', { storageid: el.dataset.access, mingrade: Number(el.value) }), 'onchange');
    bind('[data-buystorage]', (el) => confirmModal(t('ui_buy_storage'),
        t('ui_confirm_buy', el.dataset.name, money(el.dataset.price)), t('ui_buy'), () => action('buyStorage', { size: el.dataset.buystorage })));

    bind('[data-sell]', (el) => confirmModal(t('ui_sell'),
        t('ui_confirm_sell', money(el.dataset.price)), t('ui_sell'), () => action('sellAnimal', { animalid: el.dataset.sell, species: el.dataset.species })));
    bind('[data-slaughter]', (el) => confirmModal(t('ui_slaughter'),
        t('ui_confirm_slaughter'), t('ui_slaughter'), () => action('slaughter', { animalid: el.dataset.slaughter, species: el.dataset.species }), true));

    bind('[data-order]', (el) => {
        const qty = Math.max(1, Math.min(state.maxPerOrder, parseInt($('qty-' + el.dataset.order).value, 10) || 1));
        confirmModal(t('ui_order'), t('ui_confirm_order', qty, el.dataset.name, money(qty * Number(el.dataset.price))), t('ui_order'),
            () => action('orderSupply', { item: el.dataset.order, amount: qty }));
    });
    bind('[data-collect]', (el) => action('collectOrder', { orderid: el.dataset.collect }));

    bind('[data-promote]', (el) => action('promote', { citizenid: el.dataset.promote }));
    bind('[data-demote]', (el) => action('demote', { citizenid: el.dataset.demote }));
    bind('[data-fire]', (el) => confirmModal(t('ui_fire'),
        t('ui_confirm_fire', el.dataset.name), t('ui_fire'), () => action('fire', { citizenid: el.dataset.fire }), true));

    const hire = $('btn-hire'); if (hire) hire.onclick = hireFlow;
    const tr = $('btn-transfer'); if (tr) tr.onclick = transferFlow;
    const sr = $('btn-sellranch');
    if (sr) sr.onclick = () => confirmModal(t('ui_sell_ranch'),
        t('ui_confirm_sell_ranch', state.name, money(sr.dataset.refund)), t('ui_sell_ranch'), () => { post('sellRanch'); }, true);

    // live countdowns on pending supply orders
    const countdowns = $('content').querySelectorAll('[data-countdown]');
    if (countdowns.length) {
        orderTimer = setInterval(() => {
            countdowns.forEach((el) => {
                const left = Number(el.dataset.countdown) - 1;
                if (left < 0) return;
                el.dataset.countdown = left;
                el.textContent = left === 0 ? t('ui_ready_collect') : t('ui_arrives_in', duration(left));
                if (left === 0) {
                    const b = el.closest('.row').querySelector('[data-collect]');
                    if (b) b.disabled = false;
                }
            });
        }, 1000);
    }
}

// ---------- purchase ----------
function renderPurchase(d) {
    $('purchase-name').textContent = d.name;
    $('purchase-price').textContent = money(d.price);
    const cash = $('purchase-cash');
    cash.textContent = t('ui_you_have', money(d.cash));
    cash.classList.toggle('over', d.cash < d.price);
    const btn = $('btn-purchase');
    btn.disabled = d.cash < d.price;
    btn.onclick = () => post('purchaseRanch', { ranchid: d.ranchid });
}

// ---------- open / close ----------
function closeUi() {
    closeModal();
    clearInterval(orderTimer);
    $('app').classList.add('hidden');
    $('manage').classList.add('hidden');
    $('purchase').classList.add('hidden');
    state = null;
    mode = null;
}

window.addEventListener('message', (e) => {
    const msg = e.data || {};
    if (msg.action === 'open') {
        L = msg.locales || {};
        applyStaticText();
        mode = msg.mode;
        $('app').classList.remove('hidden');
        if (mode === 'purchase') {
            $('purchase').classList.remove('hidden');
            renderPurchase(msg.data);
        } else {
            activeTab = 'herd';
            herdFilter = 'all';
            state = msg.data;
            $('manage').classList.remove('hidden');
            render();
        }
    } else if (msg.action === 'update' && mode === 'manage') {
        state = msg.data;
        render();
    } else if (msg.action === 'close') {
        closeUi();
    }
});

$('btn-close').onclick = () => post('close');
document.querySelectorAll('[data-close]').forEach((el) => { el.onclick = () => post('close'); });

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !mode) return;
    if (!$('modal-backdrop').classList.contains('hidden')) closeModal();
    else post('close');
});

// ---------- context menu / alert dialog (NUI replacement for ox_lib menus) ----------
let ctxMenu = null;
let alertOpen = false;

function fmtText(s) {
    // escape, then allow simple **bold** markdown used in dialogs
    return esc(s).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
}

function barClass(o) {
    if (o.color) return 'stat-' + o.color;
    const p = Number(o.progress) || 0;
    return p >= 60 ? 'stat-good' : p >= 30 ? 'stat-warn' : 'stat-bad';
}

function renderCtx(menu) {
    ctxMenu = menu;
    $('ctx-title').textContent = menu.title || '';
    $('ctx-back').classList.toggle('hidden', !menu.back);
    $('ctx-close').classList.toggle('hidden', menu.canClose === false);
    const list = $('ctx-list');
    list.innerHTML = '';
    (menu.options || []).forEach((o) => {
        if (o.header) {
            const h = document.createElement('div');
            h.className = 'ctx-section';
            h.innerHTML = fmtText(o.title);
            list.appendChild(h);
            return;
        }
        const row = document.createElement('div');
        row.className = 'ctx-row' + (o.clickable ? ' clickable' : ' info-row') + (o.disabled ? ' disabled' : '');
        let html = `<div class="ctx-main"><div class="ctx-title">${fmtText(o.title)}</div>`;
        if (o.description) html += `<div class="ctx-desc">${fmtText(o.description)}</div>`;
        if (o.progress !== undefined && o.progress !== null) {
            const p = Math.max(0, Math.min(100, Number(o.progress)));
            html += `<div class="ctx-bar"><div class="${barClass(o)}" style="width:${p}%"></div></div>`;
        }
        if (o.metadata && o.metadata.length) {
            html += '<div class="ctx-meta">' + o.metadata.map((m) =>
                `<span class="k">${esc(m.label)}</span><span class="v">${esc(m.value ?? '')}</span>`).join('') + '</div>';
        }
        html += '</div>';
        if (o.clickable && o.arrow) html += '<div class="ctx-arrow">&#10095;</div>';
        row.innerHTML = html;
        if (o.clickable) row.onclick = () => post('menu:select', { id: menu.id, index: o.index });
        list.appendChild(row);
    });
    list.scrollTop = 0;
    $('ctx-root').classList.remove('hidden');
}

function hideCtx() {
    ctxMenu = null;
    $('ctx-root').classList.add('hidden');
}

function showAlert(a) {
    alertOpen = true;
    $('alert-title').textContent = a.header || '';
    $('alert-body').innerHTML = fmtText(a.content || '');
    const actions = $('alert-actions');
    actions.innerHTML = '';
    const done = (result) => {
        alertOpen = false;
        $('alert-root').classList.add('hidden');
        post('alert:result', { result });
    };
    if (a.cancel) {
        const c = document.createElement('button');
        c.className = 'wood-btn muted';
        c.textContent = a.cancelLabel || t('ui_cancel');
        c.onclick = () => done('cancel');
        actions.appendChild(c);
    }
    const ok = document.createElement('button');
    ok.className = 'wood-btn';
    ok.textContent = a.confirmLabel || t('ui_confirm');
    ok.onclick = () => done('confirm');
    actions.appendChild(ok);
    $('alert-root').classList.remove('hidden');
    alertDone = done;
}
let alertDone = null;

window.addEventListener('message', (e) => {
    const msg = e.data || {};
    if (msg.action === 'menu:open') renderCtx(msg.menu);
    else if (msg.action === 'menu:close') hideCtx();
    else if (msg.action === 'alert:open') showAlert(msg.alert);
    else if (msg.action === 'alert:close' && alertOpen) {
        alertOpen = false;
        $('alert-root').classList.add('hidden');
    }
});

$('ctx-close').onclick = () => post('menu:close');
$('ctx-back').onclick = () => post('menu:back');

document.addEventListener('keydown', (e) => {
    if (alertOpen) {
        if (e.key === 'Escape' && alertDone) alertDone('cancel');
        else if (e.key === 'Enter' && alertDone) alertDone('confirm');
        return;
    }
    if (!ctxMenu) return;
    if (e.key === 'Escape' && ctxMenu.canClose !== false) post('menu:close');
    else if (e.key === 'Backspace' && ctxMenu.back) post('menu:back');
});

// ---------- movable panels ----------
// Drag any panel by its header; positions are saved per panel in localStorage.
// Double-click a header to reset that panel to its default position.
const DRAG_KEY = 'rsg-ranch:ui-pos';
let dragPos = {};
try { dragPos = JSON.parse(localStorage.getItem(DRAG_KEY) || '{}') || {}; } catch (_) { dragPos = {}; }

function saveDragPos() {
    try { localStorage.setItem(DRAG_KEY, JSON.stringify(dragPos)); } catch (_) { /* ignore */ }
}

function applyDrag(el) {
    const p = dragPos[el.dataset.drag];
    el.style.transform = p ? `translate(${p.x}px, ${p.y}px)` : '';
}

// keep at least part of the panel on screen (e.g. after a resolution change)
function clampDrag(el) {
    const key = el.dataset.drag;
    const p = dragPos[key];
    if (!p || el.offsetParent === null) return;
    const r = el.getBoundingClientRect();
    const margin = 60;
    let dx = 0, dy = 0;
    if (r.right < margin) dx = margin - r.right;
    if (r.left > innerWidth - margin) dx = innerWidth - margin - r.left;
    if (r.top < 0) dy = -r.top;
    if (r.top > innerHeight - margin) dy = innerHeight - margin - r.top;
    if (dx || dy) { p.x += dx; p.y += dy; applyDrag(el); saveDragPos(); }
}

document.querySelectorAll('[data-drag]').forEach((el) => {
    const handle = el.querySelector(el.dataset.handle || '.panel-header') || el;
    handle.classList.add('drag-handle');
    applyDrag(el);

    handle.addEventListener('mousedown', (e) => {
        if (e.button !== 0 || e.target.closest('button, input, select, textarea, a')) return;
        e.preventDefault();
        const key = el.dataset.drag;
        const start = dragPos[key] || { x: 0, y: 0 };
        const sx = e.clientX, sy = e.clientY;
        document.body.classList.add('dragging');
        const move = (ev) => {
            dragPos[key] = { x: start.x + ev.clientX - sx, y: start.y + ev.clientY - sy };
            applyDrag(el);
        };
        const up = () => {
            document.body.classList.remove('dragging');
            document.removeEventListener('mousemove', move);
            document.removeEventListener('mouseup', up);
            clampDrag(el);
            saveDragPos();
        };
        document.addEventListener('mousemove', move);
        document.addEventListener('mouseup', up);
    });

    handle.addEventListener('dblclick', (e) => {
        if (e.target.closest('button')) return;
        delete dragPos[el.dataset.drag];
        applyDrag(el);
        saveDragPos();
    });
});

// re-check positions whenever something opens
window.addEventListener('message', () => {
    requestAnimationFrame(() => document.querySelectorAll('[data-drag]').forEach(clampDrag));
});
