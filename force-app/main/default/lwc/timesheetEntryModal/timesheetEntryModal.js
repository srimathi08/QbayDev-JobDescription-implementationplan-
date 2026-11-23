import { LightningElement, api, track, wire } from 'lwc';
import getProjects from '@salesforce/apex/TimesheetController.getProjects';
import createTimesheetEntry from '@salesforce/apex/TimesheetController.createTimesheetEntry';
import updateTimesheetEntry from '@salesforce/apex/TimesheetController.updateTimesheetEntry';
import getStatusPicklistValues from '@salesforce/apex/TimesheetController.getStatusPicklistValues';
import createMultipleTimesheetEntries from '@salesforce/apex/TimesheetController.createMultipleTimesheetEntries';
import getRestrictedDatesForWeek from '@salesforce/apex/TimesheetController.getRestrictedDatesForWeek';
import checkDate from '@salesforce/apex/TimesheetController.checkDate';

// import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningAlert from 'lightning/alert';

const RD_LABEL = 'Research & Development';

export default class TimesheetEntryModal extends LightningElement {
    _entry;
    @api set entry(value) { this._entry = value; this.initializeEntry(value); }
    get entry() { return this._entry; }

    @api isOpen = false;
    @track isSaving = false;
    @track errorMessage = '';    // For server/validation errors
    @track version = '2.1';      // For deployment verification

    connectedCallback() {
        console.log('TimesheetEntryModal loaded - version: ' + this.version);
    }

    get maxDate() {
        return new Date().toISOString().split('T')[0];
    }
    // single-entry fields
    @track entryId = null;
    @track entryDate; entryProject; startTime = '09:30'; endTime = '18:30';
    @track task; regularHours = 0; overtimeHours = 0; totalHours = 0; hoursWorked = null;
    @track projectOptions = []; status; statusOptions = []; approvalStatus = 'Draft'; employmentStatus = '';
    @track relatedProjectId;
    @track isRD = false;

    // multi-row
    @track rows = []; rowIdCounter = 0;

    // restricted dates
    @track restrictedHolidays = [];
    @track restrictedLeaves = [];
    @track messageWH = '';

    /* -------------------------
       Wire: Projects (normalize to label/value)
       ------------------------- */
    @wire(getProjects) wiredProjects({ error, data }) {
        if (data) {
            // Apex returns list of maps. Normalize to combobox friendly objects.
            try {
                this.projectOptions = data.map(d => {
                    // d may be a plain object with label/value/employmentStatus or {Name, Id}
                    const label = d.label || d.Name || d.name || '';
                    const value = d.value || d.Id || d.id || '';
                    const employmentStatus = d.employmentStatus || d.employmentstatus || d.Employment_Status__c || '';
                    return { label: String(label), value: String(value), employmentStatus: employmentStatus };
                }).filter(o => o.label && o.value);
            } catch (e) {
                console.error('Normalization failed for projects', e);
                this.projectOptions = data; // fallback
            }
        } else if (error) {
            if (error) {
                this.showToast('Error', 'getProjects error: ' + JSON.stringify(error), 'error');
                this.projectOptions = [];
            }

            console.error('getProjects error', error);
            this.projectOptions = [];
        }
    }

    /* -------------------------
       Wire: Status picklist -> label/value form
       ------------------------- */
    @wire(getStatusPicklistValues) wiredStatus({ error, data }) {
        if (data) {
            this.statusOptions = data.map(s => ({ label: s, value: s }));
        } else if (error) {
            console.error('status picklist error', error);
            this.statusOptions = [];
        }
    }



    createEmptyRow() {
        return {
            clientKey: 'r-' + (this.rowIdCounter++),
            date: null,
            projectId: null,
            employmentStatus: '',
            startTime: null,  // Blank for user to enter
            endTime: null,    // Blank for user to enter
            task: '',
            status: null,
            regularHours: 0,
            overtimeHours: 0,
            totalHours: 0,
            hoursWorked: null,
            approvalStatus: 'Draft',
            relatedProjectId: null,
            isRD: false,
            relatedOptions: []
        };
    }

