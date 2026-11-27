import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUploadSettings from '@salesforce/apex/IntakeController.getUploadSettings';
import submitUploadedFilesWithClient from '@salesforce/apex/IntakeController.submitUploadedFilesWithClient';
import getUploadedFileDetails from '@salesforce/apex/IntakeController.getUploadedFileDetails';
import removeUploadedFile from '@salesforce/apex/IntakeController.removeUploadedFile';
import getStatus from '@salesforce/apex/IntakeController.getStatus';
import getMyUploadsToday from '@salesforce/apex/IntakeController.getMyUploadsToday';

const POLL_MS = 5000;
const POLL_LIMIT_MS = 20 * 60 * 1000;
const FINAL = ['Completed', 'Duplicate', 'Rejected', 'Failed', 'Needs Review'];
const HINTS = {
    Auto: 'Auto-detect: the AI decides whether each file is a resume or a job description. You can mix both in one upload.',
    Resume: 'Every file is treated as a resume. A job description uploaded here is rejected.',
    'Job Description': 'Every file is treated as a job description. A resume uploaded here is rejected.'
};

function formatSize(bytes) {
    if (bytes === null || bytes === undefined) {
        return '';
    }
    if (bytes < 1024) {
        return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
        return `${Math.round(bytes / 1024)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function newKey() {
    try {
        if (window.crypto && window.crypto.randomUUID) {
            return window.crypto.randomUUID();
        }
    } catch (e) {
        // fall through
    }
    return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12);
}

/**
 * Qbay Home uploader. Files go through the standard file upload (no 3 MB limit), then one intake
 * record per file is created and the files are read one after another.
 * requested-type: 'Auto' | 'Resume' | 'Job Description'; show-type-switch lets the recruiter choose.
 */
export default class IntakeUploader extends LightningElement {
    @api requestedType = 'Resume';
    @api showTypeSwitch = false;
    @api showTodayButton = false;
    @api cardTitle = 'Upload';
    @api iconName = 'custom:custom14';
    @api fileLabel = 'Upload files';

    selectedType;
    maxFiles = 10;
    maxFileMb = 10;
    userId;
    ready = false;
    results = [];
    staged = []; // review step: uploaded, not processed yet
    isSubmitting = false;
    busyText = '';
    acceptedFormats = ['.pdf', '.docx'];
    hiddenResults = []; // "Hide" only moves results here; "Show hidden" brings them back

    showModal = false;
    todayLoading = false;
    todayRows = [];

    pollTimer;
    pollStarted;

    typeOptions = [
        { label: 'Auto-detect', value: 'Auto' },
        { label: 'Resume', value: 'Resume' },
        { label: 'Job Description', value: 'Job Description' }
    ];

    connectedCallback() {
        this.selectedType = this.requestedType || 'Resume';
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    @wire(getUploadSettings)
    wiredSettings({ data, error }) {
        if (data) {
            this.maxFiles = data.maxFiles;
            this.maxFileMb = data.maxFileMb;
            this.userId = data.userId;
            this.ready = true;
        } else if (error) {
            this.toast('Error', 'Could not load the upload settings: ' + this.errorText(error), 'error');
        }
    }

    // ---------------- getters ----------------

    get typeHint() {
        return HINTS[this.selectedType];
    }
    get hasResults() {
        return this.results.length > 0;
    }
    get hasToday() {
        return this.todayRows.length > 0;
    }
    get progressSummary() {
        const total = this.results.length;
        const done = this.results.filter((r) => r.isFinal).length;
        const where = this.showTodayButton ? '' : ' Results also stay in the Intake inbox below.';
        return (done === total ? `${total} of ${total} finished.` : `${done} of ${total} finished, reading one at a time.`) + where;
    }

    /** Type choice as a segmented control (shared theme). */
    get typeButtons() {
        return this.typeOptions.map((o) => ({
            ...o,
            cls: 'qb-segment-btn' + (o.value === this.selectedType ? ' is-active' : '')
        }));
    }
    handleTypeClick(event) {
        this.selectedType = event.currentTarget.dataset.value;
    }
    get hasHidden() {
        return this.hiddenResults.length > 0;
    }
    get showResultsStep() {
        return this.hasResults || this.hasHidden;
    }
    get hiddenLabel() {
        return `Show ${this.hiddenResults.length} hidden `
            + (this.hiddenResults.length === 1 ? 'result' : 'results');
    }
    showHidden() {
        this.results = [...this.results, ...this.hiddenResults];
        this.hiddenResults = [];
        if (this.results.some((r) => !r.isFinal)) {
            this.startPolling();
        }
    }

    // ---------------- vertical steps ----------------

    get stepTypeClass() {
        return 'step step-done';
    }
    get stepFilesClass() {
        return this.hasStaged || this.hasResults ? 'step step-done' : 'step step-active';
    }
    get stepReviewClass() {
        return this.hasStaged ? 'step step-active' : 'step';
    }
    get stepResultsClass() {
        return this.hasResults ? 'step step-active' : 'step';
    }
    get typeLabel() {
        const o = this.typeOptions.find((x) => x.value === this.selectedType);
        return o ? o.label : this.selectedType;
    }

    get isBusy() {
        return this.isSubmitting;
    }
    get hasStaged() {
        return this.staged.length > 0;
    }
    get stagedCount() {
        return this.staged.length;
    }
    /** Staged files with display values; files after the first maxFiles good ones are marked over the limit. */
    get stagedView() {
        let ok = 0;
        return this.staged.map((f) => {
            let problem = f.problem;
            if (!problem) {
                ok++;
                if (ok > this.maxFiles) {
                    problem = `Over the ${this.maxFiles}-file limit`;
                }
            }
            const ext = (f.extension || '').toLowerCase();
            return {
                ...f,
                icon: ext === 'pdf' ? 'doctype:pdf' : ext === 'docx' || ext === 'doc' ? 'doctype:word' : 'doctype:unknown',
                extLabel: ext ? ext.toUpperCase() : 'Unknown type',
                sizeLabel: formatSize(f.sizeBytes),
                checkLabel: problem || 'Ready',
                badgeClass: problem ? 'check-bad' : 'check-ok',
                willProcess: !problem
            };
        });
    }
    get readyCount() {
        return this.stagedView.filter((f) => f.willProcess).length;
    }
    get startLabel() {
        const n = this.readyCount;
        return `Start processing (${n} ${n === 1 ? 'file' : 'files'})`;
    }
    get startDisabled() {
        return this.isBusy || this.readyCount === 0;
    }

    handleTypeChange(event) {
        this.selectedType = event.detail.value;
    }

    // ---------------- upload + review step ----------------

    /** Files are stored by the standard upload; they wait in the review list until "Start processing". */
    async handleUploadFinished(event) {
        const files = event.detail.files || [];
        if (files.length === 0) {
            return;
        }
        this.setBusy('Reading file details...');
        try {
            const details = await getUploadedFileDetails({ contentDocumentIds: files.map((f) => f.documentId) });
            const known = new Set(this.staged.map((f) => f.documentId));
            const added = details.filter((d) => !known.has(d.documentId)).map((d) => ({ ...d, type: this.selectedType }));
            const single = this.staged.length === 0 && added.length === 1;
            this.staged = [...this.staged, ...added];
            if (single) {
                // One file: no review step, it is processed straight away (all checks still run on the server)
                this.setBusy(null);
                await this.handleStartProcessing();
                return;
            }
            this.toast('Files added', `${added.length} file(s) added. Check the list, then click Start processing.`, 'info');
            // Same file already waiting in Needs Review or being read: say so now, before any processing
            const pending = added.filter((d) => d.pendingMessage);
            if (pending.length) {
                this.toast(
                    'Already uploaded',
                    pending.map((d) => `${d.fileName}: ${d.pendingMessage}`).join(' '),
                    'warning'
                );
            }
        } catch (e) {
            this.toast('Upload failed', this.errorText(e), 'error');
        } finally {
            this.setBusy(null);
        }
    }

    async handleRemoveFile(event) {
        const id = event.currentTarget.dataset.id;
        this.setBusy('Removing file...');
        try {
            await removeUploadedFile({ contentDocumentId: id });
            this.staged = this.staged.filter((f) => f.documentId !== id);
        } catch (e) {
            this.toast('Could not remove the file', this.errorText(e), 'error');
        } finally {
            this.setBusy(null);
        }
    }

    async handleRemoveAll() {
        this.setBusy('Removing files...');
        const failed = [];
        for (const f of [...this.staged]) {
            try {
                // eslint-disable-next-line no-await-in-loop
                await removeUploadedFile({ contentDocumentId: f.documentId });
                this.staged = this.staged.filter((s) => s.documentId !== f.documentId);
            } catch (e) {
                failed.push(f.fileName);
            }
        }
        this.setBusy(null);
        if (failed.length) {
            this.toast('Some files were not removed', failed.join(', '), 'error');
        }
    }

    async handleStartProcessing() {
        const files = this.staged;
        if (files.length === 0) {
            return;
        }
        this.setBusy('Creating upload records...');
        try {
            const rows = await submitUploadedFilesWithClient({
                contentDocumentIds: files.map((f) => f.documentId),
                requestedTypes: files.map(() => this.selectedType),
                batchKey: newKey(),
                clientName: null
            });
            this.staged = [];
            this.results = [...rows, ...this.results];
            const queued = rows.filter((r) => !r.isFinal).length;
            const refused = rows.length - queued;
            if (queued > 0) {
                this.toast(
                    'Uploaded',
                    `${queued} file(s) are being read one after another.` + (refused ? ` ${refused} file(s) were not accepted; see below.` : ''),
                    'success'
                );
                this.startPolling();
            } else {
                this.toast('Not accepted', 'None of the files could be accepted. See the reasons below.', 'warning');
            }
            this.dispatchEvent(new CustomEvent('uploaded'));
        } catch (e) {
            this.toast('Upload failed', this.errorText(e), 'error');
        } finally {
            this.setBusy(null);
        }
    }

    setBusy(text) {
        this.isSubmitting = !!text;
        this.busyText = text || '';
    }

    /** Hides the results list only; nothing is deleted (results stay in the Intake inbox). */
    clearResults() {
        this.hiddenResults = [...this.hiddenResults, ...this.results];
        this.results = [];
    }

    handleHideResult(event) {
        const id = event.currentTarget.dataset.id;
        this.hiddenResults = [...this.hiddenResults, ...this.results.filter((r) => r.serviceId === id)];
        this.results = this.results.filter((r) => r.serviceId !== id);
    }

    handleRowChange(event) {
        const updated = event.detail;
        this.results = this.results.map((r) => (r.serviceId === updated.serviceId ? updated : r));
        if (!updated.isFinal) {
            this.startPolling();
        }
        this.dispatchEvent(new CustomEvent('uploaded'));
    }

    // ---------------- status polling ----------------

    startPolling() {
        this.stopPolling();
        this.pollStarted = Date.now();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(() => this.refreshStatus(), POLL_MS);
    }

    stopPolling() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = null;
        }
    }

    async refreshStatus() {
        const pending = this.results.filter((r) => !r.isFinal).map((r) => r.serviceId);
        if (pending.length === 0) {
            this.stopPolling();
            return;
        }
        if (Date.now() - this.pollStarted > POLL_LIMIT_MS) {
            this.stopPolling();
            return;
        }
        try {
            const statuses = await getStatus({ serviceIds: pending });
            const byId = new Map(statuses.map((s) => [s.serviceId, s]));
            const finishedNow = [];
            this.results = this.results.map((r) => {
                const s = byId.get(r.serviceId);
                if (!s) {
                    return r;
                }
                if (FINAL.includes(s.status) && !r.isFinal) {
                    finishedNow.push(s);
                }
                return s;
            });
            finishedNow.forEach((r) => {
                const variant =
                    r.status === 'Completed' ? 'success' : r.status === 'Duplicate' || r.status === 'Needs Review' ? 'warning' : 'error';
                this.toast(`${r.fileName}: ${r.status}`, r.message || '', variant);
            });
            if (finishedNow.length > 0) {
                this.dispatchEvent(new CustomEvent('uploaded'));
            }
        } catch (e) {
            // keep polling; a single failed refresh is not fatal
        }
    }

    // ---------------- today modal ----------------

    async openTodayModal() {
        this.showModal = true;
        this.todayLoading = true;
        try {
            this.todayRows = await getMyUploadsToday({ requestedType: this.requestedType });
        } catch (e) {
            this.toast('Error', "Could not load today's uploads: " + this.errorText(e), 'error');
        } finally {
            this.todayLoading = false;
        }
    }

    handleTodayChange(event) {
        const updated = event.detail;
        this.todayRows = this.todayRows.map((r) => (r.serviceId === updated.serviceId ? updated : r));
    }

    closeModal() {
        this.showModal = false;
    }

    // ---------------- utils ----------------

    errorText(e) {
        if (!e) {
            return 'Unknown error';
        }
        if (e.body) {
            if (Array.isArray(e.body)) {
                return e.body.map((b) => b.message).join(', ');
            }
            if (e.body.message) {
                return e.body.message;
            }
        }
        return e.message || 'Unknown error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
