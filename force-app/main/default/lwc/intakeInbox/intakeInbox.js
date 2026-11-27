import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getInbox from '@salesforce/apex/IntakeController.getInbox';

const PAGE_SIZE = 5;
const ACTION_STATUSES = ['Needs Review', 'Duplicate', 'Failed'];

/** Status views shown on the left, each with its count. */
const VIEWS = [
    { name: 'action', label: 'Needs my action', test: (r) => ACTION_STATUSES.includes(r.status) || r.isStuck === true },
    { name: 'review', label: 'Needs Review', test: (r) => r.status === 'Needs Review' },
    { name: 'duplicate', label: 'Duplicate', test: (r) => r.status === 'Duplicate' },
    { name: 'failed', label: 'Failed', test: (r) => r.status === 'Failed' },
    { name: 'running', label: 'Being processed', test: (r) => r.status === 'New' || r.status === 'Queued' },
    { name: 'rejected', label: 'Rejected', test: (r) => r.status === 'Rejected' },
    { name: 'completed', label: 'Completed', test: (r) => r.status === 'Completed' },
    { name: 'all', label: 'All', test: () => true }
];

/**
 * All intakes (Upload, Email, WhatsApp). Vertical layout (26-11-2026): status views on the left with counts,
 * the list on the right, 5 per page. One server call per filter change (channel, period, only mine);
 * the status views and paging are done in the browser, so switching them is instant.
 */
export default class IntakeInbox extends LightningElement {
    // 27-11-2026: defaults are All statuses and All channels
    view = 'all';
    channel = 'All';
    days = '7';
    mineOnly = false;
    rows = [];
    loading = false;
    page = 1;

    channelOptions = [
        { label: 'All channels', value: 'All' },
        { label: 'Qbay Home upload', value: 'UI Upload' },
        { label: 'Email', value: 'Email' },
        { label: 'WhatsApp', value: 'WhatsApp' }
    ];
    dayOptions = [
        { label: 'Today', value: '1' },
        { label: 'Last 7 days', value: '7' },
        { label: 'Last 30 days', value: '30' }
    ];

    connectedCallback() {
        this.refresh();
    }

    // ---------------- views (left navigation) ----------------


    get views() {
        return VIEWS.map((v) => ({
            name: v.name,
            label: v.label,
            count: this.rows.filter(v.test).length,
            cls: 'nav-item' + (v.name === this.view ? ' is-active' : '') + (v.name === 'action' ? ' nav-action' : '')
        }));
    }

    get currentView() {
        return VIEWS.find((v) => v.name === this.view) || VIEWS[0];
    }
    get viewLabel() {
        return this.currentView.label;
    }
    get filteredRows() {
        return this.rows.filter(this.currentView.test);
    }

    // ---------------- paging ----------------

    get totalCount() {
        return this.filteredRows.length;
    }
    get pageCount() {
        return Math.max(1, Math.ceil(this.totalCount / PAGE_SIZE));
    }
    get pageRows() {
        const start = (this.page - 1) * PAGE_SIZE;
        return this.filteredRows.slice(start, start + PAGE_SIZE);
    }
    get hasRows() {
        return this.totalCount > 0;
    }
    get showPager() {
        return this.totalCount > PAGE_SIZE;
    }
    get rangeText() {
        if (!this.hasRows) {
            return '';
        }
        const from = (this.page - 1) * PAGE_SIZE + 1;
        const to = Math.min(this.page * PAGE_SIZE, this.totalCount);
        return `${from}-${to} of ${this.totalCount}`;
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
    get atLimit() {
        return this.rows.length >= 200;
    }
    get emptyText() {
        if (this.channel === 'WhatsApp' && this.mineOnly) {
            return 'Nothing here. With "Only mine" on, WhatsApp shows only messages sent from the phone number on your User record.';
        }
        return 'Nothing here for these filters.';
    }

    handlePrev() {
        if (this.page > 1) {
            this.page -= 1;
        }
    }
    handleNext() {
        if (this.page < this.pageCount) {
            this.page += 1;
        }
    }

    // ---------------- filters ----------------

    @api
    async refresh() {
        this.loading = true;
        try {
            this.rows = await getInbox({
                channel: this.channel,
                status: 'All',
                days: parseInt(this.days, 10),
                mineOnly: this.mineOnly
            });
            if (this.page > this.pageCount) {
                this.page = this.pageCount;
            }
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not load the inbox', message: this.errorText(e), variant: 'error' })
            );
        } finally {
            this.loading = false;
        }
    }

    handleView(e) {
        this.view = e.currentTarget.dataset.name;
        this.page = 1;
    }
    handleChannel(e) {
        this.channel = e.detail.value;
        this.page = 1;
        this.refresh();
    }
    handleDays(e) {
        this.days = e.detail.value;
        this.page = 1;
        this.refresh();
    }
    handleMine(e) {
        this.mineOnly = e.target.checked;
        this.page = 1;
        this.refresh();
    }

    handleRowChange(event) {
        const updated = event.detail;
        this.rows = this.rows.map((r) => (r.serviceId === updated.serviceId ? updated : r));
        if (this.page > this.pageCount) {
            this.page = this.pageCount;
        }
    }

    errorText(e) {
        if (e && e.body) {
            if (Array.isArray(e.body)) {
                return e.body.map((b) => b.message).join(', ');
            }
            if (e.body.message) {
                return e.body.message;
            }
        }
        return (e && e.message) || 'Unknown error';
    }
}