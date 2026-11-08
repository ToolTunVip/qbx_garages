const inGame = typeof GetParentResourceName === 'function';

// Chuỗi mặc định (tiếng Anh). Lua sẽ gửi bản dịch từ locales/*.json khi mở UI.
const DEFAULT_STRINGS = {
    inspection: 'VEHICLE INSPECTION',
    selectVehicle: 'SELECT A VEHICLE',
    placeholder: 'Choose a vehicle from the list on the left.',
    body: 'BODY CONDITION',
    engine: 'ENGINE HEALTH',
    fuel: 'FUEL LEVEL',
    takeOut: 'TAKE OUT VEHICLE',
    payDepot: 'PAY DEPOT ($%s)',
    vehiclesFound: '%s VEHICLES',
    noVehicles: 'No vehicles in this garage.',
    statusGaraged: 'Garaged',
    statusOut: 'Out',
    statusImpounded: 'Impounded',
    description: 'Name: %s\nPlate: %s\nDepot fee: $%s',
    keyNavigate: 'UP / DOWN', hintNavigate: 'SELECT',
    keySelect: 'ENTER', hintSelect: 'TAKE OUT',
    keyDrag: 'DRAG', hintDrag: 'ROTATE',
    keyZoom: 'WHEEL', hintZoom: 'ZOOM',
    keyClose: 'ESC', hintClose: 'CLOSE',
};

let S = { ...DEFAULT_STRINGS };

const state = {
    vehicles: [],
    selected: -1,
    garageName: '',
    garageType: '',
    busy: false,
};

const $ = (id) => document.getElementById(id);

