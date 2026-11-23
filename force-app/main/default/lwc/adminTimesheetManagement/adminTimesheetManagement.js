import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getDashboardStats from '@salesforce/apex/TimesheetAdminController.getDashboardStats';
import getTimesheetEntries from '@salesforce/apex/TimesheetAdminController.getTimesheetEntries';
import searchFilterOptions from '@salesforce/apex/TimesheetAdminController.searchFilterOptions';
import getFilterOptions from '@salesforce/apex/TimesheetAdminController.getFilterOptions';
import getAdminTimesheetSummary from '@salesforce/apex/TimesheetAdminController.getAdminTimesheetSummary';

export default class AdminTimesheetManagement extends LightningElement {
    
    @track stats = {
        totalHours: 0,
        targetHours: 0,
        pendingApprovals: 0,
        pendingHours: 0,
        approvedHours: 0,
        rejectedEntries: 0,
        rejectedHours: 0,
        totalEmployees: 0,
        totalLeaveHours: 0,
        totalLeaveDays: 0,
        avgProductivity: 0
    };

    @track employeeProductivity = [];
    @track tsSummaryRows = [];
    @track tsSummaryLoading = false;
    summaryView = 'monthly'; // 'today' | 'weekly' | 'monthly'

    // Drill-down UI state
    @track selectedDrillEmployee = null;
    @track drillEntries = [];
    @track drillProjectSummary = [];
    
    get showDrillDown() { return this.selectedDrillEmployee != null; }

    get tsBtnToday()   { return this.summaryView === 'today'   ? 'sv-btn sv-btn-active' : 'sv-btn'; }
    get tsBtnWeekly()  { return this.summaryView === 'weekly'  ? 'sv-btn sv-btn-active' : 'sv-btn'; }
    get tsBtnMonthly() { return this.summaryView === 'monthly' ? 'sv-btn sv-btn-active' : 'sv-btn'; }

    get hasTsSummaryRows() { return this.tsSummaryRows.length > 0; }

    // Totals row for footer
    get tsTotalLogBill()    { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.loggedBillable,   0).toFixed(2)); }
    get tsTotalLogNonBill() { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.loggedNonBillable,0).toFixed(2)); }
    get tsTotalLogShadow()  { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.loggedShadow,    0).toFixed(2)); }
    get tsTotalLogged()     { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.loggedTotal,     0).toFixed(2)); }
    get tsTotalAppBill()    { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.approvedBillable,   0).toFixed(2)); }
    get tsTotalAppNonBill() { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.approvedNonBillable,0).toFixed(2)); }
    get tsTotalAppShadow()  { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.approvedShadow,    0).toFixed(2)); }
    get tsTotalApproved()   { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.approvedTotal,    0).toFixed(2)); }
    get tsTotalRejBill()    { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.rejectedBillable,   0).toFixed(2)); }
    get tsTotalRejNonBill() { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.rejectedNonBillable,0).toFixed(2)); }
    get tsTotalRejShadow()  { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.rejectedShadow,    0).toFixed(2)); }
    get tsTotalRejected()   { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.rejectedTotal,   0).toFixed(2)); }
    get tsTotalLeave()      { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.leaveHours,      0).toFixed(2)); }
    get tsTotalTarget()     { return this.formatHrs(this.tsSummaryRows.reduce((a,r) => a + r.targetHours,     0).toFixed(2)); }
    get tsAvgProd() {
        if (!this.tsSummaryRows.length) return '0%';
        const avg = this.tsSummaryRows.reduce((a,r) => a + r.productivityRate, 0) / this.tsSummaryRows.length;
        return avg.toFixed(1) + '%';
    }
    
@track employeeSearch = '';
@track departmentSearch = '';
@track projectSearch = '';

@track filteredEmployeeResults = [];
@track filteredDepartmentResults = [];
@track filteredProjectResults = [];

