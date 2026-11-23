/*import { LightningElement, api, track,wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import submitWeeklyEntriesForApproval from '@salesforce/apex/TimesheetController.submitWeeklyEntriesForApproval';
import checkWeeklySubmissionStatus from '@salesforce/apex/TimesheetController.checkWeeklySubmissionStatus';
import getWeeklyDataForExport from '@salesforce/apex/TimesheetController.getWeeklyDataForExport';
import getEntriesForWeek from '@salesforce/apex/TimesheetController.getEntriesForWeek';
import { refreshApex } from '@salesforce/apex';

export default class WeeklyTimesheetView extends LightningElement {
    _entries = [];
    weeklyEntries = [];
    wiredEntriesResult;
    @track currentWeekOffset = 0;
    @track currentWeekNumber = 0;
    @track currentYear = new Date().getFullYear();
    @track isLoading = false;
    @track weeklySubmissionStatus = {
        hasEntries: false,
        canSubmit: false,
        allSubmitted: false,
        anySubmitted: false,
        entryCount: 0
    };
@wire(getEntriesForWeek, { weekNumber: '$currentWeekNumber', year: '$currentYear' })
    wiredEntriesHandler(result) {
        this.wiredEntriesResult = result; // Store for refreshApex
        if (result.data) {
            this._entries = result.data;
            this.processEntries();
        } else if (result.error) {
            console.error('Error loading entries:', result.error);
            this._entries = [];
            this.weeklyEntries = [];
        }
    }

    @api
    set timesheetEntries(value) {
        this._entries = value || [];
        this.filterWeek();
    }
    get timesheetEntries() { 
        return this.weeklyEntries; 
    }

   connectedCallback() {
            this.checkSubmissionStatus();
    }
    // Calculate current week number and year
  
    // Check if viewing current week
    get isCurrentWeek() {
        return this.currentWeekOffset === 0;
    }

    // Disable submit button based on status
    get disableSubmitButton() {
        return !this.weeklySubmissionStatus.canSubmit || 
               this.weeklyEntries.length === 0 ||
               this.isLoading;
    }

    // Get week start and end dates for display
    get weekStartDate() {
        const date = this.getWeekStartDate(this.currentWeekOffset);
        return this.formatDate(date);
    }

    get weekEndDate() {
        const startDate = this.getWeekStartDate(this.currentWeekOffset);
        const endDate = new Date(startDate);
        endDate.setDate(endDate.getDate() + 6);
        return this.formatDate(endDate);
    }

    // Calculate weekly totals
    get weekTotalHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.totalHours || 0), 0).toFixed(2);
    }

    get weekRegularHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.hours || 0), 0).toFixed(2);
    }

    get weekOvertimeHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.overtime || 0), 0).toFixed(2);
    }

    filterWeek() {
        const targetDate = new Date();
        targetDate.setDate(targetDate.getDate() + (this.currentWeekOffset * 7));
        
        const week = this.getWeekNumber(targetDate);
        const year = targetDate.getFullYear();
        
        this.currentWeekNumber = week;
        this.currentYear = year;

        this.weeklyEntries = this._entries
            .filter(e => {
                const d = new Date(e.Date__c || e.date);
                return this.getWeekNumber(d) === week && d.getFullYear() === year;
            })
            .map(entry => {
                const regular = entry.Regular_Hours__c || entry.hours || 0;
                const overtime = entry.Overtime_Hours__c || entry.overtime || 0;
                const entryDate = new Date(entry.Date__c || entry.date);
                
                return {
                    id: entry.Id,
                    date: this.formatDate(entryDate),
                    day: this.getDayName(entryDate),
                    project: entry.Project__r?.Name || entry.project || '-',
                    task: entry.Tasks__c || entry.task || '-',
                    hours: regular,
                    overtime: overtime,
                    totalHours: regular + overtime,
                    status: entry.Status__c || entry.status,
                    approvalStatus: entry.Approval_Status__c || 'Draft',
                    statusClass: this.getStatusClass(entry.Approval_Status__c)
                };
            })
            .sort((a, b) => new Date(a.date) - new Date(b.date));

        this.checkSubmissionStatus();
    }

    getStatusClass(status) {
        switch(status) {
            case 'Approved': return 'slds-text-color_success';
            case 'Submitted': return 'slds-text-color_warning';
            case 'Rejected': return 'slds-text-color_error';
            default: return '';
        }
    }

    handlePrevWeek() {
        this.currentWeekOffset -= 1;
        this.filterWeek();
    }

    handleNextWeek() {
        if (!this.isCurrentWeek) {
            this.currentWeekOffset += 1;
            this.filterWeek();
        }
    }

    // Check submission status from server
    async checkSubmissionStatus() {
        try {
            const status = await checkWeeklySubmissionStatus({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });
            this.weeklySubmissionStatus = status;
        } catch (error) {
            console.error('Error checking submission status:', error);
        }
    }

    // Submit weekly entries for approval
    async handleWeeklySubmitForApproval() {
        this.isLoading = true;
        try {
            const result = await submitWeeklyEntriesForApproval({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });
            
            this.showToast('Success', result.message, 'success');
            // Force reload entries here
        await this.reloadEntries();
            // Refresh entries
            //this.dispatchEvent(new CustomEvent('refreshentries'));
            
            // Update submission status
            await this.checkSubmissionStatus();
            
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to submit timesheet', 'error');
        } finally {
            this.isLoading = false;
        }
        
    }
// Example reload method
async reloadEntries() {
    try {
        const newEntries = await getEntriesForWeek({
            weekNumber: this.currentWeekNumber,
            year: this.currentYear
        });
        this._entries = newEntries;
        this.filterWeek(); // repopulate weeklyEntries and totals
    } catch (error) {
        console.error('Error reloading entries:', error);
        this.showToast('Error', 'Failed to reload updated timesheet entries', 'error');
    }
}


  
// Reliable Excel export handler
async handleExportExcel() {
    this.isLoading = true;
    try {
        const data = await getWeeklyDataForExport({
            weekNumber: this.currentWeekNumber,
            year: this.currentYear
        });

        if (!data.entries || data.entries.length === 0) {
            this.showToast('Error', 'No entries found for this week', 'error');
            this.isLoading = false;
            return;
        }

        this.downloadCSV(data);
        this.showToast('Success', 'Excel file downloaded successfully', 'success');
    } catch (error) {
    this.showToast('Error', error.body && error.body.message ? error.body.message : error.message || 'Failed to export Excel', 'error');
    console.error('Export error:', error);


    }
    this.isLoading = false;
}

// Robust CSV download logic
downloadCSV(data) {
    let csv = '\uFEFF'; // BOM for Excel
    csv += 'Date,Day,Project,Task,Regular Hours,Overtime Hours,Total Hours,Status\n';
    data.entries.forEach(entry => {
        const dateObj = new Date(entry.Date__c);
        csv += `"${this.formatDate(dateObj)}",`;
        csv += `"${this.getDayName(dateObj)}",`;
        csv += `"${entry.Project__r?.Name || '-'}",`;
        csv += `"${entry.Tasks__c || '-'}",`;
        csv += `${entry.Regular_Hours__c || 0},`;
        csv += `${entry.Overtime_Hours__c || 0},`;
        csv += `${entry.Total_Hours__c != null ? entry.Total_Hours__c : ((entry.Regular_Hours__c || 0) + (entry.Overtime_Hours__c || 0))},`;
        csv += `"${entry.Approval_Status__c || 'Draft'}"\n`;
    });

    csv += `\nWeek Total:,,,${data.totalRegularHours},${data.totalOvertimeHours},${data.totalHours}\n`;
    csv += `\nEmployee:,${data.employeeName}\n`;
    csv += `Week:,${data.weekNumber} - ${data.year}\n`;
    csv += `Export Date:,${data.exportDate}\n`;

   
    const blob = new Blob([csv], { type: '' }); // SIMPLIFY the content type

    const link = document.createElement('a');
    if ('download' in link) {
        const url = URL.createObjectURL(blob);
        link.setAttribute('href', url);
        link.setAttribute('download', `Timesheet_Week${data.weekNumber}_${data.year}.csv`);
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }
}

// Supporting utilities
formatDate(date) {
    return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}
getDayName(date) {
    const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    return days[date.getDay()];
}
showToast(title, message, variant) {
    this.dispatchEvent(
        new ShowToastEvent({ title, message, variant })
    );
}
  
getWeekStartDate(weekOffset) {
    const date = new Date();
    date.setDate(date.getDate() + (weekOffset * 7));
    // Find Monday for ISO week
    const day = date.getDay();
    const mondayOffset = day === 0 ? -6 : 1 - day;
    date.setDate(date.getDate() + mondayOffset);
    return date;
}
    formatDate(date) {
        const options = { month: 'short', day: 'numeric', year: 'numeric' };
        return date.toLocaleDateString('en-US', options);
    }

    getDayName(date) {
        const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        return days[date.getDay()];
    }

   
getWeekNumber(date) {
    // Copy date so changes don't affect original
    const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
    // Set to nearest Thursday: current date + 4 - day-of-week (ISO 8601)
    d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay()||7));
    const yearStart = new Date(Date.UTC(d.getUTCFullYear(),0,1));
    // Week number is the number of weeks between start of year and nearest Thursday
    return Math.ceil((((d - yearStart) / 86400000) + 1)/7);
}
    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}*/

