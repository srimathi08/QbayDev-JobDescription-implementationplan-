import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import submitFile from '@salesforce/apex/IntakeController.submitFile';
import getStatus from '@salesforce/apex/IntakeController.getStatus';
import getMyUploadsToday from '@salesforce/apex/IntakeController.getMyUploadsToday';

const MAX_BYTES = 3 * 1024 * 1024;
const MAX_FILES = 10;
const ALLOWED = ['pdf', 'docx'];
const POLL_MS = 4000;
const POLL_LIMIT_MS = 5 * 60 * 1000;
const FINAL = ['Completed', 'Duplicate', 'Rejected', 'Failed'];

const BADGE = {
    Completed: 'badge-success',
    Duplicate: 'badge-warning',
    Rejected: 'badge-error',
    Failed: 'badge-error'
};

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

function extensionOf(name) {
    const i = name.lastIndexOf('.');
    return i < 0 ? '' : name.slice(i + 1).toLowerCase();
}

export default class IntakeUploader extends LightningElement {
    @api requestedType = 'Resume'; // 'Resume' | 'Job Description'
    @api cardTitle = 'Upload';
    @api iconName = 'custom:custom14';
    @api fileLabel = 'Attachment';

    maxFiles = MAX_FILES;
    selectedFiles = [];
    results = [];
    isSubmitting = false;
    progressText = '';
    showInput = true;

    showModal = false;
    todayLoading = false;
    todayRows = [];
    todayColumns = [
        { label: 'File', fieldName: 'fileName', type: 'text' },
        { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 110 },
        {
            label: 'Created record',
            fieldName: 'recordUrl',
            type: 'url',
            typeAttributes: { label: { fieldName: 'recordName' }, target: '_blank' }
        },
        { label: 'Details', fieldName: 'message', type: 'text', wrapText: true },
        {
            label: 'Uploaded',
            fieldName: 'createdDate',
            type: 'date',
            initialWidth: 150,
            typeAttributes: { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }
        }
    ];

    pollTimer;
    pollStarted;

    // ---------------- getters ----------------