    initializeEntry(entry) {
        if (entry) {
            console.log('Initializing modal in edit mode with entry', JSON.stringify(entry));
            // edit mode
            this.entryId = entry.Id || entry.id || null;
            this.entryDate = entry.Date__c || entry.date || null;
            this.entryProject = entry.Project__c || entry.projectId || null;
            this.startTime = (entry.Start_Time__c || entry.startTime ? this.formatTimeString(entry.Start_Time__c || entry.startTime) : '09:30');
            this.endTime = (entry.End_Time__c || entry.endTime ? this.formatTimeString(entry.End_Time__c || entry.endTime) : '18:30');
            this.task = entry.Tasks__c || entry.task || '';
            this.regularHours = entry.Regular_Hours__c || entry.hours || 0;
            this.overtimeHours = entry.Overtime_Hours__c || entry.overtime || 0;
            this.totalHours = entry.Total_Hours__c || entry.totalHours || 0;
            this.hoursWorked = entry.Total_Hours__c || entry.totalHours || null; // Match initially
            this.status = entry.Status__c || entry.status || null;
            this.approvalStatus = entry.Approval_Status__c || entry.approvalStatus || 'Draft';
            this.employmentStatus = entry.Billing_Status__c || entry.employmentStatus || '';
            this.relatedProjectId = entry.Related_Project__c || entry.relatedProjectId || null;
            this.isRD = this.checkIsRD(this.entryProject);
            this.updateSingleRelatedOptions();
            this.rows = [];
        } else {
            // new multi-row
            this.entryId = null;
            this.entryDate = null; this.entryProject = null; this.startTime = '09:30'; this.endTime = '18:30';
            this.task = ''; this.regularHours = 0; this.overtimeHours = 0; this.totalHours = 0; this.hoursWorked = null;
            this.status = null; this.approvalStatus = 'Draft'; this.employmentStatus = '';
            this.relatedProjectId = null; this.isRD = false;
            this.updateSingleRelatedOptions();
            this.rows = [this.createEmptyRow()];
        }
        this.fetchRestrictedDates();
    }

    async fetchRestrictedDates() {
        // Calculate week and year from current date if not editing, or from entry date
        const targetDate = this.entryDate ? new Date(this.entryDate) : new Date();
        const year = targetDate.getFullYear();
        
        // Simple week number calculation (matches server getWeekStartDate logic roughly)
        // For precision, we just fetch for the current week context.
        // If the user changes the date to a different week, we might need to re-fetch,
        // but fetching once on load for the current/selected week is a good start.
        const firstDayOfYear = new Date(year, 0, 1);
        const pastDaysOfYear = (targetDate - firstDayOfYear) / 86400000;
        const weekNumber = Math.ceil((pastDaysOfYear + firstDayOfYear.getDay() + 1) / 7);

        try {
            const data = await getRestrictedDatesForWeek({ weekNumber, year });
            if (data) {
                this.restrictedHolidays = (data.holidays || []).map(d => this.normalizeDate(d));
                this.restrictedLeaves = (data.leaves || []).map(d => this.normalizeDate(d));
            }
        } catch (error) {
            console.error('Error fetching restricted dates', error);
        }
    }

    @track singleRelatedOptions = [];
    updateSingleRelatedOptions() {
        if (this.isRD) this.singleRelatedOptions = this.projectOptions;
        else this.singleRelatedOptions = [];
    }

    checkIsRD(projectId) {
        if (!projectId || !this.projectOptions) return false;
        const sel = this.projectOptions.find(p => p.value === projectId);
        return sel ? sel.label === RD_LABEL : false;
    }