/*import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import submitWeeklyEntriesForApproval from '@salesforce/apex/TimesheetController.submitWeeklyEntriesForApproval';
import checkWeeklySubmissionStatus from '@salesforce/apex/TimesheetController.checkWeeklySubmissionStatus';
import getWeeklyDataForExport from '@salesforce/apex/TimesheetController.getWeeklyDataForExport';
import getEntriesForWeek from '@salesforce/apex/TimesheetController.getEntriesForWeek';

export default class WeeklyTimesheetView extends LightningElement {
    _entries = [];
    weeklyEntries = [];
    wiredEntriesResult;
    useWireAdapter = true; // Flag to determine data source
    
    @track currentWeekOffset = 0;
    @track currentWeekNumber = 0;
    @track currentYear = new Date().getFullYear();
    @track isLoading = false;
    @track weeklySubmissionStatus = {
        hasEntries: false,
        canSubmit: false,
        allSubmitted: false,
        anySubmitted: false,
        entryCount: 0
    };

    // Wire adapter - only active when useWireAdapter is true
    @wire(getEntriesForWeek, { 
        weekNumber: '$currentWeekNumber', 
        year: '$currentYear' 
    })
    wiredEntriesHandler(result) {
        this.wiredEntriesResult = result;
        if (this.useWireAdapter) {
            if (result.data) {
                this._entries = result.data;
                this.processEntries();
            } else if (result.error) {
                console.error('Error loading entries:', result.error);
                this._entries = [];
                this.weeklyEntries = [];
            }
        }
    }

    // API property setter (for parent component passing data)
    @api
    set timesheetEntries(value) {
        this.useWireAdapter = false; // Disable wire adapter when using @api
        this._entries = value || [];
        this.filterWeek();
    }
    get timesheetEntries() { 
        return this.weeklyEntries; 
    }

    connectedCallback() {
        this.calculateCurrentWeek();
        this.checkSubmissionStatus();
    }

    // Calculate current week number and year
    calculateCurrentWeek() {
        const targetDate = new Date();
        targetDate.setDate(targetDate.getDate() + (this.currentWeekOffset * 7));
        this.currentWeekNumber = this.getWeekNumber(targetDate);
        this.currentYear = targetDate.getFullYear();
    }

    // Process entries into display format
    processEntries() {
        this.weeklyEntries = this._entries.map(entry => {
            const regular = entry.Regular_Hours__c || 0;
            const overtime = entry.Overtime_Hours__c || 0;
            const entryDate = new Date(entry.Date__c);
            
            return {
                id: entry.Id,
                date: this.formatDate(entryDate),
                day: this.getDayName(entryDate),
                project: entry.Project__r?.Name || '-',
                task: entry.Tasks__c || '-',
                hours: regular,
                overtime: overtime,
                totalHours: regular + overtime,
                status: entry.Status__c,
                approvalStatus: entry.Approval_Status__c || 'Draft',
                statusClass: this.getStatusClass(entry.Approval_Status__c)
            };
        }).sort((a, b) => new Date(a.date) - new Date(b.date));

        this.checkSubmissionStatus();
    }

    // For @api usage - filter entries by week
    filterWeek() {
        const targetDate = new Date();
        targetDate.setDate(targetDate.getDate() + (this.currentWeekOffset * 7));
        
        const week = this.getWeekNumber(targetDate);
        const year = targetDate.getFullYear();
        
        this.currentWeekNumber = week;
        this.currentYear = year;

        this.weeklyEntries = this._entries
            .filter(e => {
                const d = new Date(e.Date__c || e.date);
                return this.getWeekNumber(d) === week && d.getFullYear() === year;
            })
            .map(entry => {
                const regular = entry.Regular_Hours__c || entry.hours || 0;
                const overtime = entry.Overtime_Hours__c || entry.overtime || 0;
                const entryDate = new Date(entry.Date__c || entry.date);
                
                return {
                    id: entry.Id,
                    date: this.formatDate(entryDate),
                    day: this.getDayName(entryDate),
                    project: entry.Project__r?.Name || entry.project || '-',
                    task: entry.Tasks__c || entry.task || '-',
                    hours: regular,
                    overtime: overtime,
                    totalHours: regular + overtime,
                    status: entry.Status__c || entry.status,
                    approvalStatus: entry.Approval_Status__c || 'Draft',
                    statusClass: this.getStatusClass(entry.Approval_Status__c)
                };
            })
            .sort((a, b) => new Date(a.date) - new Date(b.date));

        this.checkSubmissionStatus();
    }

    // Get CSS class based on approval status
    getStatusClass(approvalStatus) {
        switch(approvalStatus) {
            case 'Approved':
                return 'status-approved';
            case 'Submitted':
                return 'status-submitted';
            case 'Rejected':
                return 'status-rejected';
            case 'Draft':
            default:
                return 'status-draft';
        }
    }

    // Check if there are weekly entries
    get hasWeeklyEntries() {
        return this.weeklyEntries && this.weeklyEntries.length > 0;
    }

    // Check if viewing current week
    get isCurrentWeek() {
        return this.currentWeekOffset === 0;
    }

    // Disable submit button based on status
    get disableSubmitButton() {
        return !this.weeklySubmissionStatus.canSubmit || 
               this.weeklyEntries.length === 0 ||
               this.isLoading;
    }

    // Get week start and end dates for display
    get weekStartDate() {
        const date = this.getWeekStartDate(this.currentWeekOffset);
        return this.formatDate(date);
    }

    get weekEndDate() {
        const startDate = this.getWeekStartDate(this.currentWeekOffset);
        const endDate = new Date(startDate);
        endDate.setDate(endDate.getDate() + 6);
        return this.formatDate(endDate);
    }

    // Calculate weekly totals
    get weekTotalHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.totalHours || 0), 0).toFixed(2);
    }

    get weekRegularHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.hours || 0), 0).toFixed(2);
    }

    get weekOvertimeHours() {
        return this.weeklyEntries.reduce((sum, entry) => sum + (entry.overtime || 0), 0).toFixed(2);
    }

    handlePrevWeek() {
        this.currentWeekOffset -= 1;
        if (this.useWireAdapter) {
            this.calculateCurrentWeek();
        } else {
            this.filterWeek();
        }
    }

    handleNextWeek() {
        if (!this.isCurrentWeek) {
            this.currentWeekOffset += 1;
            if (this.useWireAdapter) {
                this.calculateCurrentWeek();
            } else {
                this.filterWeek();
            }
        }
    }

    // Check submission status from server
    async checkSubmissionStatus() {
        try {
            const status = await checkWeeklySubmissionStatus({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });
            this.weeklySubmissionStatus = status;
        } catch (error) {
            console.error('Error checking submission status:', error);
        }
    }

    // Submit weekly entries for approval - FIXED VERSION
    async handleWeeklySubmitForApproval() {
        this.isLoading = true;
        try {
            const result = await submitWeeklyEntriesForApproval({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });
            
            this.showToast('Success', result.message, 'success');
             await this.forceReloadEntries();
            // Refresh data based on source
            if (this.useWireAdapter) {
                await refreshApex(this.wiredEntriesResult);
            } else {
                // If using @api, dispatch event to parent to refresh
                this.dispatchEvent(new CustomEvent('refreshentries'));
            }
            
            // Update submission status
            await this.checkSubmissionStatus();
            
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to submit timesheet', 'error');
        } finally {
            this.isLoading = false;
        }
    }
// Force reload entries with fresh data from server
    async forceReloadEntries() {
        try {
            // Make imperative call to bypass cache
            const freshEntries = await getEntriesForWeek({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });
            
            this._entries = freshEntries || [];
            
            if (this.useWireAdapter) {
                this.processEntries();
            } else {
                this.filterWeek();
            }
            
            console.log('Entries reloaded:', freshEntries.length);
        } catch (error) {
            console.error('Error reloading entries:', error);
        }
    }
    // Reliable Excel export handler
    async handleExportExcel() {
        this.isLoading = true;
        try {
            const data = await getWeeklyDataForExport({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });

            if (!data.entries || data.entries.length === 0) {
                this.showToast('Error', 'No entries found for this week', 'error');
                this.isLoading = false;
                return;
            }

            this.downloadCSV(data);
            this.showToast('Success', 'Excel file downloaded successfully', 'success');
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to export Excel', 'error');
            console.error('Export error:', error);
        }
        this.isLoading = false;
    }

    // Robust CSV download logic
    downloadCSV(data) {
        let csv = '\uFEFF'; // BOM for Excel
        csv += 'Date,Day,Project,Task,Regular Hours,Overtime Hours,Total Hours,Status\n';
        data.entries.forEach(entry => {
            const dateObj = new Date(entry.Date__c);
            csv += `"${this.formatDate(dateObj)}",`;
            csv += `"${this.getDayName(dateObj)}",`;
            csv += `"${entry.Project__r?.Name || '-'}",`;
            csv += `"${entry.Tasks__c || '-'}",`;
            csv += `${entry.Regular_Hours__c || 0},`;
            csv += `${entry.Overtime_Hours__c || 0},`;
            csv += `${entry.Total_Hours__c != null ? entry.Total_Hours__c : ((entry.Regular_Hours__c || 0) + (entry.Overtime_Hours__c || 0))},`;
            csv += `"${entry.Approval_Status__c || 'Draft'}"\n`;
        });

        csv += `\nWeek Total:,,,${data.totalRegularHours},${data.totalOvertimeHours},${data.totalHours}\n`;
        csv += `\nEmployee:,${data.employeeName}\n`;
        csv += `Week:,${data.weekNumber} - ${data.year}\n`;
        csv += `Export Date:,${data.exportDate}\n`;

        const blob = new Blob([csv], { type: 'text/csv' });
        const link = document.createElement('a');
        if ('download' in link) {
            const url = URL.createObjectURL(blob);
            link.setAttribute('href', url);
            link.setAttribute('download', `Timesheet_Week${data.weekNumber}_${data.year}.csv`);
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            URL.revokeObjectURL(url);
        }
    }

    // Supporting utilities
    getWeekStartDate(weekOffset) {
        const date = new Date();
        date.setDate(date.getDate() + (weekOffset * 7));
        // Find Monday for ISO week
        const day = date.getDay();
        const mondayOffset = day === 0 ? -6 : 1 - day;
        date.setDate(date.getDate() + mondayOffset);
        return date;
    }

    formatDate(date) {
        const options = { month: 'short', day: 'numeric', year: 'numeric' };
        return date.toLocaleDateString('en-US', options);
    }

    getDayName(date) {
        const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        return days[date.getDay()];
    }

    getWeekNumber(date) {
        // Copy date so changes don't affect original
        const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
        // Set to nearest Thursday: current date + 4 - day-of-week (ISO 8601)
        d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay()||7));
        const yearStart = new Date(Date.UTC(d.getUTCFullYear(),0,1));
        // Week number is the number of weeks between start of year and nearest Thursday
        return Math.ceil((((d - yearStart) / 86400000) + 1)/7);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}*/
