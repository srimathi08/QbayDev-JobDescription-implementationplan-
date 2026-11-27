import { LightningElement, api } from 'lwc';
import getMatches from '@salesforce/apex/JobMatchController.getMatches';
import rescore from '@salesforce/apex/JobMatchController.rescore';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const PAGE_SIZE = 10;
const FILTERS = [
    { label: 'Good fit (50+)', value: 50 },
    { label: 'Strong (70+)', value: 70 },
    { label: 'All', value: 0 }
];

/**
 * Job matches on the Opportunity (rebuilt 27-11-2026).
 * Scores are 0-100: quick fit for everyone, AI fit for the top 10. Sorted by score, default filter 50+.
 */
export default class OpportunityMatches extends LightningElement {
    @api recordId;
    rows = [];
    jobDescription;
    waiting = 0;
    lastScored;
    running = false;
    minScore = 50;
    page = 1;
    isLoading = true;
    rescoring = false;
    errorMessage = '';
    expandedId;
    pollTimer;
    polls = 0;

    // schedule interview modal
    showModal = false;
    selectedCandidateId;
    selectedCandidateName;

    connectedCallback() {
        this.load();
    }
    disconnectedCallback() {
        this.stopPolling();
    }

    async load() {
        this.errorMessage = '';
        try {
            const res = await getMatches({ opportunityId: this.recordId });
            this.rows = res.rows || [];
            this.jobDescription = res.jobDescription;
            this.waiting = res.waiting || 0;
            this.lastScored = res.lastScored;
            this.running = res.running;
            if (!this.running && !this.waiting) {
                this.stopPolling();
            }
        } catch (e) {
            this.errorMessage = this.errorText(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ---------------- view state ----------------

    get filterButtons() {
        return FILTERS.map((f) => ({
            ...f,
            key: String(f.value),
            text: `${f.label} · ${this.countAtLeast(f.value)}`,
            cls: 'qb-segment-btn' + (this.minScore === f.value ? ' is-active' : '')
        }));
    }
    countAtLeast(min) {
        return this.rows.filter((r) => (r.score || 0) >= min).length;
    }
    get filtered() {
        return this.rows.filter((r) => (r.score || 0) >= this.minScore);
    }
    get hasRows() {
        return this.filtered.length > 0;
    }
    get noRows() {
        return !this.isLoading && !this.errorMessage && this.filtered.length === 0;
    }
    get emptyText() {
        if (this.rows.length === 0) {
            return this.running ? 'Matching is running. Scores appear here in a minute.' : 'No matches yet. Press Re-score to match every candidate to this job.';
        }
        return 'No candidates at this score. Choose "All" to see everyone.';
    }
    get statusText() {
        const parts = [];
        if (this.running || this.waiting) {
            parts.push(this.waiting ? `AI is checking ${this.waiting} top candidate${this.waiting === 1 ? '' : 's'}...` : 'Matching is running...');
        }
        if (this.lastScored) {
            parts.push('Last scored ' + new Date(this.lastScored).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }));
        }
        return parts.join(' · ');
    }
    get busy() {
        return this.rescoring || this.running;
    }
    get pageCount() {
        return Math.max(1, Math.ceil(this.filtered.length / PAGE_SIZE));
    }
    get showPager() {
        return this.filtered.length > PAGE_SIZE;
    }
    get pageText() {
        return `Page ${this.page} of ${this.pageCount}`;
    }
    get prevDisabled() {
        return this.page <= 1;
    }
    get nextDisabled() {
        return this.page >= this.pageCount;
    }
    get pageRows() {
        const start = (this.page - 1) * PAGE_SIZE;
        return this.filtered.slice(start, start + PAGE_SIZE).map((r, i) => {
            const score = Math.round(r.score || 0);
            const tone = score >= 70 ? 'good' : score >= 50 ? 'ok' : 'low';
            return {
                ...r,
                rank: start + i + 1,
                scoreText: String(score),
                ringClass: 'ring ring-' + tone,
                barStyle: `width:${Math.min(100, score)}%`,
                barClass: 'bar bar-' + tone,
                url: `/lightning/r/Account/${r.candidateId}/view`,
                meta: [r.designation, r.experience, r.location].filter((x) => x).join(' · '),
                sourceText: r.aiFit !== null && r.aiFit !== undefined ? 'AI fit' : 'Quick fit',
                sourceClass: r.aiFit !== null && r.aiFit !== undefined ? 'qb-pill qb-pill-info' : 'qb-pill',
                isWaiting: r.status === 'Waiting for AI',
                isError: r.status === 'Error',
                matchedList: this.list(r.matched, 8),
                missingList: this.list(r.missing, 6),
                hasMatched: !!r.matched,
                hasMissing: !!r.missing,
                expanded: this.expandedId === r.id,
                toggleText: this.expandedId === r.id ? 'Less' : 'Why this score'
            };
        });
    }
    list(text, n) {
        if (!text) {
            return [];
        }
        return text
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s)
            .slice(0, n);
    }

    // ---------------- actions ----------------

    handleFilter(event) {
        this.minScore = Number(event.currentTarget.dataset.value);
        this.page = 1;
    }
    handlePrev() {
        if (this.page > 1) this.page -= 1;
    }
    handleNext() {
        if (this.page < this.pageCount) this.page += 1;
    }
    handleToggle(event) {
        const id = event.currentTarget.dataset.id;
        this.expandedId = this.expandedId === id ? undefined : id;
    }
    handleRefresh() {
        this.load();
    }
    async handleRescore() {
        this.rescoring = true;
        try {
            await rescore({ opportunityId: this.recordId });
            this.running = true;
            this.toast('Re-scoring started', 'Every candidate is scored again. AI checks only the top 10 that changed.', 'success');
            this.startPolling();
        } catch (e) {
            this.toast('Could not re-score', this.errorText(e), 'error');
        } finally {
            this.rescoring = false;
        }
    }
    startPolling() {
        this.stopPolling();
        this.polls = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(() => {
            this.polls += 1;
            if (this.polls > 20) {
                this.stopPolling();
                return;
            }
            this.load();
        }, 6000);
    }
    stopPolling() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = undefined;
        }
    }

    // ---------------- schedule interview ----------------

    handleScheduleClick(event) {
        this.selectedCandidateId = event.currentTarget.dataset.id;
        this.selectedCandidateName = event.currentTarget.dataset.name;
        this.showModal = true;
    }
    handleCloseModal() {
        this.showModal = false;
    }
    handleSave() {
        const form = this.template.querySelector('lightning-record-edit-form');
        if (form) {
            form.submit();
        }
    }
    handleSuccess() {
        this.toast('Interview scheduled', `Interview saved for ${this.selectedCandidateName}.`, 'success');
        this.showModal = false;
    }
    handleError(event) {
        this.toast('Could not save the interview', event.detail && event.detail.message, 'error');
    }

    // ---------------- utils ----------------

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errorText(e) {
        if (e && e.body) {
            if (Array.isArray(e.body)) return e.body.map((b) => b.message).join(', ');
            if (e.body.message) return e.body.message;
        }
        return (e && e.message) || 'Something went wrong. Please try again.';
    }
}