@track showEmployeeDropdown = false;
@track showDepartmentDropdown = false;
@track showProjectDropdown = false;

    @track filteredEntries = [];
    @track allEntries = [];
    @track paginatedEntries = [];
    @track employeeOptions = [];
    @track departmentOptions = [];
    @track projectOptions = [];
    @track statusOptions = [];
    
     debounceTimeout;
    selectedEmployee = '';
    selectedDepartment = '';
    selectedProject = '';
    selectedStatus = '';
    searchTerm = '';
  // Pagination properties
    pageSize = 10;
    currentPage = 1;
    totalPages = 1;
    @track pageNumbers = [];
    
    // Summary Pagination
    sumCurrentPage = 1;
    sumTotalPages = 1;
    @track sumPageNumbers = [];
    @track paginatedSummaryRows = [];

    // Drill-Down Pagination
    drillCurrentPage = 1;
    drillTotalPages = 1;
    @track drillPageNumbers = [];
    @track paginatedDrillEntries = [];

    get pageSizeOptions() {
        return [
            { label: '5', value: '5' },
            { label: '10', value: '10' },
            { label: '20', value: '20' },
            { label: '50', value: '50' }
        ];
    }

    currentMonth = new Date().getMonth();
    currentYear = new Date().getFullYear();
    currentWeekStart = null;
    currentDate = new Date();
    viewMode = 'monthly'; // 'monthly', 'weekly', or 'daily'

    isLoading = false;
    selectedEntryId = '';
   
    wiredStatsResult;
    wiredEntriesResult;

    connectedCallback() {
        const today = new Date();
        this.currentWeekStart = this.getWeekStartDate(today);
        this.loadFilterOptions();
        this.loadData();
    }
    
    // Get Monday of the current week
    getWeekStartDate(date) {
        const d = new Date(date);
        const day = d.getDay();
        const diff = d.getDate() - day + (day === 0 ? -6 : 1);
        return new Date(d.setDate(diff));
    }

    // Get date range label based on view mode
    get dateRangeLabel() {
        if (this.viewMode === 'weekly') {
            const weekEnd = new Date(this.currentWeekStart);
            weekEnd.setDate(weekEnd.getDate() + 6);
            
            const startStr = this.formatShortDate(this.currentWeekStart);
            const endStr = this.formatShortDate(weekEnd);
            
            return `${startStr} - ${endStr}`;
        } else if (this.viewMode === 'daily') {
            return this.formatFullDate(this.currentDate);
        } else {
            const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 
                               'July', 'August', 'September', 'October', 'November', 'December'];
            return `${monthNames[this.currentMonth]} ${this.currentYear}`;
        }
    }

    get viewModeLabel() {
        if (this.viewMode === 'monthly') return 'Switch to Weekly';
        if (this.viewMode === 'weekly') return 'Switch to Daily';
        return 'Switch to Monthly';
    }

    get hasEntries() {
        return this.filteredEntries && this.filteredEntries.length > 0;
    }