    get hasSelected() {
        return this.selectedFiles.length > 0;
    }
    get validFiles() {
        return this.selectedFiles.filter((f) => !f.error);
    }
    get isSubmitDisabled() {
        return this.isSubmitting || this.validFiles.length === 0;
    }
    get submitLabel() {
        return this.isSubmitting ? 'Submitting...' : 'Submit';
    }
    get hasResults() {
        return this.results.length > 0;
    }
    get hasToday() {
        return this.todayRows.length > 0;
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // ---------------- file selection ----------------

    handleFilesSelected(event) {
        const files = [...(event.target.files || [])];
        let count = 0;
        this.selectedFiles = files.map((file, i) => {
            let error = null;
            const ext = extensionOf(file.name);
            if (!ALLOWED.includes(ext)) {
                error = 'Not supported. Use PDF or DOCX.';
            } else if (file.size === 0) {
                error = 'The file is empty.';
            } else if (file.size > MAX_BYTES) {
                error = 'Larger than 3 MB.';
            } else if (count >= MAX_FILES) {
                error = `Only ${MAX_FILES} files per upload.`;
            } else {
                count++;
            }
            return {
                key: `${i}-${file.name}`,
                name: file.name,
                file,
                error,
                icon: error ? 'utility:error' : 'doctype:attachment'
            };
        });
    }

    readAsBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result).split(',')[1]);
            reader.onerror = () => reject(reader.error);
            reader.readAsDataURL(file);
        });
    }

    // ---------------- submit ----------------

    async handleSubmit() {
        // Lock first, synchronously, so a second click cannot start a second run
        if (this.isSubmitting) {
            return;
        }
        const files = this.validFiles;
        if (files.length === 0) {
            this.toast('Error', 'Please choose at least one PDF or DOCX file.', 'error');
            return;
        }
        this.isSubmitting = true;
        const batchKey = newKey();
        const newRows = [];

        try {
            for (let i = 0; i < files.length; i++) {
                const f = files[i];
                this.progressText = `${i + 1} of ${files.length}`;
                try {
                    const base64 = await this.readAsBase64(f.file);
                    const st = await submitFile({
                        requestKey: `${batchKey}-${i}`,
                        requestedType: this.requestedType,
                        fileName: f.name,
                        base64
                    });
                    newRows.push(this.toRow(st));
                } catch (e) {
                    newRows.push(
                        this.toRow({
                            serviceId: null,
                            fileName: f.name,
                            status: 'Failed',
                            message: this.errorText(e),
                            isFinal: true
                        })
                    );
                }
            }
        } finally {
            this.results = [...newRows, ...this.results];
            this.clearSelection();
            this.isSubmitting = false;
            this.progressText = '';
        }

        const queued = newRows.filter((r) => !r.isFinal).length;
        if (queued > 0) {
            this.toast('Uploaded', `${queued} file(s) uploaded. Processing has started; results will appear below.`, 'success');
            this.startPolling();
        } else {
            this.toast('Upload finished', 'See the results below.', 'info');
        }
    }

    clearSelection() {
        this.selectedFiles = [];
        // re-render the file input so the same file can be chosen again
        this.showInput = false;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => {
            this.showInput = true;
        });
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
        const pending = this.results.filter((r) => !r.isFinal && r.serviceId).map((r) => r.serviceId);
        if (pending.length === 0) {
            this.stopPolling();
            return;
        }
        if (Date.now() - this.pollStarted > POLL_LIMIT_MS) {
            this.stopPolling();
            this.results = this.results.map((r) =>
                r.isFinal ? r : { ...r, message: 'Still processing. Check "View Today Uploads" in a few minutes.' }
            );
            return;
        }
        try {
            const statuses = await getStatus({ serviceIds: pending });
            const byId = new Map(statuses.map((s) => [s.serviceId, s]));
            let finishedNow = [];
            this.results = this.results.map((r) => {
                const s = byId.get(r.serviceId);
                if (!s) {
                    return r;
                }
                const row = this.toRow(s, r.key);
                if (row.isFinal && !r.isFinal) {
                    finishedNow.push(row);
                }
                return row;
            });
            finishedNow.forEach((r) => {
                const variant = r.status === 'Completed' ? 'success' : r.status === 'Duplicate' ? 'warning' : 'error';
                this.toast(`${r.fileName}: ${r.status}`, r.message || '', variant);
            });
        } catch (e) {
            // keep polling; a single failed refresh is not fatal
        }
    }

    toRow(s, existingKey) {
        const isFinal = s.isFinal === true || FINAL.includes(s.status);
        const isResume = this.requestedType === 'Resume';
        return {
            key: existingKey || s.serviceId || newKey(),
            serviceId: s.serviceId,
            fileName: s.fileName,
            status: s.status || 'Queued',
            message: s.message,
            isFinal,
            isRunning: !isFinal,
            badgeClass: BADGE[s.status] || 'badge-info',
            accountUrl: s.accountId ? `/${s.accountId}` : null,
            accountLabel: s.accountId ? `${isResume ? 'Candidate' : 'Client'}: ${s.accountName}` : null,
            opportunityUrl: s.opportunityId ? `/${s.opportunityId}` : null,
            opportunityName: s.opportunityName,
            jobDescriptionUrl: s.jobDescriptionId ? `/${s.jobDescriptionId}` : null,
            jobDescriptionName: s.jobDescriptionName
        };
    }

    // ---------------- today modal ----------------

    async openTodayModal() {
        this.showModal = true;
        this.todayLoading = true;
        try {
            const rows = await getMyUploadsToday({ requestedType: this.requestedType });
            this.todayRows = rows.map((s) => {
                const recId = s.opportunityId || s.accountId || s.jobDescriptionId;
                const recName = s.opportunityId ? s.opportunityName : s.accountId ? s.accountName : s.jobDescriptionName;
                return {
                    key: s.serviceId,
                    fileName: s.fileName,
                    status: s.status,
                    message: s.message,
                    createdDate: s.createdDate,
                    recordUrl: recId ? `/${recId}` : null,
                    recordName: recName
                };
            });
        } catch (e) {
            this.toast('Error', 'Could not load today\'s uploads: ' + this.errorText(e), 'error');
        } finally {
            this.todayLoading = false;
        }
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