    formatTimeString(sfTime) {
        if (!sfTime) return null;
        if (typeof sfTime === 'string') {
            // Updated regex to optionally capture AM/PM and preserve it
            const m = sfTime.match(/^(\d{1,2}):(\d{2})(\s*[ap]m)?/i);
            if (m) {
                const hh = m[1].padStart(2, '0');
                const mm = m[2];
                const ampm = m[3] ? m[3].trim().toLowerCase() : '';
                return ampm ? `${hh}:${mm} ${ampm}` : `${hh}:${mm}`;
            }
            return sfTime;
        }
        if (typeof sfTime === 'object' && sfTime.hours !== undefined) {
            return String(sfTime.hours).padStart(2, '0') + ':' + String(sfTime.minutes || 0).padStart(2, '0');
        }
        return null;
    }

    parseTimeToMinutes(t) {
        if (!t) return 0;
        let time = String(t).toLowerCase();
        let isPm = time.includes('pm');
        let isAm = time.includes('am');
        // Remove am/pm for parsing
        time = time.replace(/[ap]m/g, '').trim();
        
        const parts = time.split(':');
        if (parts.length < 2) return 0;
        
        let hours = parseInt(parts[0], 10);
        let minutes = parseInt(parts[1], 10);
        
        if (isNaN(hours) || isNaN(minutes)) return 0;

        if (isPm && hours < 12) hours += 12;
        if (isAm && hours === 12) hours = 0;
        
        // Final fallback: if no AM/PM, and it's 12:xx, it's 12:xx (Noon) 
        // unless it's explicitly 00:xx (Midnight).
        if (!isAm && !isPm && hours === 0 && !t.startsWith('00:')) hours = 12;

        return hours * 60 + minutes;
    }

    /* ================= Single-entry handlers ================= */
    handleInputChange(event) {
        const label = event.target.label;
        const name = event.target.name;
        const value = event.target.value;

        // Assignments (Always run so state stays in sync)
        if (label === 'Project *' || name === 'entryProject') {
            this.entryProject = value;
            const sel = this.projectOptions.find(p => p.value === value);
            this.employmentStatus = sel ? sel.employmentStatus : '';
            this.isRD = (sel ? sel.label === RD_LABEL : false);
            this.updateSingleRelatedOptions();
            if (!this.isRD) this.relatedProjectId = null;
        } else if (label === 'Related Project' || name === 'relatedProject') {
            this.relatedProjectId = value;
        } else if (label === 'Date' || name === 'entryDate') {
            this.entryDate = value;
        } else if (label === 'Start Time' || name === 'startTime') {
            this.startTime = value;
            this.hoursWorked = null;
        } else if (label === 'End Time' || name === 'endTime') {
            this.endTime = value;
            this.hoursWorked = null;
        } else if (label === 'Hours Worked' || name === 'hoursWorked') {
            this.hoursWorked = value;
            this.startTime = null;
            this.endTime = null;
        } else if (label === 'Task *' || name === 'task') {
            this.task = value;
        } else if (label === 'Status *' || name === 'entryStatus') {
            this.status = value;
        }

        // Validation & Calculation trigger
        if (label === 'Date' || name === 'entryDate' || label === 'Project *' || name === 'entryProject' ||
            label === 'Hours Worked' || name === 'hoursWorked' || label === 'Start Time' || name === 'startTime' || 
            label === 'End Time' || name === 'endTime') {
            
            this.calculateHours(); // Updates this.totalHours
            
            // Check for WH Date feedback
            const isWH = this.isWeekend(this.entryDate) || this.restrictedHolidays.includes(this.normalizeDate(this.entryDate));
            this.messageWH = isWH ? 'This entry is on a weekend/holiday and will require manager pre-approval.' : '';
            
            // Re-validate date restriction
            const dateInput = this.template.querySelector('[data-field="date"]') || this.template.querySelector('lightning-input[type="date"]');
            if (dateInput && this.entryDate) {
                this.validateDateInput(dateInput, this.entryDate, this.entryProject, this.totalHours);
            }
        }
    }

