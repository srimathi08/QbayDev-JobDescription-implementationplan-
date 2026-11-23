import { LightningElement, api, track } from 'lwc';
import getEmployeesByCertification from '@salesforce/apex/EmployeeResumeController.getEmployeesByCertification';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class EmployeeSelector extends LightningElement {
    @api keyword = '';
    @track employees = [];
    @track selectedEmployees = [];
    @track showTable = false;
    @track isLoading = false;

    // Datatable columns map to the wrapper fields returned by Apex
    columns = [
        { label: 'Name', fieldName: 'Name' },
        { label: 'Designation', fieldName: 'Designation' },
        { label: 'Experience', fieldName: 'YearsOfExperience' },
        { label: 'Certifications', fieldName: 'Certifications', wrapText: true }
    ];

    get hasResults() {
        return this.showTable && (this.employees?.length || 0) > 0;
    }

    handleKeywordChange(event) {
        this.keyword = event.target.value || '';
        this.showTable = false; // hide table until next search
    }

    async handleSearch() {
        const term = (this.keyword || '').trim();
        if (!term) {
            this.employees = [];
            this.showTable = false;
            this.fireToast('Enter a keyword', 'Please type a certification keyword to search.', 'info');
            return;
        }

        this.isLoading = true;
        try {
            const result = await getEmployeesByCertification({ keyword: term });
            this.employees = Array.isArray(result) ? result : [];
            this.showTable = this.employees.length > 0;

            if (!this.showTable) {
                this.fireToast('No matches', 'No employees found for that certification keyword.', 'warning');
            }
        } catch (err) {
            // Optional: log full error for debugging
            // eslint-disable-next-line no-console
            console.error('Error fetching employees:', err);
            this.employees = [];
            this.showTable = false;

            const message =
                err?.body?.message ||
                err?.message ||
                'There was a problem fetching employees.';
            this.fireToast('Error', message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleRowSelection(event) {
        const selectedRows = event?.detail?.selectedRows || [];
        this.selectedEmployees = selectedRows.map(r => r.Id);

        // Let Flow/parent know which Ids are selected
        this.dispatchEvent(
            new CustomEvent('valuechange', {
                detail: { value: this.selectedEmployees }
            })
        );
    }

    // Expose selected Ids to Flow as component value
    @api
    get value() {
        return this.selectedEmployees;
    }

    fireToast(title, message, variant = 'info') {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}