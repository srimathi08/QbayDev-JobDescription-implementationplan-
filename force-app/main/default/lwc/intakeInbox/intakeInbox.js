import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getInbox from '@salesforce/apex/IntakeController.getInbox';

const ORDER = ['Needs Review', 'Duplicate', 'Failed', 'Queued', 'New', 'Rejected', 'Completed'];

/** All intakes (Upload, Email, WhatsApp) with filters; Qbay Home uploads can be fixed, attached or retried here. */
export default class IntakeInbox extends LightningElement {
    status = 'Action needed';
    channel = 'UI Upload';
    days = '7';
    mineOnly = false;
    rows = [];
    loading = false;

    statusOptions = [
        { label: 'Needs my action', value: 'Action needed' },
        { label: 'All statuses', value: 'All' },
        { label: 'Needs Review', value: 'Needs Review' },
        { label: 'Duplicate', value: 'Duplicate' },
        { label: 'Failed', value: 'Failed' },
        { label: 'Rejected', value: 'Rejected' },
        { label: 'Completed', value: 'Completed' },
        { label: 'Queued', value: 'Queued' }
    ];
    channelOptions = [
        { label: 'Qbay Home upload', value: 'UI Upload' },
        { label: 'All channels', value: 'All' },
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

    get hasRows() {
        return this.rows.length > 0;
    }
    get atLimit() {
        return this.rows.length >= 200;
    }
    get counts() {
        const by = {};
        this.rows.forEach((r) => {
            by[r.status] = (by[r.status] || 0) + 1;
        });
        return ORDER.filter((s) => by[s]).map((s) => ({
            label: s,
            count: by[s],
            cls: s === 'Needs Review' || s === 'Failed' ? 'needs' : ''
        }));
    }

    @api
    async refresh() {
        this.loading = true;
        try {
            this.rows = await getInbox({
                channel: this.channel,
                status: this.status,
                days: parseInt(this.days, 10),
                mineOnly: this.mineOnly
            });
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not load the inbox', message: this.errorText(e), variant: 'error' })
            );
        } finally {
            this.loading = false;
        }
    }

    handleStatus(e) {
        this.status = e.detail.value;
        this.refresh();
    }
    handleChannel(e) {
        this.channel = e.detail.value;
        this.refresh();
    }
    handleDays(e) {
        this.days = e.detail.value;
        this.refresh();
    }
    handleMine(e) {
        this.mineOnly = e.target.checked;
        this.refresh();
    }

    handleRowChange(event) {
        const updated = event.detail;
        this.rows = this.rows.map((r) => (r.serviceId === updated.serviceId ? updated : r));
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