    calculateHours() {
        if (this.hoursWorked !== null && this.hoursWorked !== '') {
            const total = parseFloat(this.hoursWorked) || 0;
            this.totalHours = Math.round(total * 100) / 100;
            this.regularHours = Math.round((total > 8 ? 8 : total) * 100) / 100;
            this.overtimeHours = Math.round((total > 8 ? total - 8 : 0) * 100) / 100;
        } else if (this.startTime && this.endTime) {
            const start = this.parseTimeToMinutes(this.startTime);
            const end = this.parseTimeToMinutes(this.endTime);
            const totalM = Math.max(0, end - start);
            const total = totalM / 60;
            this.totalHours = Math.round(total * 100) / 100;
            this.regularHours = Math.round((total > 8 ? 8 : total) * 100) / 100;
            this.overtimeHours = Math.round((total > 8 ? total - 8 : 0) * 100) / 100;
        } else {
            this.totalHours = this.regularHours = this.overtimeHours = 0;
        }
    }

    async saveEntry() {
        // Validate required
        if (!this.entryDate || !this.entryProject || !this.task) {
            //this.showToast('Error', 'Please fill required fields (Date, Project, Task).', 'error'); return;
            await this.showToast('Error', 'Please fill required fields (Date, Project, Task)', 'error');
            return;
        }

        // Normalize date -> YYYY-MM-DD
        let normalizedDate = this.normalizeDate(this.entryDate);
        if (!normalizedDate) { this.showToast('Error', 'Invalid date format', 'error'); return; }

        const st = this.formatTimeString(this.startTime);
        const et = this.formatTimeString(this.endTime);
        
        if (st && et) {
            const startMins = this.parseTimeToMinutes(st);
            const endMins = this.parseTimeToMinutes(et);
            if (endMins <= startMins) {
                this.showToast('Error', 'End time must be after start time', 'error'); return;
            }
        }

        const fields = {
            Date__c: normalizedDate,
            Project__c: this.entryProject,
            Start_Time__c: st,
            End_Time__c: et,
            Tasks__c: (this.task || '').trim(),
            Status__c: this.status || (this.statusOptions.length ? this.statusOptions[0].value : null),
            Regular_Hours__c: this.regularHours || 0,
            Overtime_Hours__c: this.overtimeHours || 0,
            Total_Hours__c: this.totalHours || 0,
            Billing_Status__c: this.employmentStatus || null,
            Related_Project__c: this.relatedProjectId || null
        };
        console.log('Saving entry with fields', fields);
        console.log('Saving entry with fields1', JSON.stringify(fields));
        console.log('Entry ID:', this.entryId);
        this.isSaving = true;
        this.errorMessage = '';
        try {
            if (this.entryId) {
                console.log('Updating entry ID:', this.entryId);
                fields.Id = this.entryId;
                console.log('Fields to update:', JSON.stringify(fields));
                await updateTimesheetEntry({ fields: fields });
                // Close modal and reset state BEFORE showing alert
                this.isSaving = false;
                this.handleClose();
                this.dispatchEvent(new CustomEvent('entrycreated'));
                await this.showToast('Success', 'Timesheet entry updated successfully', 'success');
            } else {
                // call single-entry create; the Apex controller delegates to multi-row internally
                await createTimesheetEntry({ newEntryFields: fields });
                // Close modal and reset state BEFORE showing alert
                this.isSaving = false;
                this.handleClose();
                this.dispatchEvent(new CustomEvent('entrycreated'));
                await this.showToast('Success', 'Timesheet entry created successfully', 'success');
            }
        } catch (err) {
            this.isSaving = false;
            this.errorMessage = 'Failed to save entry: ' + this.extractErrorMessage(err);
            console.error('saveEntry error', err);
        }
    }

    /* ================= Multi-row handlers ================= */
    addRow() { this.rows = [...this.rows, this.createEmptyRow()]; }

    deleteRow(event) {
        // event comes from lightning-button-icon; dataset on the button is used
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (this.rows.length === 1) {
            // Show inline warning instead of alert (which appears behind modal)
            this.warningMessage = 'At least one row is required';
            // Auto-clear after 3 seconds
            setTimeout(() => { this.warningMessage = ''; }, 3000);
            return;
        }
        this.warningMessage = '';  // Clear any existing warning
        const c = [...this.rows]; c.splice(idx, 1); this.rows = c;
    }

