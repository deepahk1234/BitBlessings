/**
 * Blessings – script.js
 *
 * Responsibilities:
 *  1. JS ↔ Swift (WKWebView) bridge for asking & responding to blessing questions.
 *  2. Live rendering of blessing question cards with Yes / No / Wait vote bars.
 *  3. Interactive Garden (tree filtering, view toggle).
 *  4. Receive blessing updates pushed by Swift via window.onBlessingUpdate().
 *
 * Protocol (via window.webkit.messageHandlers):
 *   → sendBlessingQuestion  { question: String }
 *   → sendBlessingResponse  { questionId: String, response: "yes"|"no"|"wait" }
 *   → blessingReady         {}        (sent once the page is fully loaded)
 *
 * Swift → JS callbacks registered on window:
 *   ← window.onBlessingUpdate(payload)   (BlessingQuestion JSON payload)
 *   ← window.setMyNickname(name)
 */

'use strict';

// ─────────────────────────────────────────────
// STATE
// ─────────────────────────────────────────────

const MAX_RESPONDERS = 30;

/** Map from questionId → BlessingQuestion state object */
const questions = new Map();

let myNickname = 'anon';

// ─────────────────────────────────────────────
// SWIFT BRIDGE HELPERS
// ─────────────────────────────────────────────

/**
 * Send a message to Swift via WKWebView message handler.
 * Falls back gracefully when running outside a WKWebView (e.g. browser preview).
 */
function postToSwift(handlerName, payload = {}) {
    try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName]) {
            window.webkit.messageHandlers[handlerName].postMessage(payload);
        } else {
            // Dev/browser fallback: simulate a local blessing for testing
            simulateLocalResponse(handlerName, payload);
        }
    } catch (e) {
        console.warn('[Blessings] postToSwift failed:', e);
    }
}

/** Fallback: simulate Swift behaviour locally when there is no WKWebView */
function simulateLocalResponse(handlerName, payload) {
    if (handlerName === 'sendBlessingQuestion') {
        const q = {
            id: generateId(),
            question: payload.question,
            askerNickname: myNickname,
            isOwnQuestion: true,
            timestamp: Date.now(),
            yesCount: 0,
            noCount: 0,
            waitCount: 0,
            totalCount: 0,
            isFull: false,
            hasResponded: false,
            votes: []
        };
        window.onBlessingUpdate(q);
    } else if (handlerName === 'sendBlessingResponse') {
        const q = questions.get(payload.questionId);
        if (!q) return;
        const responseMap = { yes: 0, no: 0, wait: 0 };
        responseMap[payload.response]++;
        q.votes = [...q.votes, { voterNickname: myNickname, response: payload.response, emoji: responseEmoji(payload.response) }];
        q.yesCount = q.votes.filter(v => v.response === 'yes').length;
        q.noCount = q.votes.filter(v => v.response === 'no').length;
        q.waitCount = q.votes.filter(v => v.response === 'wait').length;
        q.totalCount = q.votes.length;
        q.hasResponded = true;
        window.onBlessingUpdate(q);
    }
}

function responseEmoji(r) {
    return r === 'yes' ? '🌿' : r === 'no' ? '🌼' : '🌸';
}

function generateId() {
    return Math.random().toString(36).substr(2, 8);
}

// ─────────────────────────────────────────────
// SWIFT → JS CALLBACKS
// ─────────────────────────────────────────────

/**
 * Called by Swift (BlessingsService.notifyJS) every time a question state changes.
 * Payload matches BlessingQuestion.jsPayload.
 */
window.onBlessingUpdate = function (payload) {
    questions.set(payload.id, payload);
    upsertBlessingCard(payload);
    updateActiveBadge();
    updateEmptyState();
};

/**
 * Called by Swift after the webview loads to set the current user's nickname.
 */
window.setMyNickname = function (name) {
    myNickname = name || 'anon';
    const el = document.getElementById('myNickDisplay');
    if (el) el.textContent = myNickname;
};

// ─────────────────────────────────────────────
// ASK A BLESSING
// ─────────────────────────────────────────────

function askBlessing() {
    const input = document.getElementById('questionInput');
    const question = (input.value || '').trim();
    if (!question) {
        input.focus();
        input.classList.add('shake');
        setTimeout(() => input.classList.remove('shake'), 400);
        return;
    }

    postToSwift('sendBlessingQuestion', { question });

    // Show confirmation
    const conf = document.getElementById('confirmation');
    conf.classList.remove('hidden');
    setTimeout(() => conf.classList.add('hidden'), 4000);

    // Reset
    input.value = '';
    updateCharCounter(input);
}

// ─────────────────────────────────────────────
// CAST A VOTE
// ─────────────────────────────────────────────

