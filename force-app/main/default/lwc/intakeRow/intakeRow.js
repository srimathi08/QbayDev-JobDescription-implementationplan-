import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import completeReview from '@salesforce/apex/IntakeController.completeReview';
import attachToExisting from '@salesforce/apex/IntakeController.attachToExisting';
import retryIntake from '@salesforce/apex/IntakeController.retryIntake';
import resolveJdDuplicate from '@salesforce/apex/IntakeController.resolveJdDuplicate';

const LOOK = {
    Completed: 'success',
    Duplicate: 'warning',
    'Needs Review': 'review',
    Rejected: 'error',
    Failed: 'error'
};

/** One intake (one file) with its result, links and the actions the recruiter can take. */
export default class IntakeRow extends LightningElement {
    @api row;
    @api showMeta = false;

    showForm = false;
    busy = false;
    email = '';
    phone = '';
    linkedIn = '';

    get look() {
        return LOOK[this.row.status] || 'info';
    }
    get boxClass() {
        return `row row-${this.look}`;
    }
    get badgeClass() {
        return `badge badge-${this.look}`;
    }
    get isRunning() {
        return !this.row.isFinal;
    }
    get waitingText() {
        if (this.row.status !== 'Queued') {
            return 'Reading';
        }
        // Files of one upload are read one after another
        if (this.row.batchTotal > 1 && this.row.batchPosition) {
            return `Waiting, file ${this.row.batchPosition} of ${this.row.batchTotal}`;
        }
        return 'Waiting to be read';
    }
    get fileIcon() {
        const n = (this.row.fileName || '').toLowerCase();
        return n.endsWith('.docx') ? 'doctype:word' : 'doctype:pdf';
    }
    get metaText() {
        if (!this.showMeta) {
            return '';
        }
        const parts = [];
        if (this.row.channel) {
            parts.push(this.row.channel === 'UI Upload' ? 'Upload' : this.row.channel);
        }
        if (this.row.createdByName) {
            parts.push(this.row.createdByName);
        }
        if (this.row.createdDate) {
            parts.push(
                new Date(this.row.createdDate).toLocaleString(undefined, {
                    day: '2-digit',
                    month: 'short',
                    hour: '2-digit',
                    minute: '2-digit'
                })
            );
        }
        return parts.join(' · ');
    }
    get isResume() {
        return this.row.requestedType !== 'Job Description';
    }
    get accountUrl() {
        return this.row.accountId ? `/${this.row.accountId}` : null;
    }
    get accountLabel() {
        return `${this.isResume ? 'Candidate' : 'Client'}: ${this.row.accountName}`;
    }
    get opportunityUrl() {
        return this.row.opportunityId ? `/${this.row.opportunityId}` : null;
    }
    get jobDescriptionUrl() {
        return this.row.jobDescriptionId ? `/${this.row.jobDescriptionId}` : null;
    }
    get hasActions() {
        return this.row.canReview || this.row.canAttach || this.row.canRetry || this.row.canChooseJd;
    }
    get reviewLabel() {
        return this.row.status === 'Duplicate' ? 'Different person? Add contact details' : 'Add contact details';
    }
    get reviewVariant() {
        return this.row.status === 'Needs Review' ? 'brand' : 'neutral';
    }

    toggleForm() {
        this.showForm = !this.showForm;
    }
    handleEmail(e) {
        this.email = e.target.value;
    }
    handlePhone(e) {
        this.phone = e.target.value;
    }
    handleLinkedIn(e) {
        this.linkedIn = e.target.value;
    }

    async handleContinue() {
        if (!this.email && !this.phone && !this.linkedIn) {
            this.toast('Contact details needed', 'Please enter an email, a phone number or a LinkedIn profile.', 'warning');
            return;
        }
        await this.run(
            () =>
                completeReview({
                    serviceId: this.row.serviceId,
                    email: this.email,
                    phone: this.phone,
                    linkedIn: this.linkedIn
                }),
            true
        );
    }

    async handleAttach() {
        await this.run(() => attachToExisting({ serviceId: this.row.serviceId }), false);
    }

    async handleUseExistingOpp() {
        await this.run(() => resolveJdDuplicate({ serviceId: this.row.serviceId, useExisting: true }), false);
    }

    async handleCreateNewOpp() {
        await this.run(() => resolveJdDuplicate({ serviceId: this.row.serviceId, useExisting: false }), false);
    }

    async handleRetry() {
        await this.run(() => retryIntake({ serviceId: this.row.serviceId }), false);
    }

    async run(call, closeForm) {
        this.busy = true;
        try {
            const updated = await call();
            if (closeForm) {
                this.showForm = false;
            }
            const variant = updated.status === 'Completed' ? 'success' : updated.status === 'Duplicate' ? 'warning' : 'info';
            this.toast(`${updated.fileName}: ${updated.status}`, updated.message || '', variant);
            this.dispatchEvent(new CustomEvent('rowchange', { detail: updated, bubbles: true, composed: true }));
        } catch (e) {
            this.toast('Could not complete', this.errorText(e), 'error');
        } finally {
            this.busy = false;
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

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