import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningAlert from 'lightning/alert';
import { refreshApex } from '@salesforce/apex';
import submitWeeklyEntriesForApproval from '@salesforce/apex/TimesheetController.submitWeeklyEntriesForApproval';
import checkWeeklySubmissionStatus from '@salesforce/apex/TimesheetController.checkWeeklySubmissionStatus';
//import getWeeklyDataForExport from '@salesforce/apex/TimesheetController.getWeeklyDataForExport';
import getEntriesForWeek from '@salesforce/apex/TimesheetController.getEntriesForWeek';
import getPendingApprovals from '@salesforce/apex/TimesheetApprovalService.getPendingApprovals';

export default class WeeklyTimesheetView extends LightningElement {
    @track weeklyEntries = [];
    @track currentWeekOffset = 0;
    @track currentWeekNumber = 0;
    @track currentYear = new Date().getFullYear();
    @track isLoading = false;
    @track weeklySubmissionStatus = {
        hasEntries: false,
        canSubmit: false,
        allSubmitted: false,
        entryCount: 0
    };
    wiredEntriesResult;
    wiredStatusResult;

    @wire(getPendingApprovals)
    pendingApprovals;
    // Wire adapter to fetch entries for the current week
    @wire(getEntriesForWeek, {
        weekNumber: '$currentWeekNumber',
        year: '$currentYear'
    })
    wiredEntriesHandler(result) {
        this.wiredEntriesResult = result;
        if (result.data) {
            this.processEntries(result.data);
            // ✅ Fire AFTER weeklyEntries is ready
            Promise.resolve().then(() => {
                this.notifyWeekTotal();
            });
            // Wait for LWC reactivity to update currentWeekNumber
            setTimeout(() => {
                this.checkSubmissionStatus();
            }, 50);

        } else if (result.error) {
            console.error('Error loading entries:', result.error);
            this.weeklyEntries = [];
            this.showToast('Error', 'Failed to load timesheet entries', 'error');
        }
    }