function post(endpoint, data = {}) {
    if (!inGame) {
        console.log('[NUI demo]', endpoint, data);
        return Promise.resolve();
    }
    return fetch(`https://${GetParentResourceName()}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    }).catch(() => {});
}

function fmt(str, ...args) {
    let i = 0;
    return String(str).replace(/%s/g, () => (i < args.length ? args[i++] : ''));
}

function formatMoney(n) {
    return Number(n || 0).toLocaleString('en-US');
}

function applyStrings() {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
        const key = el.dataset.i18n;
        if (S[key] !== undefined) el.textContent = S[key];
    });
}

function getProgressColorClass(percent) {
    if (percent >= 75) return 'green';
    if (percent > 25) return 'yellow';
    return 'red';
}

function setBar(name, value) {
    $(`val-${name}`).textContent = `${value}%`;
    const bar = $(`bar-${name}`);
    bar.className = `progress-bar-fill ${getProgressColorClass(value)}`;
    bar.style.width = `${value}%`;
}

function renderVehicles() {
    const list = $('vehicle-list');
    list.innerHTML = '';
    $('vehicle-count').textContent = fmt(S.vehiclesFound, state.vehicles.length);

    if (!state.vehicles.length) {
        const empty = document.createElement('div');
        empty.className = 'placeholder-text';
        empty.style.padding = '20px 0';
        empty.textContent = S.noVehicles;
        list.appendChild(empty);
        return;
    }

    state.vehicles.forEach((veh, index) => {
        let statusText = S.statusGaraged;
        let statusClass = 'garaged';
        if (veh.state === 0) { statusText = S.statusOut; statusClass = 'out'; }
        else if (veh.state === 2) { statusText = S.statusImpounded; statusClass = 'impounded'; }

        const card = document.createElement('div');
        card.className = `vehicle-card ${state.selected === index ? 'active' : ''}`;

        const info = document.createElement('div');
        info.className = 'vc-info';
        const name = document.createElement('h4');
        name.textContent = (veh.label || veh.modelName).toUpperCase();
        const plate = document.createElement('p');
        plate.textContent = veh.plate;
        info.append(name, plate);

        const status = document.createElement('div');
        status.className = `vc-status ${statusClass}`;
        status.textContent = statusText;

        card.append(info, status);
        card.addEventListener('click', () => selectVehicle(index));
        list.appendChild(card);
    });
}

function selectVehicle(index) {
    const veh = state.vehicles[index];
    if (!veh) return;

    const changed = state.selected !== index;
    state.selected = index;
    renderVehicles();

    const active = $('vehicle-list').children[index];
    if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });

    const label = (veh.label || veh.modelName).toUpperCase();
    $('info-veh-name').textContent = label;
    $('info-plate').textContent = veh.plate;

    setBar('body', veh.body);
    setBar('engine', veh.engine);
    setBar('fuel', veh.fuel);

    const isDepot = state.garageType === 'depot';
    const price = isDepot ? (veh.depotPrice || 0) : 0;

    let desc = fmt(S.description, veh.label || veh.modelName, veh.plate, formatMoney(veh.depotPrice));
    if (!veh.canTakeOut && veh.message) desc = veh.message;
    $('info-description').textContent = desc;

    $('btn-takeout-text').textContent = price > 0 ? fmt(S.payDepot, formatMoney(price)) : S.takeOut;
    $('btn-takeout').disabled = !veh.canTakeOut;

    $('placeholder').classList.add('hidden');
    $('veh-details-wrap').classList.remove('hidden');

    // báo Lua đổi xe đang xem (camera tự căn theo xe mới)
    if (changed) post('previewVehicle', { id: veh.id });
}

function takeOut() {
    const veh = state.vehicles[state.selected];
    if (!veh || !veh.canTakeOut || state.busy) return;
    state.busy = true;
    post('takeOutVehicle', { vehicleId: veh.id });
}

function closeUi() {
    post('closeGarage');
}

/* ===================== Lua -> NUI ===================== */
window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data.action) return;

    if (data.action === 'openGarage') {
        S = { ...DEFAULT_STRINGS, ...(data.strings || {}) };
        applyStrings();

        state.garageName = data.garageName;
        state.garageType = data.garageType || '';
        state.vehicles = data.vehicles || [];
        state.selected = -1;
        state.busy = false;

        $('garage-title').textContent = (data.garageLabel || 'Garage').toUpperCase();
        $('info-veh-name').textContent = S.selectVehicle;
        $('info-plate').textContent = '---';
        $('placeholder').classList.remove('hidden');
        $('veh-details-wrap').classList.add('hidden');

        document.body.classList.add('ui-open');
        renderVehicles();
        if (state.vehicles.length > 0) selectVehicle(0);
    } else if (data.action === 'closeGarage') {
        document.body.classList.remove('ui-open');
        state.busy = false;
    }
});

/* ===================== Nút / bàn phím ===================== */
$('btn-takeout').addEventListener('click', takeOut);

window.addEventListener('keydown', (e) => {
    if (!document.body.classList.contains('ui-open')) return;

    switch (e.key) {
        case 'ArrowDown':
            e.preventDefault();
            selectVehicle(Math.min(state.vehicles.length - 1, state.selected + 1));
            break;
        case 'ArrowUp':
            e.preventDefault();
            selectVehicle(Math.max(0, state.selected - 1));
            break;
        case 'Enter':
            e.preventDefault();
            takeOut();
            break;
        case 'Escape':
        case 'Backspace':
            e.preventDefault();
            closeUi();
            break;
    }
});

/* ===================== Camera: kéo chuột + lăn chuột ===================== */
const capture = $('cam-capture');
let dragging = false;
let lastX = 0, lastY = 0, accX = 0, accY = 0, rafId = null;

function flushDrag() {
    rafId = null;
    if (accX || accY) {
        post('cameraMove', { dx: accX, dy: accY });
        accX = 0;
        accY = 0;
    }
}

capture.addEventListener('mousedown', (e) => {
    dragging = true;
    lastX = e.clientX;
    lastY = e.clientY;
    capture.classList.add('dragging');
});

window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    accX += e.clientX - lastX;
    accY += e.clientY - lastY;
    lastX = e.clientX;
    lastY = e.clientY;
    if (!rafId) rafId = requestAnimationFrame(flushDrag);
});

window.addEventListener('mouseup', () => {
    dragging = false;
    capture.classList.remove('dragging');
});

capture.addEventListener('wheel', (e) => {
    e.preventDefault();
    post('cameraZoom', { delta: Math.sign(e.deltaY) });
}, { passive: false });

capture.addEventListener('contextmenu', (e) => e.preventDefault());

/* ===================== Demo (mở file trong trình duyệt) ===================== */
if (!inGame) {
    window.addEventListener('load', () => {
        document.body.classList.add('demo');
        window.postMessage({
            action: 'openGarage',
            garageName: 'motel',
            garageLabel: 'Motel Parking',
            garageType: 'depot',
            vehicles: [
                { id: 1, modelName: 'sultanrs', label: 'Karin Sultan RS', plate: 'TTUN 8888', state: 1, depotPrice: 0, body: 95, engine: 98, fuel: 85, canTakeOut: true },
                { id: 2, modelName: 'zentorno', label: 'Pegassi Zentorno', plate: 'TOOLTUN', state: 0, depotPrice: 1500, body: 60, engine: 72, fuel: 40, canTakeOut: true },
                { id: 3, modelName: 't20', label: 'Progen T20', plate: 'TOOLTUN2', state: 2, depotPrice: 0, body: 20, engine: 15, fuel: 10, canTakeOut: false, message: 'Xe của bạn đã bị cảnh sát tạm giữ' },
            ],
        }, '*');
    });
}