    handleRowChange(event) {
        const idx = parseInt(event.target.dataset.index, 10);
        const field = event.target.dataset.field;
        const value = event.target.value;
        const copy = [...this.rows];
        const row = { ...copy[idx] };

        // Assignments (Always run so state stays in sync)
        if (field === 'projectId') {
            row.projectId = value;
            const proj = this.projectOptions.find(p => p.value === value);
            row.employmentStatus = proj ? proj.employmentStatus : '';
            row.isRD = (proj ? proj.label === RD_LABEL : false);
            if (row.isRD) row.relatedOptions = this.projectOptions;
            else row.relatedOptions = [];
            if (!row.isRD) row.relatedProjectId = null;
        } else if (field === 'relatedProjectId') {
            row.relatedProjectId = value;
        } else if (field === 'date') {
            row.date = value;
        } else if (field === 'startTime') {
            row.startTime = value;
            row.hoursWorked = null;
        } else if (field === 'endTime') {
            row.endTime = value;
            row.hoursWorked = null;
        } else if (field === 'hoursWorked') {
            row.hoursWorked = value;
            row.startTime = null;
            row.endTime = null;
        } else if (field === 'task') {
            row.task = value ? value.trim() : '';
        } else if (field === 'status') {
            row.status = value;
        }
        
        copy[idx] = row; 
        this.rows = copy;

        // Validation & Calculation trigger
        if (field === 'date' || field === 'projectId' || field === 'startTime' || field === 'endTime' || field === 'hoursWorked') {
            this.calculateRowHours(idx);
            
            // Check for WH and update overall message if any row is WH
            const whRows = this.rows.filter(r => r.date && (this.isWeekend(r.date) || this.restrictedHolidays.includes(this.normalizeDate(r.date))));
            this.messageWH = whRows.length > 0 ? 'Some entries are on weekends/holidays and will require manager pre-approval.' : '';

            setTimeout(() => {
                const dateInput = this.template.querySelector(`[data-index="${idx}"][data-field="date"]`);
                const updatedRow = this.rows[idx];
                if (dateInput && updatedRow.date) {
                    this.validateDateInput(dateInput, updatedRow.date, updatedRow.projectId, updatedRow.totalHours);
                }
            }, 0);
        }
    }

    // Helper to check if a date is restricted
    async validateDateInput(target, dateValue, projectId, hours) {
        if (!dateValue) {
            target.setCustomValidity('');
            target.reportValidity();
            return;
        }

        const normalized = this.normalizeDate(dateValue);
        // Fix: Use local-safe date parsing for weekend check
        const [y, m, d] = dateValue.split('-').map(Number);
        const dateObj = new Date(y, m - 1, d);
        const day = dateObj.getDay();

        // Local check is now only a hint; the server bypasses weekend check for certain projects
        // So we call the server-side check mostly.
        
        try {
            const errorMessage = await checkDate({ 
                entryDate: normalized, 
                projectId: projectId || null, 
                hours: hours || 0 
            });
            target.setCustomValidity(errorMessage || '');
            target.reportValidity();
        } catch (error) {
            console.error('Validation failed', error);
            target.setCustomValidity('');
            target.reportValidity();
        }
    }

    // Helper to check if a date is a weekend
    isWeekend(dateString) {
        if (!dateString) return false;
        const date = new Date(dateString);
        const day = date.getDay();
        return day === 0 || day === 6; // 0 = Sunday, 6 = Saturday
    }

    calculateRowHours(index) {
        const copy = [...this.rows]; const row = { ...copy[index] };
        if (row.hoursWorked !== null && row.hoursWorked !== '') {
            const total = parseFloat(row.hoursWorked) || 0;
            row.totalHours = Math.round(total * 100) / 100;
            row.regularHours = Math.round((total > 8 ? 8 : total) * 100) / 100;
            row.overtimeHours = Math.round((total > 8 ? total - 8 : 0) * 100) / 100;
        } else if (row.startTime && row.endTime) {
            const start = this.parseTimeToMinutes(row.startTime);
            const end = this.parseTimeToMinutes(row.endTime);
            const totalM = Math.max(0, end - start); const total = Math.round((totalM / 60) * 100) / 100;
            row.totalHours = total;
            row.regularHours = Math.round((total > 8 ? 8 : total) * 100) / 100;
            row.overtimeHours = Math.round((total > 8 ? total - 8 : 0) * 100) / 100;
        } else {
            row.totalHours = row.regularHours = row.overtimeHours = 0;
        }
        copy[index] = row; this.rows = copy;
    }