    connectedCallback() {
        this.calculateCurrentWeek();
        this.getCurrentUserName();
    }

    // Calculate current week number and year based on offset
    calculateCurrentWeek() {
        const targetDate = new Date();
        targetDate.setDate(targetDate.getDate() + (this.currentWeekOffset * 7));

        // Use ISO logic for both Week and Year
        const d = new Date(Date.UTC(targetDate.getFullYear(), targetDate.getMonth(), targetDate.getDate()));
        d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));

        const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
        this.currentWeekNumber = Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
        this.currentYear = d.getUTCFullYear(); // Crucial: Use year of the Thursday
    }

    // Process entries into display format
    processEntries(entries) {
        this.weeklyEntries = entries.map(entry => {
            const regular = entry.Regular_Hours__c || 0;
            const overtime = entry.Overtime_Hours__c || 0;
            const entryDate = new Date(entry.Date__c);

            return {
                id: entry.Id,
                date: this.formatDate(entryDate),
                day: this.getDayName(entryDate),
                project: entry.Project__r ? (entry.Related_Project__r ? `${entry.Project__r.Name} (${entry.Related_Project__r.Name})` : entry.Project__r.Name) : '-',
                task: entry.Tasks__c || '-',
                description: entry.Description__c || '-',
                hours: regular,
                overtime: overtime,
                totalHours: regular + overtime,
                status: entry.Status__c,
                approvalStatus: entry.Approval_Status__c || 'Draft',
                statusClass: this.getStatusClass(entry.Approval_Status__c),
                isApproved: entry.Approval_Status__c === 'Approved' || entry.Approval_Status__c === 'WH Entry - Approved' || entry.Approval_Status__c === 'Submitted',
                rawEntry: entry // Keep original for editing
            };
        }).sort((a, b) => new Date(a.date) - new Date(b.date));
    }

    handleEditClick(event) {
        const entryId = event.target.value;
        const entry = this.weeklyEntries.find(e => e.id === entryId);
        if (entry) {
            this.dispatchEvent(new CustomEvent('editentry', {
                detail: { entry: entry.rawEntry }
            }));
        }
    }

    // Get CSS class based on approval status
    getStatusClass(approvalStatus) {
        switch (approvalStatus) {
            case 'Approved':
            case 'WH Entry - Approved':
                return 'status-approved';
            case 'Submitted':
                return 'status-submitted';
            case 'Rejected':
                return 'status-rejected';
            case 'Draft':
            default:
                return 'status-draft';
        }
    }

    // Computed properties
    get hasWeeklyEntries() {
        return this.weeklyEntries && this.weeklyEntries.length > 0;
    }

    get isCurrentWeek() {
        return this.currentWeekOffset === 0;
    }

    get disableSubmitButton() {
        return !this.weeklySubmissionStatus.canSubmit ||
            this.weeklyEntries.length === 0 ||
            this.isLoading;
    }

    // Count of entries NOT yet approved (will be sent to manager)
    get pendingEntriesCount() {
        return this.weeklyEntries.filter(e => e.approvalStatus !== 'Approved' && e.approvalStatus !== 'WH Entry - Approved').length;
    }

    // Count of entries already approved (will be skipped)
    get approvedEntriesCount() {
        return this.weeklyEntries.filter(e => e.approvalStatus === 'Approved' || e.approvalStatus === 'WH Entry - Approved').length;
    }

    // Show the info banner only when some entries are already approved
    get showApprovedBanner() {
        return this.approvedEntriesCount > 0 && this.pendingEntriesCount > 0;
    }

    get weekStartDate() {
        const date = this.getWeekStartDate(this.currentWeekOffset);
        return this.formatDate(date);
    }

    get weekEndDate() {
        const startDate = this.getWeekStartDate(this.currentWeekOffset);
        const endDate = new Date(startDate);
        endDate.setDate(endDate.getDate() + 6);
        return this.formatDate(endDate);
    }

    // Calculate accurate weekly totals based on aggregated daily rules (8h/day, 40h/week)
    get weekSummary() {
        if (!this.weeklyEntries || this.weeklyEntries.length === 0) {
            return { total: '0.00', regular: '0.00', overtime: '0.00' };
        }

        // 1. Group by date to handle split entries in a single day
        const dailyTotalsByDate = {};
        this.weeklyEntries.forEach(entry => {
            // Using rawEntry.Date__c for reliability as it's consistent YYYY-MM-DD
            const dateStr = entry.rawEntry?.Date__c || entry.date || '';
            if (dateStr) {
                if (!dailyTotalsByDate[dateStr]) dailyTotalsByDate[dateStr] = 0;
                dailyTotalsByDate[dateStr] += (entry.totalHours || 0);
            }
        });

        let totalWeeklyHours = 0;
        let totalCappedDailyHours = 0;

        // 2. Apply Daily Rule (cap regular hours at 8 per day across all entries on that day)
        for (const date in dailyTotalsByDate) {
            const daySum = dailyTotalsByDate[date];
            totalWeeklyHours += daySum;
            totalCappedDailyHours += Math.min(8, daySum);
        }

        // 3. Apply Weekly Rule (cap regular hours at 40 per week)
        const finalRegular = Math.min(40, totalCappedDailyHours);
        const finalOvertime = Math.max(0, totalWeeklyHours - finalRegular);

        return {
            total: totalWeeklyHours.toFixed(2),
            regular: finalRegular.toFixed(2),
            overtime: finalOvertime.toFixed(2)
        };
    }

    // Calculate weekly totals (displayed in HTML)
    get weekTotalHours() {
        return this.weekSummary.total;
    }

    get weekRegularHours() {
        return this.weekSummary.regular;
    }

    get weekOvertimeHours() {
        return this.weekSummary.overtime;
    }

    // Navigation handlers
    handlePrevWeek() {
        this.currentWeekOffset -= 1;
        this.calculateCurrentWeek();
        Promise.resolve().then(() => {
            this.notifyWeekTotal();
        });

        setTimeout(() => {
            this.checkSubmissionStatus();
        }, 50);
    }

    handleNextWeek() {
        if (!this.isCurrentWeek) {
            this.currentWeekOffset += 1;
            this.calculateCurrentWeek();
            Promise.resolve().then(() => {
                this.notifyWeekTotal();
            });

            setTimeout(() => {
                this.checkSubmissionStatus();
            }, 50);
        }
    }

    // Check submission status from server
    async checkSubmissionStatus() {
        try {
            const status = await checkWeeklySubmissionStatus({
                weekNumber: Number(this.currentWeekNumber),
                year: Number(this.currentYear)
            });
            this.weeklySubmissionStatus = status;
        } catch (error) {
            console.error('Error checking submission status:', error);
        }
    }

    // Submit weekly entries for approval
    async handleWeeklySubmitForApproval() {
        console.log('=== SUBMIT STARTED ===');
        console.log('Week:', this.currentWeekNumber, 'Year:', this.currentYear);
        this.isLoading = true;
        try {
            const result = await submitWeeklyEntriesForApproval({
                weekNumber: this.currentWeekNumber,
                year: this.currentYear
            });

            // Build an informative message using the enriched response
            let message;
            if (result.alreadyApprovedCount > 0) {
                message = `${result.pendingCount} entr(ies) sent to ${result.managerName || 'your manager'} for approval. ` +
                          `${result.alreadyApprovedCount} already-approved entr(ies) were skipped.`;
            } else {
                message = result.message ||
                    `Timesheet submitted successfully to ${result.managerName || 'your manager'}`;
            }
            await this.showToast('Success', message, 'success');

            // Refresh the entries to show updated approval status
            console.log('Refreshing entries...');
            await refreshApex(this.wiredEntriesResult);
            await this.delay(200);

            setTimeout(() => {
                this.checkSubmissionStatus();
            }, 100);
            await this.checkSubmissionStatus();

            // Notify parent component to refresh
            this.dispatchEvent(new CustomEvent('refreshentries'));
            console.log('=== SUBMIT COMPLETED ===');
        } catch (error) {
            console.error('=== SUBMIT FAILED ===');
            console.error('Error details:', error);
            const errorMsg = error.body?.message || 'Failed to submit timesheet for approval';
            await this.showToast('Error', errorMsg, 'error');
        } finally {
            this.isLoading = false;
        }
    }
    // Helper function to create delays
    delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
    handleExportExcel() {
        console.log('=== Starting Enhanced Excel Export ===');
        this.isLoading = true;

        try {
            if (!this.weeklyEntries || this.weeklyEntries.length === 0) {
                this.showToast('Warning', 'No entries found for this week', 'warning');
                return;
            }

            // 1. Calculate project-wise breakdown and totals
            const projectSummaryMap = {};
            let grandRegular = 0;
            let grandOvertime = 0;
            let grandTotal = 0;

            this.weeklyEntries.forEach(entry => {
                const projName = entry.project || 'Unassigned';
                const reg = parseFloat(entry.hours) || 0;
                const ot = parseFloat(entry.overtime) || 0;
                const tot = parseFloat(entry.totalHours) || (reg + ot);

                grandRegular += reg;
                grandOvertime += ot;
                grandTotal += tot;

                if (!projectSummaryMap[projName]) {
                    projectSummaryMap[projName] = { regular: 0, overtime: 0, total: 0 };
                }
                projectSummaryMap[projName].regular += reg;
                projectSummaryMap[projName].overtime += ot;
                projectSummaryMap[projName].total += tot;
            });

            // 2. Build rows for main timesheet table
            let rowsHtml = '';
            this.weeklyEntries.forEach((entry, index) => {
                const isZebra = index % 2 === 1;
                const rowBg = isZebra ? '#F8FAFC' : '#FFFFFF';
                const status = entry.approvalStatus || 'Draft';
                
                let statusBg = '#F3F4F6';
                let statusColor = '#374151';
                if (status === 'Approved' || status === 'WH Entry - Approved') {
                    statusBg = '#DCFCE7';
                    statusColor = '#166534';
                } else if (status === 'Submitted') {
                    statusBg = '#DBEAFE';
                    statusColor = '#1E40AF';
                } else if (status === 'Rejected') {
                    statusBg = '#FEE2E2';
                    statusColor = '#991B1B';
                }

                rowsHtml += `
                <tr style="height: 26px;">
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: center; padding: 6px; font-size: 10pt; mso-number-format: '\\@';">${entry.date || '-'}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: center; padding: 6px; font-size: 10pt;">${entry.day || '-'}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: left; padding: 6px; font-size: 10pt; font-weight: 600; color: #0F172A;">${entry.project || '-'}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: left; padding: 6px; font-size: 10pt; color: #334155;">${entry.task || '-'}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: right; padding: 6px; font-size: 10pt; mso-number-format: '0\\.00';">${(entry.hours || 0).toFixed(2)}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: right; padding: 6px; font-size: 10pt; mso-number-format: '0\\.00';">${(entry.overtime || 0).toFixed(2)}</td>
                    <td style="background-color: ${rowBg}; border: 1px solid #CBD5E1; text-align: right; padding: 6px; font-size: 10pt; font-weight: 600; color: #0176D3; mso-number-format: '0\\.00';">${(entry.totalHours || 0).toFixed(2)}</td>
                    <td style="border: 1px solid #CBD5E1; text-align: center; padding: 6px; font-size: 9.5pt; font-weight: bold; background-color: ${statusBg}; color: ${statusColor};">${status}</td>
                </tr>`;
            });

            // 3. Build Project Summary Rows
            let projectRowsHtml = '';
            for (const proj in projectSummaryMap) {
                const p = projectSummaryMap[proj];
                const pct = grandTotal > 0 ? ((p.total / grandTotal) * 100).toFixed(1) : '0.0';
                projectRowsHtml += `
                <tr style="height: 24px;">
                    <td colspan="3" style="background-color: #FFFFFF; border: 1px solid #CBD5E1; text-align: left; padding: 5px; font-size: 9.5pt; font-weight: 600; color: #1E293B;">${proj}</td>
                    <td style="background-color: #FFFFFF; border: 1px solid #CBD5E1; text-align: right; padding: 5px; font-size: 9.5pt; mso-number-format: '0\\.00';">${p.regular.toFixed(2)}</td>
                    <td style="background-color: #FFFFFF; border: 1px solid #CBD5E1; text-align: right; padding: 5px; font-size: 9.5pt; mso-number-format: '0\\.00';">${p.overtime.toFixed(2)}</td>
                    <td style="background-color: #FFFFFF; border: 1px solid #CBD5E1; text-align: right; padding: 5px; font-size: 9.5pt; font-weight: bold; mso-number-format: '0\\.00';">${p.total.toFixed(2)}</td>
                    <td colspan="2" style="background-color: #FFFFFF; border: 1px solid #CBD5E1; text-align: center; padding: 5px; font-size: 9.5pt; color: #64748B;">${pct}%</td>
                </tr>`;
            }

            const exportDateTime = new Date().toLocaleString('en-US', {
                dateStyle: 'medium',
                timeStyle: 'short'
            });

            // 4. Construct complete XML/HTML Excel document
            const excelTemplate = `
            <html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns="http://www.w3.org/TR/REC-html40">
            <head>
                <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
                <!--[if gte mso 9]>
                <xml>
                    <x:ExcelWorkbook>
                        <x:ExcelWorksheets>
                            <x:ExcelWorksheet>
                                <x:Name>Weekly Timesheet</x:Name>
                                <x:WorksheetOptions>
                                    <x:DisplayGridlines/>
                                </x:WorksheetOptions>
                            </x:ExcelWorksheet>
                        </x:ExcelWorksheets>
                    </x:ExcelWorkbook>
                </xml>
                <![endif]-->
                <style>
                    body { font-family: 'Segoe UI', Calibri, Arial, sans-serif; font-size: 10pt; color: #1E293B; }
                    table { border-collapse: collapse; }
                </style>
            </head>
            <body>
                <table>
                    <col width="110">
                    <col width="100">
                    <col width="220">
                    <col width="300">
                    <col width="110">
                    <col width="110">
                    <col width="110">
                    <col width="130">
                    
                    <!-- Corporate Header Banner -->
                    <tr style="height: 38px;">
                        <td colspan="8" style="background-color: #014486; color: #FFFFFF; font-size: 15pt; font-weight: bold; text-align: center; vertical-align: middle; border: 1px solid #014486;">
                            QUADROBAY TECHNOLOGIES - TIMESHEET REPORT
                        </td>
                    </tr>
                    <tr style="height: 24px;">
                        <td colspan="8" style="background-color: #0176D3; color: #FFFFFF; font-size: 11pt; font-weight: 600; text-align: center; vertical-align: middle; border: 1px solid #0176D3;">
                            Weekly Timesheet: Week ${this.currentWeekNumber}, ${this.currentYear} (${this.weekStartDate} - ${this.weekEndDate})
                        </td>
                    </tr>
                    
                    <!-- Blank separator -->
                    <tr style="height: 12px;"><td colspan="8"></td></tr>

                    <!-- Metadata Section Card -->
                    <tr style="height: 24px;">
                        <td colspan="2" style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Total Regular Hours:</td>
                        <td style="background-color: #FFFFFF; font-weight: bold; color: #0F172A; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.weekRegularHours).toFixed(2)} hrs</td>
                        <td style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Total Overtime Hours:</td>
                        <td style="background-color: #FFFFFF; font-weight: bold; color: #D97706; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.weekOvertimeHours).toFixed(2)} hrs</td>
                        <td colspan="2" style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Grand Total Hours:</td>
                        <td style="background-color: #EFF6FF; font-weight: bold; color: #0176D3; font-size: 11pt; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.weekTotalHours).toFixed(2)} hrs</td>
                    </tr>
                    <tr style="height: 24px;">
                        <td colspan="2" style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Export Timestamp:</td>
                        <td colspan="6" style="background-color: #FFFFFF; color: #64748B; border: 1px solid #CBD5E1; padding: 6px;">${exportDateTime}</td>
                    </tr>

                    <!-- Blank separator -->
                    <tr style="height: 16px;"><td colspan="8"></td></tr>

                    <!-- Main Data Table Headers -->
                    <tr style="height: 30px;">
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 110px;">Date</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 100px;">Day</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: left; width: 220px;">Project</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: left; width: 300px;">Task Description</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 110px;">Regular (h)</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 110px;">Overtime (h)</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 110px;">Total (h)</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 130px;">Approval Status</th>
                    </tr>

                    <!-- Data Rows -->
                    ${rowsHtml}

                    <!-- Total Summary Row -->
                    <tr style="height: 30px; font-weight: bold;">
                        <td colspan="4" style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #0F172A; text-transform: uppercase;">
                            Total Weekly Hours:
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #0F172A; mso-number-format: '0\\.00';">
                            ${parseFloat(this.weekRegularHours).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #D97706; mso-number-format: '0\\.00';">
                            ${parseFloat(this.weekOvertimeHours).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 11pt; text-align: right; color: #0176D3; mso-number-format: '0\\.00';">
                            ${parseFloat(this.weekTotalHours).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; text-align: center; color: #64748B;">-</td>
                    </tr>

                    <!-- Blank separator -->
                    <tr style="height: 20px;"><td colspan="8"></td></tr>

                    <!-- Project-Wise Breakdown Header -->
                    <tr style="height: 26px;">
                        <th colspan="3" style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: left;">Project-wise Breakdown</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Regular (h)</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Overtime (h)</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Total Hours</th>
                        <th colspan="2" style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: center;">% Allocation</th>
                    </tr>
                    ${projectRowsHtml}
                </table>
            </body>
            </html>`;

            const filename = `Timesheet_Week${this.currentWeekNumber}_${this.currentYear}.xls`;
            const dataUri = 'data:application/vnd.ms-excel;charset=utf-8,' + encodeURIComponent(excelTemplate);

            const link = document.createElement('a');
            link.setAttribute('href', dataUri);
            link.setAttribute('download', filename);
            link.style.display = 'none';

            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);

            console.log('=== Enhanced Excel Export Completed Successfully ===');
            this.showToast('Success', 'Timesheet Excel report downloaded successfully', 'success');

        } catch (error) {
            console.error('=== Export Failed ===');
            console.error('Error:', error);

            this.showToast('Error', 'Failed to export: ' + error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }



    // Get current user name
    getCurrentUserName() {
        // This will be available from the component context
        // If not, it will show as 'Unknown' in export
        try {
            this.currentUserName = this.weeklyEntries[0]?.CreatedBy?.Name || 'Employee';
        } catch (e) {
            this.currentUserName = 'Employee';
        }
    }
    // Utility methods
    getWeekStartDate(weekOffset) {
        const date = new Date();
        date.setDate(date.getDate() + (weekOffset * 7));
        // Find Monday (ISO week start)
        const day = date.getDay();
        const mondayOffset = day === 0 ? -6 : 1 - day;
        date.setDate(date.getDate() + mondayOffset);
        return date;
    }

    formatDate(date) {
        const options = { month: 'short', day: 'numeric', year: 'numeric' };
        return date.toLocaleDateString('en-US', options);
    }

    getDayName(date) {
        const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
        return days[date.getDay()];
    }

    getWeekNumber(date) {
        // ISO 8601 week number calculation
        const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
        d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
        const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
        return Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
    }
    notifyWeekTotal() {
        console.log('Dispatching week total:', this.weekTotalHours);
        this.dispatchEvent(
            new CustomEvent('weektotalupdate', {
                detail: {
                    weekTotalHours: this.weekTotalHours,
                    overtimeHours: this.weekOvertimeHours
                },
                bubbles: true,
                composed: true
            })
        );
    }

    async showToast(title, message, variant) {
        // Use LightningAlert for Experience Site compatibility
        await LightningAlert.open({
            message: message,
            theme: variant, // success | error | warning | info
            label: title
        });
    }
}