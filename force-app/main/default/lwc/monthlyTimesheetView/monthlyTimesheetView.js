/*import { LightningElement, api } from 'lwc';

export default class MonthlyTimesheetView extends LightningElement {
    @api timesheetEntries = [];

    handleViewDetails(event) {
        const id = event.target.dataset.id;
        // Fire custom event to parent
        this.dispatchEvent(new CustomEvent('viewdetails', { detail: id }));
    }

    // Helper for status CSS
    get statusClass() {
        return (status) => status === 'Approved' ? 'status-approved' : status === 'Pending' ? 'status-pending' : '';
    }
}*/
/*import { LightningElement, api } from 'lwc';

export default class MonthlyTimesheetView extends LightningElement {
    _allEntries = [];
    monthlyWeeks = [];

  @api
set timesheetEntries(value) {
    this._allEntries = value || [];
    this.processMonthlyWeeks();
}
        get timesheetEntries() {
        return this.monthlyWeeks;
    }
    

getAggregatedApprovalStatus(entries) {
    if (entries.some(e => e.approvalStatus === 'Rejected' || e.Approval_Status__c === 'Rejected')) return 'Rejected';
    if (entries.some(e => e.approvalStatus === 'Submitted' || e.Approval_Status__c === 'Submitted')) return 'Submitted';
    if (entries.some(e => e.approvalStatus === 'Approved' || e.Approval_Status__c === 'Approved')) return 'Approved';
    return 'Draft';
}
    processMonthlyWeeks() {
        // Get current month/year
        const now = new Date();
        const month = now.getMonth();
        const year = now.getFullYear();

        // Group by week number { week: { ... } }
        const weeksMap = {};
        for (const e of this._allEntries) {
            // Accept both date and Date__c
            const dateStr = e.date || e.Date__c;
            if (!dateStr) continue;
            const d = new Date(dateStr);

            if (d.getMonth() === month && d.getFullYear() === year) {
                const week = this.getWeekNumber(d);
                if (!weeksMap[week]) {
                    weeksMap[week] = {
                        id: `${year}-W${week}`,
                        weekLabel: `Week ${week}`,
                        regularHours: 0,
                        overtimeHours: 0,
                        totalHours: 0,
                        approvalStatus: '', // Will be filled after
                    approvalStatusClass: ''
                    };
                }
                weeksMap[week].regularHours += e.hours || e.Regular_Hours__c || 0;
                weeksMap[week].overtimeHours += e.overtime || e.Overtime_Hours__c || 0;
                weeksMap[week].totalHours += e.totalHours || e.Total_Hours__c ||
                    ((e.hours || e.Regular_Hours__c || 0) + (e.overtime || e.Overtime_Hours__c || 0));
                
            }
        }
       
// Aggregate approvalStatus (after collecting all weekly entries)
    Object.keys(weeksMap).forEach(week => {
        // Get all entries for this week in the month/year
        const entriesForWeek = this._allEntries.filter(entry => {
            const d = new Date(entry.date || entry.Date__c);
            return d.getMonth() === month && d.getFullYear() === year && this.getWeekNumber(d) === Number(week);
        });
        weeksMap[week].approvalStatus = this.getAggregatedApprovalStatus(entriesForWeek);

        // Optional: Style class for coloring
        weeksMap[week].approvalStatusClass =
            weeksMap[week].approvalStatus === 'Approved'
                ? 'approval-approved'
                : weeksMap[week].approvalStatus === 'Submitted'
                    ? 'approval-submitted'
                    : weeksMap[week].approvalStatus === 'Rejected'
                        ? 'approval-rejected'
                        : 'approval-draft';
    });
        // Sort by week ascending
        this.monthlyWeeks = Object.values(weeksMap).sort((a, b) => a.weekLabel.localeCompare(b.weekLabel));
    }

    getWeekNumber(d) {
        d = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
        d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay()||7));
        const yearStart = new Date(Date.UTC(d.getUTCFullYear(),0,1));
        return Math.ceil((((d - yearStart) / 86400000) + 1)/7);
    }


    handleViewDetails(event) {
        const id = event.target.dataset.id;
        this.dispatchEvent(new CustomEvent('viewdetails', { detail: id }));
    }
}*/
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class MonthlyTimesheetView extends LightningElement {
    @track _allEntries = [];
    @track monthlyWeeks = [];
    @track currentMonthOffset = 0;
    @track isLoading = false;

    @api
    set timesheetEntries(value) {
        this._allEntries = value || [];
        this.processMonthlyWeeks();
    }
    get timesheetEntries() {
        return this._allEntries;
    }

    // Get current month and year based on offset
    get currentDate() {
        const date = new Date();
        date.setMonth(date.getMonth() + this.currentMonthOffset);
        return date;
    }

    get currentMonth() {
        return this.currentDate.getMonth();
    }

    get currentYear() {
        return this.currentDate.getFullYear();
    }

    get monthDisplay() {
        const options = { month: 'long', year: 'numeric' };
        return this.currentDate.toLocaleDateString('en-US', options);
    }

    get isCurrentMonth() {
        return this.currentMonthOffset === 0;
    }

    get hasMonthlyData() {
        return this.monthlyWeeks && this.monthlyWeeks.length > 0;
    }

    // Calculate totals for the month
    get monthlyTotalRegular() {
        return this.monthlyWeeks.reduce((sum, week) => sum + (week.regularHours || 0), 0).toFixed(2);
    }

    get monthlyTotalOvertime() {
        return this.monthlyWeeks.reduce((sum, week) => sum + (week.overtimeHours || 0), 0).toFixed(2);
    }

    get monthlyTotalHours() {
        return this.monthlyWeeks.reduce((sum, week) => sum + (week.totalHours || 0), 0).toFixed(2);
    }

    // Process entries into weekly summaries
    processMonthlyWeeks() {
        const month = this.currentMonth;
        const year = this.currentYear;

        const weeksMap = {};

        for (const entry of this._allEntries) {
            const dateStr = entry.date || entry.Date__c;
            if (!dateStr) continue;

            const entryDate = new Date(dateStr);
            
            // Only process entries for current month/year
            if (entryDate.getMonth() === month && entryDate.getFullYear() === year) {
                const weekNum = this.getWeekNumber(entryDate);
                const weekKey = `${year}-W${weekNum}`;

                if (!weeksMap[weekKey]) {
                    weeksMap[weekKey] = {
                        id: weekKey,
                        weekNumber: weekNum,
                        weekLabel: `Week ${weekNum}`,
                        weekDateRange: this.getWeekDateRange(weekNum, year),
                        regularHours: 0,
                        overtimeHours: 0,
                        totalHours: 0,
                        entries: []
                    };
                }

                // Add to totals
                const regular = entry.hours || entry.Regular_Hours__c || 0;
                const overtime = entry.overtime || entry.Overtime_Hours__c || 0;

                weeksMap[weekKey].regularHours += regular;
                weeksMap[weekKey].overtimeHours += overtime;
                weeksMap[weekKey].totalHours += regular + overtime;
                weeksMap[weekKey].entries.push(entry);
            }
        }

        // Aggregate approval status for each week
        Object.keys(weeksMap).forEach(weekKey => {
            const week = weeksMap[weekKey];
            week.approvalStatus = this.getAggregatedApprovalStatus(week.entries);
            week.approvalStatusClass = this.getApprovalStatusClass(week.approvalStatus);
            
            // Round hours
            week.regularHours = parseFloat(week.regularHours.toFixed(2));
            week.overtimeHours = parseFloat(week.overtimeHours.toFixed(2));
            week.totalHours = parseFloat(week.totalHours.toFixed(2));
        });

        // Sort by week number
        this.monthlyWeeks = Object.values(weeksMap).sort((a, b) => a.weekNumber - b.weekNumber);
    }

    // Get aggregated approval status for a week
    getAggregatedApprovalStatus(entries) {
        if (!entries || entries.length === 0) return 'Draft';

        const statuses = entries.map(e => e.approvalStatus || e.Approval_Status__c || 'Draft');

        if (statuses.some(s => s === 'Rejected')) return 'Rejected';
        if (statuses.some(s => s === 'Submitted')) return 'Submitted';
        if (statuses.every(s => s === 'Approved')) return 'Approved';
        
        return 'Draft';
    }

    // Get CSS class for approval status
    getApprovalStatusClass(status) {
        switch(status) {
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

    // Get week date range string
    getWeekDateRange(weekNum, year) {
        const weekStart = this.getWeekStartDate(weekNum, year);
        const weekEnd = new Date(weekStart);
        weekEnd.setDate(weekEnd.getDate() + 6);

        return `${this.formatDate(weekStart)} - ${this.formatDate(weekEnd)}`;
    }

    // Get Monday of a given week
    getWeekStartDate(weekNum, year) {
        const jan4 = new Date(year, 0, 4);
        const firstMonday = new Date(jan4);
        firstMonday.setDate(jan4.getDate() - (jan4.getDay() || 7) + 1);
        
        const targetDate = new Date(firstMonday);
        targetDate.setDate(firstMonday.getDate() + (weekNum - 1) * 7);
        
        return targetDate;
    }

    // Calculate ISO week number
    getWeekNumber(date) {
        const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
        d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
        const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
        return Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
    }

    // Format date for display
    formatDate(date) {
        const options = { month: 'short', day: 'numeric' };
        return date.toLocaleDateString('en-US', options);
    }

    // Navigation handlers
    handlePrevMonth() {
        this.currentMonthOffset -= 1;
        this.processMonthlyWeeks();
    }

    handleNextMonth() {
        if (!this.isCurrentMonth) {
            this.currentMonthOffset += 1;
            this.processMonthlyWeeks();
        }
    }

    // View week details
    /*handleViewDetails(event) {
        const weekId = event.target.dataset.id;
        const week = this.monthlyWeeks.find(w => w.id === weekId);
        
        if (week) {
            this.dispatchEvent(new CustomEvent('viewweekdetails', { 
                detail: { 
                    weekNumber: week.weekNumber,
                    year: this.currentYear,
                    weekLabel: week.weekLabel
                }
            }));
        }
    }*/
handleViewDetails(event) {
        const id = event.target.dataset.id;
        this.dispatchEvent(new CustomEvent('viewdetails', { detail: id }));
    }
    // Export to Excel (.xls XML/HTML format with styling)
    handleExportExcel() {
        console.log('=== Starting Enhanced Monthly Excel Export ===');
        this.isLoading = true;

        try {
            if (!this.monthlyWeeks || this.monthlyWeeks.length === 0) {
                this.showToast('Warning', 'No entries found for this month', 'warning');
                this.isLoading = false;
                return;
            }

            const exportDateTime = new Date().toLocaleString('en-US', {
                month: 'short',
                day: 'numeric',
                year: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                hour12: true
            });

            // Calculate Project breakdown across all entries in the month
            const projectTotals = {};
            let totalMonthHoursNum = 0;

            this.monthlyWeeks.forEach(week => {
                if (week.entries && Array.isArray(week.entries)) {
                    week.entries.forEach(entry => {
                        const projName = entry.Project__r?.Name || entry.project || entry.Project_Name__c || 'General Tasks';
                        const reg = parseFloat(entry.Regular_Hours__c || entry.hours || 0);
                        const ot = parseFloat(entry.Overtime_Hours__c || entry.overtime || 0);
                        const tot = parseFloat(entry.Total_Hours__c || (reg + ot));

                        if (!projectTotals[projName]) {
                            projectTotals[projName] = { regular: 0, overtime: 0, total: 0 };
                        }
                        projectTotals[projName].regular += reg;
                        projectTotals[projName].overtime += ot;
                        projectTotals[projName].total += tot;
                        totalMonthHoursNum += tot;
                    });
                }
            });

            // Generate weekly table rows
            let rowsHtml = '';
            this.monthlyWeeks.forEach((week, index) => {
                const bg = index % 2 === 0 ? '#FFFFFF' : '#F8FAFC';
                const status = week.approvalStatus || 'Draft';
                let statusBg = '#F1F5F9';
                let statusColor = '#475569';

                if (status === 'Approved') {
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
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: center; font-weight: bold; color: #1E293B;">
                            ${week.weekLabel || 'Week ' + week.weekNumber}
                        </td>
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: center; color: #334155;">
                            ${week.weekDateRange || '-'}
                        </td>
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; color: #1E293B; mso-number-format: '0\\.00';">
                            ${(week.regularHours || 0).toFixed(2)}
                        </td>
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; color: #D97706; mso-number-format: '0\\.00';">
                            ${(week.overtimeHours || 0).toFixed(2)}
                        </td>
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; font-weight: bold; color: #0176D3; mso-number-format: '0\\.00';">
                            ${(week.totalHours || 0).toFixed(2)}
                        </td>
                        <td style="background-color: ${bg}; border: 1px solid #CBD5E1; padding: 6px; text-align: center;">
                            <span style="background-color: ${statusBg}; color: ${statusColor}; font-weight: bold; padding: 3px 8px; border-radius: 4px; font-size: 9pt;">
                                ${status}
                            </span>
                        </td>
                    </tr>
                `;
            });

            // Generate Project breakdown rows
            let projectRowsHtml = '';
            const projectKeys = Object.keys(projectTotals);
            if (projectKeys.length > 0) {
                projectKeys.forEach((pName, pIndex) => {
                    const pBg = pIndex % 2 === 0 ? '#FFFFFF' : '#F8FAFC';
                    const p = projectTotals[pName];
                    const pct = totalMonthHoursNum > 0 ? ((p.total / totalMonthHoursNum) * 100).toFixed(1) : '0.0';
                    projectRowsHtml += `
                        <tr style="height: 24px;">
                            <td colspan="2" style="background-color: ${pBg}; border: 1px solid #CBD5E1; padding: 6px; font-weight: 500; color: #1E293B;">
                                ${pName}
                            </td>
                            <td style="background-color: ${pBg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; color: #1E293B; mso-number-format: '0\\.00';">
                                ${p.regular.toFixed(2)}
                            </td>
                            <td style="background-color: ${pBg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; color: #D97706; mso-number-format: '0\\.00';">
                                ${p.overtime.toFixed(2)}
                            </td>
                            <td style="background-color: ${pBg}; border: 1px solid #CBD5E1; padding: 6px; text-align: right; font-weight: bold; color: #0176D3; mso-number-format: '0\\.00';">
                                ${p.total.toFixed(2)}
                            </td>
                            <td style="background-color: ${pBg}; border: 1px solid #CBD5E1; padding: 6px; text-align: center; font-weight: bold; color: #475569;">
                                ${pct}%
                            </td>
                        </tr>
                    `;
                });
            } else {
                projectRowsHtml = `
                    <tr style="height: 24px;">
                        <td colspan="6" style="background-color: #FFFFFF; border: 1px solid #CBD5E1; padding: 6px; text-align: center; color: #64748B;">
                            No project breakdown available
                        </td>
                    </tr>
                `;
            }

            const excelTemplate = `
            <html xmlns:o="urn:schemas-microsoft-com:office:office"
                  xmlns:x="urn:schemas-microsoft-com:office:excel"
                  xmlns="http://www.w3.org/TR/REC-html40">
            <head>
                <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
                <!--[if gte mso 9]>
                <xml>
                    <x:ExcelWorkbook>
                        <x:ExcelWorksheets>
                            <x:ExcelWorksheet>
                                <x:Name>Monthly Timesheet</x:Name>
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
                    <col width="130">
                    <col width="220">
                    <col width="130">
                    <col width="130">
                    <col width="130">
                    <col width="140">
                    
                    <!-- Corporate Header Banner -->
                    <tr style="height: 38px;">
                        <td colspan="6" style="background-color: #014486; color: #FFFFFF; font-size: 15pt; font-weight: bold; text-align: center; vertical-align: middle; border: 1px solid #014486;">
                            QUADROBAY TECHNOLOGIES - MONTHLY TIMESHEET REPORT
                        </td>
                    </tr>
                    <tr style="height: 24px;">
                        <td colspan="6" style="background-color: #0176D3; color: #FFFFFF; font-size: 11pt; font-weight: 600; text-align: center; vertical-align: middle; border: 1px solid #0176D3;">
                            Monthly Summary: ${this.monthDisplay}
                        </td>
                    </tr>
                    
                    <!-- Blank separator -->
                    <tr style="height: 12px;"><td colspan="6"></td></tr>

                    <!-- Metadata Section Card -->
                    <tr style="height: 24px;">
                        <td style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Total Regular:</td>
                        <td style="background-color: #FFFFFF; font-weight: bold; color: #0F172A; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.monthlyTotalRegular).toFixed(2)} hrs</td>
                        <td style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Total Overtime:</td>
                        <td style="background-color: #FFFFFF; font-weight: bold; color: #D97706; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.monthlyTotalOvertime).toFixed(2)} hrs</td>
                        <td style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Grand Total:</td>
                        <td style="background-color: #EFF6FF; font-weight: bold; color: #0176D3; font-size: 11pt; border: 1px solid #CBD5E1; padding: 6px; text-align: right; mso-number-format: '0\\.00';">${parseFloat(this.monthlyTotalHours).toFixed(2)} hrs</td>
                    </tr>
                    <tr style="height: 24px;">
                        <td style="background-color: #F1F5F9; font-weight: bold; color: #475569; border: 1px solid #CBD5E1; padding: 6px;">Export Date:</td>
                        <td colspan="5" style="background-color: #FFFFFF; color: #64748B; border: 1px solid #CBD5E1; padding: 6px;">${exportDateTime}</td>
                    </tr>

                    <!-- Blank separator -->
                    <tr style="height: 16px;"><td colspan="6"></td></tr>

                    <!-- Main Data Table Headers -->
                    <tr style="height: 30px;">
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 130px;">Week</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 220px;">Date Range</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 130px;">Regular (h)</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 130px;">Overtime (h)</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: right; width: 130px;">Total Hours</th>
                        <th style="background-color: #1E293B; color: #FFFFFF; border: 1px solid #334155; padding: 8px; font-weight: bold; text-align: center; width: 140px;">Approval Status</th>
                    </tr>

                    <!-- Data Rows -->
                    ${rowsHtml}

                    <!-- Total Summary Row -->
                    <tr style="height: 30px; font-weight: bold;">
                        <td colspan="2" style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #0F172A; text-transform: uppercase;">
                            MONTH TOTALS:
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #0F172A; mso-number-format: '0\\.00';">
                            ${parseFloat(this.monthlyTotalRegular).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 10pt; text-align: right; color: #D97706; mso-number-format: '0\\.00';">
                            ${parseFloat(this.monthlyTotalOvertime).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; font-size: 11pt; text-align: right; color: #0176D3; mso-number-format: '0\\.00';">
                            ${parseFloat(this.monthlyTotalHours).toFixed(2)}
                        </td>
                        <td style="background-color: #E2E8F0; border: 1px solid #94A3B8; padding: 6px; text-align: center; color: #64748B;">-</td>
                    </tr>

                    <!-- Blank separator -->
                    <tr style="height: 20px;"><td colspan="6"></td></tr>

                    <!-- Project-Wise Breakdown Header -->
                    <tr style="height: 26px;">
                        <th colspan="2" style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: left;">Monthly Project Breakdown</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Regular (h)</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Overtime (h)</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: right;">Total Hours</th>
                        <th style="background-color: #334155; color: #FFFFFF; border: 1px solid #475569; padding: 6px; font-weight: bold; text-align: center;">% Allocation</th>
                    </tr>
                    ${projectRowsHtml}
                </table>
            </body>
            </html>`;

            const monthName = this.currentDate.toLocaleDateString('en-US', { month: 'long' });
            const filename = `Timesheet_${monthName}_${this.currentYear}.xls`;
            const dataUri = 'data:application/vnd.ms-excel;charset=utf-8,' + encodeURIComponent(excelTemplate);

            const link = document.createElement('a');
            link.setAttribute('href', dataUri);
            link.setAttribute('download', filename);
            link.style.display = 'none';

            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);

            console.log('=== Monthly Enhanced Excel Export Completed Successfully ===');
            this.showToast('Success', 'Monthly timesheet Excel report downloaded successfully', 'success');

        } catch (error) {
            console.error('=== Monthly Export Failed ===');
            console.error('Error:', error);
            this.showToast('Error', 'Failed to export: ' + error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Show toast notification
    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant,
                mode: 'dismissable'
            })
        );
    }
}