    /*async saveAllEntries() {
        console.log( 'this.rows'+JSON.stringify(this.rows))
    if (!this.rows || this.rows.length === 0) {
        this.showToast('Error', 'Add at least one row', 'error');
        return;
    }

    const payload = [];
    for (let i = 0; i < this.rows.length; i++) {
        const r = this.rows[i];
        if (!r.date || !r.projectId || !r.task || !r.status) {
            this.showToast('Error', `Row ${i + 1}: Date, Project, Task and Status required`, 'error');
            return;
        }
        const normalized = this.normalizeDate(r.date);
        if (!normalized) {
            this.showToast('Error', `Row ${i + 1}: invalid date`, 'error');
            return;
        }

        const normalizeTime = t => {
            if (!t) return null;
            if (/^\d{2}:\d{2}$/.test(t)) return t;
            const parts = String(t).split(':');
            if (parts.length >= 2) return String(parts[0]).padStart(2, '0') + ':' + String(parts[1]).padStart(2, '0');
            return null;
        };
        const st = normalizeTime(r.startTime), et = normalizeTime(r.endTime);
        if (st && et) {
            const [sh, sm] = st.split(':'), [eh, em] = et.split(':');
            if ((parseInt(eh, 10) * 60 + parseInt(em, 10)) < (parseInt(sh, 10) * 60 + parseInt(sm, 10))) {
                this.showToast('Error', `Row ${i + 1}: End time must be after start time`, 'error');
                return;
            }
        }
        console.log('r.wemp',r.employmentStatus)
        payload.push({
            Date__c: normalized,
            Project__c: r.projectId,
            Start_Time__c: st,
            End_Time__c: et,
            Tasks__c: r.task,
            Description__c: r.description || '',
            Status__c: r.status,
            Regular_Hours__c: r.regularHours || 0,
            Overtime_Hours__c: r.overtimeHours || 0,
            Total_Hours__c: r.totalHours || 0,
            Billing_Status__c: r.employmentStatus || null,
            Approval_Status__c: r.approvalStatus || 'Draft'
        });
    }
    console.log('payload'+JSON.stringify(payload))
    this.isSaving = true;
    try {
        const ids = await createMultipleTimesheetEntries({ rows: payload });
        this.showToast('Success', `${ids.length} entries created`, 'success');
        this.handleClose();
        this.dispatchEvent(new CustomEvent('entrycreated'));
    } catch (err) {
        this.showToast('Error', 'Failed to create entries: ' + this.extractErrorMessage(err), 'error');
        console.error('createMultipleTimesheetEntries error', err);
    } finally {
        this.isSaving = false;
    }
}*/