get hasActiveFilters() {
        return this.selectedEmployee || this.selectedDepartment || this.selectedProject || this.selectedStatus;
    }
    get paginationLabel() {
        const start = (this.currentPage - 1) * this.pageSize + 1;
        const end = Math.min(this.currentPage * this.pageSize, this.filteredEntries.length);
        return `Showing ${start} to ${end} of ${this.filteredEntries.length} entries`;
    }

    get canPreviousPage() {
        return this.currentPage > 1;
    }

    get canNextPage() {
        return this.currentPage < this.totalPages;
    }
    formatShortDate(date) {
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return `${months[date.getMonth()]} ${date.getDate()}`;
    }

    formatFullDate(date) {
        const months = ['January', 'February', 'March', 'April', 'May', 'June', 
                       'July', 'August', 'September', 'October', 'November', 'December'];
        return `${months[date.getMonth()]} ${date.getDate()}, ${date.getFullYear()}`;
    }

    // Calculate start date based on view mode
    get startDate() {
        if (this.viewMode === 'weekly') {
            return this.formatDateForAPI(this.currentWeekStart);
        } else {
            const firstDay = new Date(this.currentYear, this.currentMonth, 1);
            return this.formatDateForAPI(firstDay);
        }
    }

    // Calculate end date based on view mode
    get endDate() {
        if (this.viewMode === 'weekly') {
            const weekEnd = new Date(this.currentWeekStart);
            weekEnd.setDate(weekEnd.getDate() + 6);
            return this.formatDateForAPI(weekEnd);
        } else {
            const lastDay = new Date(this.currentYear, this.currentMonth + 1, 0);
            return this.formatDateForAPI(lastDay);
        }
    }

    get actualStartDate() {
        if (this.viewMode === 'daily') {
            return this.formatDateForAPI(this.currentDate);
        }
        return this.startDate;
    }

    get actualEndDate() {
        let date;
        if (this.viewMode === 'daily') {
            date = this.currentDate;
        } else {
            date = this.endDate;
        }
        
        // Cap at today for productivity calculations if the range extends into the future
        const apiDate = typeof date === 'string' ? date : this.formatDateForAPI(date);
        const todayStr = this.formatDateForAPI(new Date());
        return apiDate > todayStr ? todayStr : apiDate;
    }

    // Format date to YYYY-MM-DD for API calls
    formatDateForAPI(date) {
        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        return `${year}-${month}-${day}`;
    }

    // Load filter options from server
    async loadFilterOptions() {
        try {
            const results = await Promise.all([
                getFilterOptions({ filterType: 'employees' }),
                getFilterOptions({ filterType: 'departments' }),
                getFilterOptions({ filterType: 'projects' }),
                getFilterOptions({ filterType: 'status' })
            ]);

            this.employeeOptions = [
                { label: 'All Employees', value: '' },
                ...results[0].map(e => ({ label: e, value: e }))
            ];
            this.departmentOptions = [
                { label: 'All Departments', value: '' },
                ...results[1].map(d => ({ label: d, value: d }))
            ];
            this.projectOptions = [
                { label: 'All Projects', value: '' },
                ...results[2].map(p => ({ label: p, value: p }))
            ];
            this.statusOptions = [
                { label: 'All Status', value: '' },
                ...results[3].map(s => ({ label: s, value: s }))
            ];
           
        

        } catch (error) {
            console.error('Error loading filter options:', error);
            this.showToast('Error', 'Failed to load filter options', 'error');
        }
    }

    // Load timesheet data
    async loadData() {
        this.isLoading = true;
        try {
            const [statsData, entriesData, summaryData] = await Promise.all([
                getDashboardStats({ 
                    startDate: this.actualStartDate, 
                    endDate: this.actualEndDate 
                }),
                getTimesheetEntries({
                    startDate: this.actualStartDate,
                    endDate: this.actualEndDate,
                    employeeFilter: this.selectedEmployee,
                    departmentFilter: this.selectedDepartment,
                    projectFilter: this.selectedProject,
                    statusFilter: this.selectedStatus
                }),
                getAdminTimesheetSummary({
                    startDateStr: this.actualStartDate,
                    endDateStr: this.actualEndDate,
                    departmentFilter: this.selectedDepartment,
                    employeeFilter: this.selectedEmployee
                })
            ]);
            console.log('Stats received:', statsData);
            console.log('Entries received:', entriesData.length);
            console.log('Summary rows:', summaryData.length);

            this.stats = statsData;
            this.allEntries = entriesData.map(entry => ({
                ...entry,
                statusClass: this.getStatusClass(entry.status)
            }));
            this.tsSummaryRows = summaryData.map(row => ({
                ...row,
                initials: this.getInitials(row.name),
                loggedBillableDisplay:    this.formatHrs(row.loggedBillable),
                loggedNonBillableDisplay: this.formatHrs(row.loggedNonBillable),
                loggedShadowDisplay:      this.formatHrs(row.loggedShadow),
                loggedTotalDisplay:       this.formatHrs(row.loggedTotal),
                approvedBillableDisplay:    this.formatHrs(row.approvedBillable),
                approvedNonBillableDisplay: this.formatHrs(row.approvedNonBillable),
                approvedShadowDisplay:      this.formatHrs(row.approvedShadow),
                approvedTotalDisplay:       this.formatHrs(row.approvedTotal),
                rejectedBillableDisplay:    this.formatHrs(row.rejectedBillable),
                rejectedNonBillableDisplay: this.formatHrs(row.rejectedNonBillable),
                rejectedShadowDisplay:      this.formatHrs(row.rejectedShadow),
                rejectedTotalDisplay:       this.formatHrs(row.rejectedTotal),
                prodBillableDisplay:    row.prodBillable    + '%',
                prodNonBillableDisplay: row.prodNonBillable + '%',
                prodShadowDisplay:      row.prodShadow      + '%',
                prodTotalDisplay:       row.productivityRate + '%',
                prodTotalClass:         this.getProdClass(row.productivityRate),
                targetDisplay:          this.formatHrs(row.targetHours),
                leaveDisplay:           this.formatHrs(row.leaveHours),
                leaveDaysDisplay:       row.leaveDays + 'd'
            }));
            
            this.sumCurrentPage = 1;
            this.updateSumPagination();

            this.applyFilters();
            
            // If a drill down is active, refresh its data
            if (this.selectedDrillEmployee) {
                this.drillEntries = this.allEntries.filter(e => e.employeeName === this.selectedDrillEmployee);
                this.calculateProjectSummary(this.drillEntries);
                this.drillCurrentPage = 1;
                this.updateDrillPagination();
            }

            if (this.filteredEntries.length === 0) {
                console.warn('No entries found after filtering');
            }
        } catch (error) {
            console.error('Error loading data:', error);
            this.showToast('Error', error.body?.message || 'Failed to load data', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Apply local filters to entries
    applyFilters() {
        let filtered = [...this.allEntries];

        if (this.searchTerm) {
            const term = this.searchTerm.toLowerCase();
            filtered = filtered.filter(entry => 
                entry.employeeName?.toLowerCase().includes(term) ||
                entry.description?.toLowerCase().includes(term) ||
                entry.projectName?.toLowerCase().includes(term)
            );
        }

       console.log('Applied filters - Before:', this.allEntries.length, 'After:', filtered.length);
        this.filteredEntries = filtered;
        
    }
 // Update pagination
    updatePagination() {
        this.totalPages = Math.ceil(this.filteredEntries.length / this.pageSize) || 1;
        this.currentPage = Math.min(this.currentPage, this.totalPages);
        
        const start = (this.currentPage - 1) * this.pageSize;
        const end = start + this.pageSize;
        this.paginatedEntries = this.filteredEntries.slice(start, end);
        
        this.generatePageNumbers();
    }

    // Generate page number array for display
    generatePageNumbers() {
        this.pageNumbers = [];
        const maxPagesToShow = 5;
        let startPage = 1;
        let endPage = this.totalPages;

        if (this.totalPages > maxPagesToShow) {
            startPage = Math.max(1, this.currentPage - Math.floor(maxPagesToShow / 2));
            endPage = Math.min(this.totalPages, startPage + maxPagesToShow - 1);

            if (endPage - startPage + 1 < maxPagesToShow) {
                startPage = Math.max(1, endPage - maxPagesToShow + 1);
            }
        }

       for (let i = startPage; i <= endPage; i++) {
            this.pageNumbers.push({
                number: i,
                isActive: i === this.currentPage
            });
        }
    }

    formatHrs(val) {
        if (!val || val === 0) return '—';
        return val + 'h';
    }

    getInitials(name) {
        if (!name) return '?';
        return name.split(' ').map(w => w[0]).join('').substring(0, 2).toUpperCase();
    }

    getProdClass(pct) {
        if (pct >= 90) return 'prod-total-chip prod-high';
        if (pct >= 75) return 'prod-total-chip prod-medium';
        return 'prod-total-chip prod-low';
    }

    // Get CSS class for status badges
    getStatusClass(status) {
        const classes = {
            'Pending': 'status-pending',
            'Approved': 'status-approved',
            'Rejected': 'status-rejected'
        };
        return classes[status] || 'status-pending';
    }

    // Get CSS class for productivity
    getProductivityClass(pct) {
        if (pct >= 90) return 'prod-high';
        if (pct >= 75) return 'prod-medium';
        return 'prod-low';
    }

    // Summary view toggle (Today / Week / Month)
    handleSummaryViewChange(event) {
        const view = event.target.dataset.view;
        this.summaryView = view;
        
        // Sync with main viewMode
        if (view === 'today') {
            this.viewMode = 'daily';
            this.currentDate = new Date(); // Reset to today
        } else if (view === 'weekly') {
            this.viewMode = 'weekly';
            this.currentWeekStart = this.getWeekStartDate(new Date()); // Reset to current week
        } else if (view === 'monthly') {
            this.viewMode = 'monthly';
            const today = new Date();
            this.currentMonth = today.getMonth();
            this.currentYear = today.getFullYear();
        }
        
        this.loadData();
    }

    // Drill-Down handlers
    handleEmployeeClick(event) {
        const empName = event.currentTarget.dataset.name;
        if (!empName) return;

        this.selectedDrillEmployee = empName;
        // Filter entries
        this.drillEntries = this.allEntries.filter(e => e.employeeName === empName);
        this.calculateProjectSummary(this.drillEntries);
        this.drillCurrentPage = 1;
        this.updateDrillPagination();
        
        // Scroll to drill-down panel
        setTimeout(() => {
            const panel = this.template.querySelector('.drill-panel');
            if (panel) panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }, 100);
    }

    closeDrillDown() {
        this.selectedDrillEmployee = null;
        this.drillEntries = [];
        this.drillProjectSummary = [];
    }

    calculateProjectSummary(entries) {
        const projMap = {};
        
        entries.forEach(e => {
            const proj = e.projectName || 'N/A';
            const bill = e.billingStatus ? e.billingStatus.toLowerCase().trim() : 'billable';
            const status = e.status ? e.status.toLowerCase() : '';
            
            const isBill = bill === 'billable';
            const isNonB = bill.includes('non') || bill === 'non-billable';
            const displayBill = isBill ? 'Billable' : (isNonB ? 'Non-Billable' : 'Shadow');
            
            const key = proj + '|' + displayBill;
            
            if(!projMap[key]) {
                projMap[key] = {
                    id: key,
                    projectName: proj,
                    billingStatus: displayBill,
                    billClass: isBill ? 'bill-pill billable' : (isNonB ? 'bill-pill nonbg' : 'bill-pill shadow'),
                    logged: 0,
                    approved: 0,
                    rejected: 0
                };
            }
            
            const hrs = e.hours || 0;
            projMap[key].logged += hrs;
            
            if(status.includes('approved')) {
                projMap[key].approved += hrs;
            } else if (status.includes('rejected')) {
                projMap[key].rejected += hrs;
            }
        });
        
        this.drillProjectSummary = Object.values(projMap).map(p => ({
            ...p,
            loggedDisplay: this.formatHrs(p.logged),
            approvedDisplay: this.formatHrs(p.approved),
            rejectedDisplay: this.formatHrs(p.rejected)
        })).sort((a,b) => a.projectName.localeCompare(b.projectName));
    }

    // Navigation handlers
    handlePreviousMonth() {
        if (this.viewMode === 'weekly') {
            this.currentWeekStart = new Date(this.currentWeekStart);
            this.currentWeekStart.setDate(this.currentWeekStart.getDate() - 7);
        } else if (this.viewMode === 'daily') {
            this.currentDate = new Date(this.currentDate);
            this.currentDate.setDate(this.currentDate.getDate() - 1);
        } else {
            if (this.currentMonth === 0) {
                this.currentMonth = 11;
                this.currentYear--;
            } else {
                this.currentMonth--;
            }
        }
        this.loadData();
    }

    handleNextMonth() {
        if (this.viewMode === 'weekly') {
            this.currentWeekStart = new Date(this.currentWeekStart);
            this.currentWeekStart.setDate(this.currentWeekStart.getDate() + 7);
        } else if (this.viewMode === 'daily') {
            this.currentDate = new Date(this.currentDate);
            this.currentDate.setDate(this.currentDate.getDate() + 1);
        } else {
            if (this.currentMonth === 11) {
                this.currentMonth = 0;
                this.currentYear++;
            } else {
                this.currentMonth++;
            }
        }
        this.loadData();
    }

    // Toggle between view modes
    handleMonthViewToggle() {
        if (this.viewMode === 'monthly') {
            this.viewMode = 'weekly';
            this.summaryView = 'weekly';
            this.currentWeekStart = this.getWeekStartDate(new Date());
        } else if (this.viewMode === 'weekly') {
            this.viewMode = 'daily';
            this.summaryView = 'today';
            this.currentDate = new Date();
        } else {
            this.viewMode = 'monthly';
            this.summaryView = 'monthly';
            const today = new Date();
            this.currentMonth = today.getMonth();
            this.currentYear = today.getFullYear();
        }
        this.loadData();
    }

   // Filter handlers - these now trigger data load immediately
    handleEmployeeChange(event) {
        this.selectedEmployee = event.detail.value || '';
        console.log('Employee selected:', this.selectedEmployee);
        this.loadData();
    }

    handleDepartmentChange(event) {
        this.selectedDepartment = event.detail.value || '';
        console.log('Department selected:', this.selectedDepartment);
        this.loadData();
    }

    handleProjectChange(event) {
        this.selectedProject = event.detail.value || '';
                console.log('Project selected:', this.selectedProject);
                this.loadData();
    }

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value || '';
        console.log('Status selected:', this.selectedStatus);
        this.loadData();
    }

    /*handleApplyFilters() {
        this.loadData();
    }*/
handleApplyFilters() {
       // Convert 'All' values to empty string for proper filtering
       this.selectedEmployee = this.selectedEmployee === 'All Employees' ? '' : this.selectedEmployee;
       this.selectedDepartment = this.selectedDepartment === 'All Departments' ? '' : this.selectedDepartment;
       this.selectedProject = this.selectedProject === 'All Projects' ? '' : this.selectedProject;
       this.selectedStatus = this.selectedStatus === 'All Status' ? '' : this.selectedStatus;
       this.loadData();
   }
    handleClearFilters() {
        this.selectedEmployee = '';
        this.selectedDepartment = '';
        this.selectedProject = '';
        this.selectedStatus = '';
        this.searchTerm = '';
        this.loadData();
    }
// Individual pill clear handlers
    handleClearEmployee() {
        this.selectedEmployee = '';
        this.loadData();
    }

    handleClearDepartment() {
        this.selectedDepartment = '';
        this.loadData();
    }

    handleClearProject() {
        this.selectedProject = '';
        this.loadData();
    }

    handleClearStatus() {
        this.selectedStatus = '';
        this.loadData();
    }
    
// Summary Pagination Handlers
    get sumDisablePrev() { return this.sumCurrentPage <= 1; }
    get sumDisableNext() { return this.sumCurrentPage >= this.sumTotalPages; }

    updateSumPagination() {
        this.sumTotalPages = Math.ceil(this.tsSummaryRows.length / this.pageSize) || 1;
        const start = (this.sumCurrentPage - 1) * this.pageSize;
        this.paginatedSummaryRows = this.tsSummaryRows.slice(start, start + this.pageSize);
        
        this.sumPageNumbers = [];
        for (let i = 1; i <= this.sumTotalPages; i++) {
            this.sumPageNumbers.push({ number: i, variant: i === this.sumCurrentPage ? 'brand' : 'neutral' });
        }
    }

    handleSumFirst() { this.sumCurrentPage = 1; this.updateSumPagination(); }
    handleSumPrev() { if(!this.sumDisablePrev) { this.sumCurrentPage--; this.updateSumPagination(); } }
    handleSumNext() { if(!this.sumDisableNext) { this.sumCurrentPage++; this.updateSumPagination(); } }
    handleSumLast() { this.sumCurrentPage = this.sumTotalPages; this.updateSumPagination(); }
    handleSumPage(event) {
        this.sumCurrentPage = parseInt(event.currentTarget.dataset.page, 10);
        this.updateSumPagination();
    }

// Drill-Down Pagination Handlers
    get drillDisablePrev() { return this.drillCurrentPage <= 1; }
    get drillDisableNext() { return this.drillCurrentPage >= this.drillTotalPages; }

    updateDrillPagination() {
        this.drillTotalPages = Math.ceil(this.drillEntries.length / this.pageSize) || 1;
        const start = (this.drillCurrentPage - 1) * this.pageSize;
        this.paginatedDrillEntries = this.drillEntries.slice(start, start + this.pageSize);
        
        this.drillPageNumbers = [];
        for (let i = 1; i <= this.drillTotalPages; i++) {
            this.drillPageNumbers.push({ number: i, variant: i === this.drillCurrentPage ? 'brand' : 'neutral' });
        }
    }

    handleDrillFirst() { this.drillCurrentPage = 1; this.updateDrillPagination(); }
    handleDrillPrev() { if(!this.drillDisablePrev) { this.drillCurrentPage--; this.updateDrillPagination(); } }
    handleDrillNext() { if(!this.drillDisableNext) { this.drillCurrentPage++; this.updateDrillPagination(); } }
    handleDrillLast() { this.drillCurrentPage = this.drillTotalPages; this.updateDrillPagination(); }
    handleDrillPage(event) {
        this.drillCurrentPage = parseInt(event.currentTarget.dataset.page, 10);
        this.updateDrillPagination();
    }

    handlePageSizeChange(event) {
        this.pageSize = parseInt(event.detail.value, 10);
        this.sumCurrentPage = 1; this.updateSumPagination();
        this.drillCurrentPage = 1; this.updateDrillPagination();
    }


    // Export CSV / Excel
    handleExportCSV() {
        try {
            if (!this.filteredEntries || this.filteredEntries.length === 0) {
                this.showToast('Warning', 'No data to export', 'warning');
                return;
            }

            let csv = 'Employee,Department,Project,Date,Task,Hours,Billing Status,Status\n';
            
            this.filteredEntries.forEach(entry => {
                const employee = entry.employeeName || '';
                const department = entry.department || '';
                const project = entry.projectName || '';
                const date = entry.entryDate || '';
                const description = (entry.task || entry.description || '').replace(/"/g, '""');
                const hours = entry.hours != null ? entry.hours : 0;
                const billingStatus = entry.billingStatus || '';
                const status = entry.status || '';
                
                csv += `"${employee}","${department}","${project}","${date}","${description}","${hours}","${billingStatus}","${status}"\n`;
            });

            try {
                this.downloadExcelFile(csv);
                this.showToast('Success', 'Timesheet Excel report (.xlsx) exported successfully', 'success');
            } catch (excelError) {
                console.warn('Excel export error, falling back to CSV:', excelError);
                this.downloadCSVFile(csv);
                this.showToast('Success', 'Timesheet report (.csv) exported successfully', 'success');
            }
        } catch (error) {
            console.error('Export error:', error);
            this.showToast('Error', 'Failed to export: ' + error.message, 'error');
        }
    }

    /**
     * Download formatted Excel (.xlsx) spreadsheet with bold headers, color-coded status, and gridlines
     */
    downloadExcelFile(csvContent) {
        const zipBytes = this.generateXLSXFromCSV(csvContent);
        
        let blob;
        let url;
        try {
            blob = new Blob([zipBytes], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
            url = URL.createObjectURL(blob);
        } catch (e1) {
            blob = new Blob([zipBytes], { type: 'text/plain' });
            url = URL.createObjectURL(blob);
        }
        
        const hiddenElement = document.createElement('a');
        hiddenElement.href = url;
        hiddenElement.download = `Timesheet_Export_${this.startDate}_to_${this.endDate}.xlsx`;
        hiddenElement.style.display = 'none';
        
        document.body.appendChild(hiddenElement);
        hiddenElement.click();
        document.body.removeChild(hiddenElement);
        
        setTimeout(() => {
            URL.revokeObjectURL(url);
        }, 1000);
    }

    /**
     * Generates genuine OpenXML Spreadsheet (.xlsx) binary bytes from CSV content
     */
    generateXLSXFromCSV(csvContent) {
        const rows = this.parseCSV(csvContent);
        if (!rows || rows.length === 0) {
            throw new Error('No records available to export');
        }

        const contentTypes = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>`;

        const rels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`;

        const wbRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`;

        const workbook = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Timesheet Export" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>`;

        const styles = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="8">
    <font><sz val="10"/><name val="Calibri"/><color rgb="FF181818"/></font>
    <font><b/><sz val="11"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF2E844A"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF0176D3"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFB86700"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFEA001E"/></font>
    <font><sz val="10"/><name val="Calibri"/><color rgb="FF706E6B"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF7F27CB"/></font>
  </fonts>
  <fills count="8">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF0070D2"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F5E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F4F9"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF4E5"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFDE8E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F3F3"/></patternFill></fill>
  </fills>
  <borders count="3">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border>
      <left style="thin"><color rgb="FFD8DDE6"/></left>
      <right style="thin"><color rgb="FFD8DDE6"/></right>
      <top style="thin"><color rgb="FFD8DDE6"/></top>
      <bottom style="thin"><color rgb="FFD8DDE6"/></bottom>
    </border>
    <border>
      <left style="thin"><color rgb="FF005FB2"/></left>
      <right style="thin"><color rgb="FF005FB2"/></right>
      <top style="thin"><color rgb="FF005FB2"/></top>
      <bottom style="thin"><color rgb="FF005FB2"/></bottom>
    </border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="11">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="2" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="3" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="4" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="5" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="6" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="left" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="right" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="left" vertical="center" wrapText="1"/>
    </xf>
  </cellXfs>
</styleSheet>`;

        let sheetDataXml = '';
        const headerRow = rows[0];
        sheetDataXml += '<row r="1" ht="28" customHeight="1">';
        for (let c = 0; c < headerRow.length; c++) {
            const colLetter = this.getColumnLetter(c + 1);
            sheetDataXml += `<c r="${colLetter}1" t="inlineStr" s="1"><is><t>${this.escapeXml(headerRow[c])}</t></is></c>`;
        }
        sheetDataXml += '</row>';

        for (let r = 1; r < rows.length; r++) {
            const row = rows[r];
            const rowNum = r + 1;
            sheetDataXml += `<row r="${rowNum}" ht="22" customHeight="1">`;
            
            for (let c = 0; c < row.length; c++) {
                const colLetter = this.getColumnLetter(c + 1);
                const val = row[c] !== undefined ? row[c] : '';
                
                let sIdx = 0;
                if (c === 7) {
                    sIdx = this.getStatusStyleIndex(val);
                } else if (c === 3 || c === 6) {
                    sIdx = 7;
                } else if (c === 5) {
                    sIdx = 9;
                } else if (c === 4) {
                    sIdx = 10;
                } else {
                    sIdx = 8;
                }
                
                if (c === 5 && !isNaN(val) && String(val).trim() !== '') {
                    sheetDataXml += `<c r="${colLetter}${rowNum}" s="${sIdx}"><v>${Number(val)}</v></c>`;
                } else {
                    sheetDataXml += `<c r="${colLetter}${rowNum}" t="inlineStr" s="${sIdx}"><is><t>${this.escapeXml(val)}</t></is></c>`;
                }
            }
            sheetDataXml += '</row>';
        }

        const sheet1 = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetViews>
    <sheetView tabSelected="1" workbookViewId="0">
      <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>
    </sheetView>
  </sheetViews>
  <cols>
    <col min="1" max="1" width="22" customWidth="1"/>
    <col min="2" max="2" width="20" customWidth="1"/>
    <col min="3" max="3" width="26" customWidth="1"/>
    <col min="4" max="4" width="16" customWidth="1"/>
    <col min="5" max="5" width="45" customWidth="1"/>
    <col min="6" max="6" width="12" customWidth="1"/>
    <col min="7" max="7" width="18" customWidth="1"/>
    <col min="8" max="8" width="22" customWidth="1"/>
  </cols>
  <sheetData>
    ${sheetDataXml}
  </sheetData>
</worksheet>`;

        const files = [
            { name: '[Content_Types].xml', data: contentTypes },
            { name: '_rels/.rels', data: rels },
            { name: 'xl/_rels/workbook.xml.rels', data: wbRels },
            { name: 'xl/workbook.xml', data: workbook },
            { name: 'xl/styles.xml', data: styles },
            { name: 'xl/worksheets/sheet1.xml', data: sheet1 }
        ];

        return this.createZip(files);
    }

    parseCSV(csvText) {
        const lines = [];
        let row = [];
        let inQuotes = false;
        let currentField = '';
        
        for (let i = 0; i < csvText.length; i++) {
            const c = csvText[i];
            const next = csvText[i + 1];
            
            if (c === '"') {
                if (inQuotes && next === '"') {
                    currentField += '"';
                    i++;
                } else {
                    inQuotes = !inQuotes;
                }
            } else if (c === ',' && !inQuotes) {
                row.push(currentField);
                currentField = '';
            } else if ((c === '\r' || c === '\n') && !inQuotes) {
                if (c === '\r' && next === '\n') {
                    i++;
                }
                row.push(currentField);
                currentField = '';
                if (row.length > 0 && (row.length > 1 || row[0] !== '')) {
                    lines.push(row);
                }
                row = [];
            } else {
                currentField += c;
            }
        }
        if (currentField || row.length > 0) {
            row.push(currentField);
            if (row.length > 0 && (row.length > 1 || row[0] !== '')) {
                lines.push(row);
            }
        }
        return lines;
    }

    getStatusStyleIndex(statusText) {
        if (!statusText) return 7;
        const s = String(statusText).toLowerCase();
        if (s.includes('approved')) {
            return 2;
        } else if (s.includes('pending') || s.includes('draft')) {
            return 4;
        } else if (s.includes('rejected')) {
            return 5;
        }
        return 7;
    }

    escapeXml(value) {
        if (value === null || value === undefined) {
            return '';
        }
        return String(value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    getColumnLetter(colIndex) {
        let letter = '';
        let temp = colIndex;
        while (temp > 0) {
            const mod = (temp - 1) % 26;
            letter = String.fromCharCode(65 + mod) + letter;
            temp = Math.floor((temp - mod) / 26);
        }
        return letter;
    }

    createZip(files) {
        const encoder = new TextEncoder();
        const fileEntries = [];
        let localHeadersSize = 0;

        for (const file of files) {
            const nameBytes = encoder.encode(file.name);
            const dataBytes = typeof file.data === 'string' ? encoder.encode(file.data) : file.data;
            const crc = this.crc32(dataBytes);
            fileEntries.push({
                nameBytes,
                dataBytes,
                crc,
                uncompressedSize: dataBytes.length,
                compressedSize: dataBytes.length,
                offset: localHeadersSize
            });
            localHeadersSize += 30 + nameBytes.length + dataBytes.length;
        }

        let centralDirSize = 0;
        for (const entry of fileEntries) {
            centralDirSize += 46 + entry.nameBytes.length;
        }

        const totalSize = localHeadersSize + centralDirSize + 22;
        const buffer = new Uint8Array(totalSize);
        const view = new DataView(buffer.buffer);
        let pos = 0;

        for (const entry of fileEntries) {
            view.setUint32(pos, 0x04034b50, true); pos += 4;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 0x0800, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, entry.crc, true); pos += 4;
            view.setUint32(pos, entry.compressedSize, true); pos += 4;
            view.setUint32(pos, entry.uncompressedSize, true); pos += 4;
            view.setUint16(pos, entry.nameBytes.length, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            buffer.set(entry.nameBytes, pos); pos += entry.nameBytes.length;
            buffer.set(entry.dataBytes, pos); pos += entry.dataBytes.length;
        }

        const centralDirOffset = pos;

        for (const entry of fileEntries) {
            view.setUint32(pos, 0x02014b50, true); pos += 4;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 0x0800, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, entry.crc, true); pos += 4;
            view.setUint32(pos, entry.compressedSize, true); pos += 4;
            view.setUint32(pos, entry.uncompressedSize, true); pos += 4;
            view.setUint16(pos, entry.nameBytes.length, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, 0, true); pos += 4;
            view.setUint32(pos, entry.offset, true); pos += 4;
            buffer.set(entry.nameBytes, pos); pos += entry.nameBytes.length;
        }

        view.setUint32(pos, 0x06054b50, true); pos += 4;
        view.setUint16(pos, 0, true); pos += 2;
        view.setUint16(pos, 0, true); pos += 2;
        view.setUint16(pos, fileEntries.length, true); pos += 2;
        view.setUint16(pos, fileEntries.length, true); pos += 2;
        view.setUint32(pos, centralDirSize, true); pos += 4;
        view.setUint32(pos, centralDirOffset, true); pos += 4;
        view.setUint16(pos, 0, true); pos += 2;

        return buffer;
    }

    crc32(bytes) {
        if (!this._crcTable) {
            const table = new Uint32Array(256);
            for (let n = 0; n < 256; n++) {
                let c = n;
                for (let k = 0; k < 8; k++) {
                    c = ((c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1));
                }
                table[n] = c;
            }
            this._crcTable = table;
        }
        let crc = 0 ^ (-1);
        for (let i = 0; i < bytes.length; i++) {
            crc = (crc >>> 8) ^ this._crcTable[(crc ^ bytes[i]) & 0xFF];
        }
        return (crc ^ (-1)) >>> 0;
    }

    downloadCSVFile(csvContent) {
        const universalBOM = '\uFEFF';
        const blob = new Blob([universalBOM + csvContent], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = `timesheet_export_${this.startDate}_to_${this.endDate}.csv`;
        link.style.display = 'none';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);

        setTimeout(() => {
            URL.revokeObjectURL(url);
        }, 500);
    }

    // Toast notification
    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
    /* ---------------- EMPLOYEE AUTOCOMPLETE ---------------- */
handleEmployeeSearchChange(event) {
    const search = event.target.value;
    this.employeeSearch = search;
   clearTimeout(this.debounceTimeout);
    this.debounceTimeout = setTimeout(() => {
        if (search && search.length > 1) {
            this.fetchFilterResults('employees', search, 'employee');
        } else {
            this.filteredEmployeeResults = [];
            this.showEmployeeDropdown = false;
        }
    }, 300);
}

handleEmployeeSelect(event) {
    const value = event.currentTarget.dataset.value;
    this.selectedEmployee = value;
    this.employeeSearch = value;
    this.showEmployeeDropdown = false;
    this.loadData();
}

/* ---------------- DEPARTMENT AUTOCOMPLETE ---------------- */
handleDepartmentSearchChange(event) {
    const search = event.target.value;
    this.departmentSearch = search;
    clearTimeout(this.debounceTimeout);
    this.debounceTimeout = setTimeout(() => {
        if (search && search.length > 1) {
            this.fetchFilterResults('departments', search, 'department');
        } else {
            this.filteredDepartmentResults = [];
            this.showDepartmentDropdown = false;
        }
    }, 300);
}

handleDepartmentSelect(event) {
    const value = event.currentTarget.dataset.value;
    this.selectedDepartment = value;
    this.departmentSearch = value;
    this.showDepartmentDropdown = false;
    this.loadData();
}

/* ---------------- PROJECT AUTOCOMPLETE ---------------- */
handleProjectSearchChange(event) {
    const search = event.target.value;
    this.projectSearch = search;
    clearTimeout(this.debounceTimeout);
    this.debounceTimeout = setTimeout(() => {
        if (search && search.length > 1) {
            this.fetchFilterResults('projects', search, 'project');
        } else {
            this.filteredProjectResults = [];
            this.showProjectDropdown = false;
        }
    }, 300);
}

handleProjectSelect(event) {
    const value = event.currentTarget.dataset.value;
    this.selectedProject = value;
    this.projectSearch = value;
    this.showProjectDropdown = false;
    this.loadData();
}

/* ---------------- SHARED FETCH LOGIC ---------------- */
async fetchFilterResults(type, term, context) {
    try {
        const results = await searchFilterOptions({ filterType: type, searchTerm: term });
        const mapped = results.map(r => ({ label: r, value: r }));
        if (context === 'employee') {
            this.filteredEmployeeResults = mapped;
            this.showEmployeeDropdown = mapped.length > 0;
        } else if (context === 'department') {
            this.filteredDepartmentResults = mapped;
            this.showDepartmentDropdown = mapped.length > 0;
        } else if (context === 'project') {
            this.filteredProjectResults = mapped;
            this.showProjectDropdown = mapped.length > 0;
        }
    } catch (error) {
        console.error('Filter search error', error);
    }
}
}