function castVote(btn, response) {
    const container = btn.closest('.bc-vote-buttons');
    const questionId = container.dataset.questionId;
    if (!questionId) return;

    // Disable all buttons in this card immediately
    container.querySelectorAll('.vote-btn').forEach(b => {
        b.disabled = true;
        b.classList.remove('selected');
    });
    btn.classList.add('selected');

    postToSwift('sendBlessingResponse', { questionId, response });
}

// ─────────────────────────────────────────────
// CARD RENDERING
// ─────────────────────────────────────────────

/** Insert or update a blessing card in the list */
function upsertBlessingCard(q) {
    const list = document.getElementById('blessingsList');
    const existingCard = document.getElementById('bc-' + q.id);

    if (existingCard) {
        updateCard(existingCard, q);
    } else {
        const card = createCard(q);
        list.insertBefore(card, list.firstChild);  // newest first
    }
}

function createCard(q) {
    const template = document.getElementById('blessingCardTemplate');
    const clone = template.content.cloneNode(true);
    const card = clone.querySelector('.blessing-card');

    card.id = 'bc-' + q.id;
    card.dataset.questionId = q.id;
    if (q.isOwnQuestion) {
        card.classList.add('own-card');
    }

    // Avatar initials
    const avatar = card.querySelector('.bc-avatar');
    avatar.textContent = (q.askerNickname || '?').charAt(0).toUpperCase();
    avatar.style.background = nicknameToGradient(q.askerNickname);

    card.querySelector('.bc-asker').textContent = q.askerNickname;
    card.querySelector('.bc-time').textContent = formatTime(q.timestamp);
    card.querySelector('.bc-question').textContent = q.question;

    if (q.isOwnQuestion) {
        card.querySelector('.own-badge').classList.remove('hidden');
    }

    // Wire vote buttons
    const voteContainer = card.querySelector('.bc-vote-buttons');
    voteContainer.dataset.questionId = q.id;

    updateCard(card, q);
    return card;
}

function updateCard(card, q) {
    // Responder count
    const countNum = card.querySelector('.bc-count-num');
    if (countNum) countNum.textContent = q.totalCount;

    // Full banner
    if (q.isFull) card.classList.add('full-card');

    // Vote buttons vs voted message
    const voteButtons = card.querySelector('.bc-vote-buttons');
    const votedMsg = card.querySelector('.bc-voted-msg');

    if (q.isOwnQuestion) {
        voteButtons.classList.add('hidden');
        votedMsg.classList.remove('hidden');
        votedMsg.textContent = '🙏 You asked this — waiting for blessings from the mesh…';
    } else if (q.hasResponded) {
        voteButtons.classList.add('hidden');
        votedMsg.classList.remove('hidden');
        votedMsg.textContent = '✅ Your blessing has been sent.';
    } else if (q.isFull) {
        voteButtons.classList.add('hidden');
        votedMsg.classList.remove('hidden');
        votedMsg.textContent = '🔒 This blessing has received 30 responses.';
    } else {
        voteButtons.classList.remove('hidden');
        votedMsg.classList.add('hidden');
    }

    // Update vote bars
    const total = Math.max(q.totalCount, 1);
    updateBar(card, '.yes-fill', '.yes-count', q.yesCount, total);
    updateBar(card, '.no-fill', '.no-count', q.noCount, total);
    updateBar(card, '.wait-fill', '.wait-count', q.waitCount, total);

    // Responder chips
    renderResponderChips(card, q);
}

function updateBar(card, fillSel, countSel, count, total) {
    const fill = card.querySelector(fillSel);
    const label = card.querySelector(countSel);
    if (fill) fill.style.width = ((count / total) * 100).toFixed(1) + '%';
    if (label) label.textContent = count;
}

function renderResponderChips(card, q) {
    const container = card.querySelector('.bc-responders');
    if (!container) return;

    // Only add new chips (don't re-render all to preserve animations)
    const existingCount = container.querySelectorAll('.responder-chip').length;
    const newVotes = (q.votes || []).slice(existingCount);

    newVotes.forEach(vote => {
        const chip = document.createElement('span');
        chip.className = `responder-chip chip-${vote.response}`;
        chip.textContent = `${vote.emoji} ${vote.voterNickname}`;
        chip.title = `${vote.voterNickname} responded ${vote.response}`;
        container.appendChild(chip);
    });
}

// ─────────────────────────────────────────────
// UI HELPERS
// ─────────────────────────────────────────────

function updateActiveBadge() {
    const badge = document.getElementById('activeBadge');
    if (badge) badge.textContent = questions.size;
}