    async saveAllEntries() {
        console.log('this.rows: ' + JSON.stringify(this.rows));

        if (!this.rows || this.rows.length === 0) {
            this.errorMessage = 'Please add at least one row.';
            return;
        }
        this.errorMessage = '';

        // --- STEP 1: UI VALIDATION (Highlighting red boxes with inline errors) ---
        // This finds all inputs/comboboxes in your HTML and triggers their built-in validation
        const allValid = [
            ...this.template.querySelectorAll('lightning-input'),
            ...this.template.querySelectorAll('lightning-combobox'),
            ...this.template.querySelectorAll('lightning-textarea')
        ].reduce((validSoFar, inputCmp) => {
            inputCmp.reportValidity();
            return validSoFar && inputCmp.checkValidity();
        }, true);

        if (!allValid) {
            // Inline validation messages will show at each field
            return;
        }

        // --- STEP 2: PAYLOAD BUILDING ---
        const payload = [];
        for (let i = 0; i < this.rows.length; i++) {
            const r = this.rows[i];

            // Manual check for required data logic
            if (!r.date || !r.projectId || !r.task || !r.status) {
                this.errorMessage = `Row ${i + 1}: Date, Project, Task and Status are required.`;
                return;
            }

            const normalized = this.normalizeDate(r.date);
            const st = this.formatTimeString(r.startTime);
            const et = this.formatTimeString(r.endTime);

            // Time logic check
            if (st && et) {
                if (this.parseTimeToMinutes(et) <= this.parseTimeToMinutes(st)) {
                    this.errorMessage = `Row ${i + 1}: End time must be after start time.`;
                    return;
                }
            }

            payload.push({
                Date__c: normalized,
                Project__c: r.projectId,
                Start_Time__c: st,
                End_Time__c: et,
                Tasks__c: r.task,
                Status__c: r.status,
                Regular_Hours__c: r.regularHours || 0,
                Overtime_Hours__c: r.overtimeHours || 0,
                Total_Hours__c: r.totalHours || 0,
                Billing_Status__c: r.employmentStatus || null,
                Related_Project__c: r.relatedProjectId || null
            });
        }

        // --- STEP 3: SERVER CALL ---
        this.isSaving = true;
        this.errorMessage = '';
        try {
            const ids = await createMultipleTimesheetEntries({ rows: payload });
            const successMsg = ids.length === 1
                ? 'Timesheet entry created successfully'
                : `${ids.length} Timesheet entries created successfully`;
            // Close modal and reset state BEFORE showing alert (so "Saving..." doesn't persist)
            this.isSaving = false;
            this.handleClose();
            this.dispatchEvent(new CustomEvent('entrycreated'));
            // Show success alert after modal is closed
            await this.showToast('Success', successMsg, 'success');
        } catch (err) {
            // Capture Apex Errors
            this.isSaving = false;
            this.errorMessage = 'Failed to create entries: ' + this.extractErrorMessage(err);
            console.error('Save Error', err);
        }
    }

    normalizeDate(input) {
        // Accept YYYY-MM-DD or Date-like strings. Return YYYY-MM-DD or null.
        try {
            if (!input) return null;
            // If already in YYYY-MM-DD
            if (/^\d{4}-\d{2}-\d{2}$/.test(input)) return input;
            const dt = new Date(input);
            if (isNaN(dt.getTime())) return null;
            return dt.toISOString().slice(0, 10);
        } catch (e) { return null; }
    }

    extractErrorMessage(error) {
        try {
            if (!error) return 'Unknown error';
            
            // 1. Apex AuraHandledException
            if (error.body && error.body.message) return error.body.message;
            
            // 2. DML Errors (Field errors / Page errors)
            if (error.body && error.body.pageErrors && error.body.pageErrors.length > 0) {
                return error.body.pageErrors[0].message;
            }
            if (error.body && error.body.fieldErrors) {
                const fields = Object.keys(error.body.fieldErrors);
                if (fields.length > 0 && error.body.fieldErrors[fields[0]].length > 0) {
                    return error.body.fieldErrors[fields[0]][0].message;
                }
            }
            
            // 3. Platform Error
            if (error.message) return error.message;
            
            // 4. String error
            if (typeof error === 'string') return error;
            
            // 5. Raw error object stringified
            return JSON.stringify(error);
        } catch (e) {
            console.error('Error in extractErrorMessage', e);
        }
        return 'Unknown error';
    }

    handleClose() { this.isOpen = false; this.dispatchEvent(new CustomEvent('close')); }
    /*showToast(title,msg,variant) { 
       this.dispatchEvent(new ShowToastEvent({ title, message: msg, variant })); }*/
    async showToast(title, msg, variant) {
        await LightningAlert.open({
            message: msg,
            theme: variant, // success | error | warning | info
            label: title
        });
    }
    get isEditMode() { return this.entryId !== null; }
    get modalTitle() {
        return this.isEditMode ? 'Edit Timesheet Entry' : 'New Timesheet Entries';
    }
}