function updateEmptyState() {
    const empty = document.getElementById('emptyState');
    const list = document.getElementById('blessingsList');
    if (!empty || !list) return;
    if (questions.size > 0) {
        empty.classList.add('hidden');
    } else {
        empty.classList.remove('hidden');
    }
}

function updateCharCounter(textarea) {
    const counter = document.getElementById('charCounter');
    if (counter) counter.textContent = `${textarea.value.length} / 280`;
}

function formatTime(tsMs) {
    const d = new Date(tsMs);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

/** Deterministic gradient from a nickname string */
function nicknameToGradient(name) {
    let hash = 0;
    for (let i = 0; i < (name || '').length; i++) {
        hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
    }
    const hue1 = hash % 360;
    const hue2 = (hue1 + 60) % 360;
    return `linear-gradient(135deg, hsl(${hue1},70%,45%), hsl(${hue2},70%,35%))`;
}

// ─────────────────────────────────────────────
// INTERACTIVE GARDEN
// ─────────────────────────────────────────────

const descriptions = {
    yes: { title: '"Yes" – Proceed', text: 'A "yes" answer means God grants what was asked for because it is the best path for that person\'s life.' },
    no: { title: '"No" – Stop', text: 'A "no" answer is protection from harm. A denied request is a blessing in disguise.' },
    wait: { title: '"Wait" – Patience', text: 'A "wait" answer strengthens you for a greater future blessing. It encourages patience and trust in divine timing.' },
    center: { title: 'The Centre – Banyan Tree', text: 'The great Banyan tree represents the core of the garden—ancient, vast, and deeply rooted.' }
};

function initGarden() {
    // View toggle
    const toggleBtn = document.getElementById('toggleViewBtn');
    const viewText = document.getElementById('viewText');
    const topView = document.getElementById('topView');
    const sideView = document.getElementById('sideView');
    if (!toggleBtn) return;

    let isTopView = true;
    toggleBtn.addEventListener('click', () => {
        isTopView = !isTopView;
        if (isTopView) {
            topView.classList.replace('hidden', 'active');
            sideView.classList.replace('active', 'hidden');
            viewText.textContent = 'Switch to Side View';
        } else {
            sideView.classList.replace('hidden', 'active');
            topView.classList.replace('active', 'hidden');
            viewText.textContent = 'Switch to Top View';
        }
    });

    // Legend filter
    const legendCards = document.querySelectorAll('.legend-card');
    const allTrees = () => [...document.querySelectorAll('.tree, .tree-side')];
    let activeType = null;

    legendCards.forEach(card => {
        card.addEventListener('click', () => {
            const type = card.getAttribute('data-type');
            if (activeType === type) {
                activeType = null;
                legendCards.forEach(c => c.classList.remove('active'));
                allTrees().forEach(t => t.classList.remove('dimmed'));
                hideDesc();
            } else {
                activeType = type;
                legendCards.forEach(c => c.classList.remove('active'));
                card.classList.add('active');
                allTrees().forEach(t => {
                    const match = t.getAttribute('data-type') === type;
                    t.classList.toggle('dimmed', !match);
                });
                showDesc(type);
            }
        });
    });
}

function showDesc(type) {
    const panel = document.getElementById('descriptionPanel');
    const title = document.getElementById('descTitle');
    const text = document.getElementById('descText');
    if (!panel || !descriptions[type]) return;
    title.textContent = descriptions[type].title;
    text.textContent = descriptions[type].text;
    panel.classList.remove('hidden');
}

function hideDesc() {
    const panel = document.getElementById('descriptionPanel');
    if (panel) panel.classList.add('hidden');
}

// ─────────────────────────────────────────────
// SHAKE ANIMATION (inline, no extra CSS needed)
// ─────────────────────────────────────────────

(function injectShakeStyle() {
    const style = document.createElement('style');
    style.textContent = `
        @keyframes shake {
            0%,100% { transform: translateX(0); }
            20%      { transform: translateX(-6px); }
            40%      { transform: translateX(6px); }
            60%      { transform: translateX(-4px); }
            80%      { transform: translateX(4px); }
        }
        .shake { animation: shake 0.35s ease; border-color: #ff6b6b !important; }
    `;
    document.head.appendChild(style);
})();

// ─────────────────────────────────────────────
// INIT
// ─────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
    // Character counter
    const textarea = document.getElementById('questionInput');
    if (textarea) {
        textarea.addEventListener('input', () => updateCharCounter(textarea));

        // Allow Cmd/Ctrl+Enter to submit
        textarea.addEventListener('keydown', e => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
                askBlessing();
            }
        });
    }

    // Send Enter key hint (↩ Cmd+Enter)
    initGarden();

    // Tell Swift the page is ready so it can inject nickname + existing questions
    postToSwift('blessingReady', {});
});