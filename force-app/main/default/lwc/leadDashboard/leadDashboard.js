// leadDashboard.js
// CHANGES:
// (1) Month names now FULL (January, February...) shown in a dropdown selector
// (2) Drill-down inherits the selected summary month — no separate month filter in drill panel
// (3) Drill-down tables have full tfoot totals row (attendance + timesheet)
// (4) Productivity rate shown in timesheet drill tfoot
// ═══════════════════════════════════════════════════════════════════════════════

import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent }                from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue }      from 'lightning/uiRecordApi';

import getMyTeamMembers            from '@salesforce/apex/TeamLeadDashboardController.getMyTeamMembers';
import getAttendanceRecords        from '@salesforce/apex/TeamLeadDashboardController.getAttendanceRecords';
import getTimesheetRecords         from '@salesforce/apex/TeamLeadDashboardController.getTimesheetRecords';
import getTimesheetEntries         from '@salesforce/apex/TeamLeadDashboardController.getTimesheetEntries';
import getLeaveRequests            from '@salesforce/apex/TeamLeadDashboardController.getLeaveRequests';
import getLeaveRequestsUncached    from '@salesforce/apex/TeamLeadDashboardController.getLeaveRequestsUncached';
import getMonthlyAttendanceSummary from '@salesforce/apex/TeamLeadDashboardController.getMonthlyAttendanceSummary';
import updateLeaveStatus           from '@salesforce/apex/TeamLeadDashboardController.updateLeaveStatus';
import getActiveProjects           from '@salesforce/apex/TeamLeadDashboardController.getActiveProjects';
import getProjectAssignments       from '@salesforce/apex/TeamLeadDashboardController.getProjectAssignments';
import assignProjectToEmployees    from '@salesforce/apex/TeamLeadDashboardController.assignProjectToEmployees';
import removeProjectAssignment     from '@salesforce/apex/TeamLeadDashboardController.removeProjectAssignment';
import getTeamSummary              from '@salesforce/apex/TeamLeadDashboardController.getTeamSummary';
import getTeamTimesheetSummary     from '@salesforce/apex/TeamLeadDashboardController.getTeamTimesheetSummary';
import getTeamMemberLeaves         from '@salesforce/apex/TeamLeadDashboardController.getTeamMemberLeaves';
import getPicklistValues           from '@salesforce/apex/TeamLeadDashboardController.getPicklistValues';
import getPendingApprovalCounts    from '@salesforce/apex/TeamLeadDashboardController.getPendingApprovalCounts';
import getPendingLeaveAll          from '@salesforce/apex/TeamLeadDashboardController.getPendingLeaveAll';
import getPendingTimesheetAll      from '@salesforce/apex/TeamLeadDashboardController.getPendingTimesheetAll';
import updateTimesheetStatus       from '@salesforce/apex/TeamLeadDashboardController.updateTimesheetStatus';
import getPendingWfhAll            from '@salesforce/apex/TeamLeadDashboardController.getPendingWfhAll';
import updateWfhStatus             from '@salesforce/apex/TeamLeadDashboardController.updateWfhStatus';
import sendApprovalEmail           from '@salesforce/apex/TeamLeadDashboardController.sendApprovalEmail';

import USER_ID    from '@salesforce/user/Id';
import NAME_FIELD from '@salesforce/schema/User.Name';

const COLORS      = ['#7C3AED','#0891B2','#D97706','#059669','#DC2626'];
// ✅ CHANGE 1: Full month names
const MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December'];
// Short labels for badges/display
const MONTH_SHORT = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class LeadDashboard extends LightningElement {

    userId = USER_ID;

    @wire(getRecord, { recordId: '$userId', fields: [NAME_FIELD] })
    currentUser;

    get managerName()     { return getFieldValue(this.currentUser.data, NAME_FIELD) || 'Team Lead'; }
    get managerInitials() { return this._initials(this.managerName); }

    // ── Core ──
    @track teamMembers       = [];
    @track selectedEmpId     = null;
    @track selectedEmp       = null;
    @track activeTab         = 'attendance';
    @track mainView          = 'summary';
    @track attendanceRecords = [];
    @track timesheetRecords  = [];
    @track leaveRequests     = [];
    @track attendanceSummary = { rate:0, rateDisplay:'0%', present:0, late:0, absent:0 };
    @track isLoading         = false;
    @track noTeamMembers     = false;

    // ── Projects ──
    @track projectAssignments     = [];
    @track activeProjects          = [];
    @track showProjModal           = false;
    @track projModalTitle          = 'Assign Project';
    @track projModalSaveLabel      = 'Assign';
    @track projFormProjectId       = '';
    @track projFormRole            = '';
    @track projFormStatus          = '';
    @track editingAssignmentId     = null;
    @track roleOptions             = [];
    @track employmentStatusOptions = [];
    _picklistsLoaded = false;

    // ── Summary ──
    @track activeSummaryTab = 'attendance';
    @track summaryView      = `month_${new Date().getMonth()}`;
    @track summaryRows      = [];
    @track summaryLoading   = false;
    @track tsView           = 'monthly';
    @track tsSummaryRows    = [];
    @track tsSummaryLoading = false;

    // ✅ CHANGE 1: Dropdown state for month selectors
    @track showAttMonthDropdown = false;  // attendance summary month dropdown
    @track showTsMonthDropdown  = false;  // timesheet summary month dropdown

    // ── Drill-down ──
    @track drillEmp        = null;
    @track drillTab        = 'attendance';
    @track drillView       = `month_${new Date().getMonth()}`;
    @track drillLoading    = false;
    @track drillAttRecords = [];
    @track drillTsRecords  = [];
    _rawDrillAtt = [];
    _rawDrillTs  = [];

    // ── Filters ──
    @track attFilterStatus = '';
    @track tsFilterProject = '';
    @track tsFilterBilling = '';
    @track lvFilterType    = '';
    @track showFilterPopup = false;

    // ── Modals ──
    @track showRejectModal = false;
    @track pendingRejectId = null;
    @track rejectReason    = '';

    @track drillLeaveRecords = [];
    @track _rawDrillLeave    = [];

    // ── Pending counts ──
    @track pendingLeaveCount    = 0;
    @track pendingTsCount       = 0;
    @track pendingCountsLoading = false;
    @track pendingWfhCount      = 0;

    // ── Pending Approvals View ──
    @track pendingView              = 'leave';
    @track pendingLeaveAll          = [];
    @track pendingTsAll             = [];
    @track pendingViewLoading       = false;
    @track showRejectModalPending   = false;
    @track pendingRejectTargetId    = null;
    @track pendingRejectReason      = '';
    @track pendingRejectIsTs        = false;
    @track pendingRejectIsWfh       = false;
    @track pendingWfhAll            = [];

    // ── Approval Page ──
    @track approvalPageType            = '';
    @track approvalData                = {};
    @track approvalComments            = '';
    @track approvalMailSubject         = '';
    @track approvalMailBody            = '';
    @track approvalPageProcessing      = false;
    @track showApprovalPageRejectReason = false;
    @track approvalPageRejectReason    = '';
    @track _isApprovalPage = false;

    @track tsSubTab = 'entries';
    @track expandedWeekKeys = {};
    @track weeklyBulkProcessing = {};

    // ═════════════════════════════════════════════════
    //  GENERAL COMPUTED
    // ═════════════════════════════════════════════════
    get todayDisplay() {
        return new Date().toLocaleDateString('en-IN',{ weekday:'long', day:'numeric', month:'long', year:'numeric' });
    }
    get teamCount()      { return this.teamMembers.length; }
    get hasAssignments() { return this.projectAssignments.length > 0; }

    // ✅ CHANGE 1: Month list for dropdowns — full names, all months up to current
    _buildMonthDropdownList(activeView) {
        const cm = new Date().getMonth();
        const all = [];
        for (let m = 0; m <= cm; m++) {
            const vk = `month_${m}`;
            all.push({
                monthKey : vk,
                viewKey  : vk,
                label    : MONTH_NAMES[m],
                shortLabel: MONTH_SHORT[m],
                isActive : activeView === vk,
                itemClass: `month-dd-item${activeView === vk ? ' month-dd-item--active' : ''}`
            });
        }
        return all.reverse(); // most recent first
    }

    // Att summary dropdown
    get attMonthDropdownList() { return this._buildMonthDropdownList(this.summaryView); }
    get attActiveMonthLabel() {
        if (this.summaryView === 'today')  return 'Today';
        if (this.summaryView === 'weekly') return 'This Week';
        if (this.summaryView?.startsWith('month_')) {
            const mi = parseInt(this.summaryView.substring(6), 10);
            return MONTH_NAMES[mi] || 'Month';
        }
        return 'Month';
    }
    get attMonthDropdownClass() { return `month-dropdown-panel${this.showAttMonthDropdown ? ' month-dropdown-panel--open' : ''}`; }

    // Ts summary dropdown
    get tsMonthDropdownList() { return this._buildMonthDropdownList(this.tsView); }
    get tsActiveMonthLabel() {
        if (this.tsView === 'today')   return 'Today';
        if (this.tsView === 'weekly')  return 'This Week';
        if (this.tsView === 'monthly') return MONTH_NAMES[new Date().getMonth()];
        if (this.tsView?.startsWith('month_')) {
            const mi = parseInt(this.tsView.substring(6), 10);
            return MONTH_NAMES[mi] || 'Month';
        }
        return 'Month';
    }
    get tsMonthDropdownClass() { return `month-dropdown-panel${this.showTsMonthDropdown ? ' month-dropdown-panel--open' : ''}`; }

    get attBtnToday()  { return `sv-btn${this.summaryView==='today'  ?' sv-active':''}`; }
    get attBtnWeekly() { return `sv-btn${this.summaryView==='weekly' ?' sv-active':''}`; }
    get tsBtnToday()   { return `sv-btn ts-sv-btn${this.tsView==='today'  ?' ts-sv-active':''}`; }
    get tsBtnWeekly()  { return `sv-btn ts-sv-btn${this.tsView==='weekly' ?' ts-sv-active':''}`; }
    get tsBtnMonthly() { return `sv-btn ts-sv-btn${this.tsView==='monthly'?' ts-sv-active':''}`; }

    get totalPendingCount()  { return this.pendingLeaveCount + this.pendingTsCount + this.pendingWfhCount; }
    get hasAnyPending()      { return this.totalPendingCount > 0; }
    get allCaughtUp()        { return this.totalPendingCount === 0 && !this.pendingCountsLoading; }
    get pendingBarClass()    { return this.hasAnyPending ? 'pending-bar pending-bar--has-items' : 'pending-bar'; }
    get leavePillClass()     { return this.pendingLeaveCount > 0 ? 'pending-pill pending-pill--leave' : 'pending-pill pending-pill--leave pending-pill--zero'; }
    get tsPillClass()        { return this.pendingTsCount   > 0 ? 'pending-pill pending-pill--ts'    : 'pending-pill pending-pill--ts pending-pill--zero'; }
    get pendingWfhClass()    { return this.pendingWfhCount  > 0 ? 'pending-pill pending-pill--wfh'   : 'pending-pill pending-pill--wfh pending-pill--zero'; }

    // Summary totals
    get attTotalWd()      { return this.summaryRows.reduce((s,r)=>s+(Number(r.workingDays)||0),0); }
    get attTotalPresent() { return this.summaryRows.reduce((s,r)=>s+(Number(r.present)||0),0); }
    get attTotalLate()    { return this.summaryRows.reduce((s,r)=>s+(Number(r.late)||0),0); }
    get attTotalAbsent()  { return this.summaryRows.reduce((s,r)=>s+(Number(r.absent)||0),0); }
    get attTotalLeave()   { const t=this.summaryRows.reduce((s,r)=>s+(Number(r.leaveDays)||0),0); return t>0?t:'—'; }
    get attTotalLop()     { const t=this.summaryRows.reduce((s,r)=>s+(Number(r.lop)||0),0); return t>0?t:'—'; }
    get attAvgRate() { return this.summaryRows.length?`${Math.round(this.summaryRows.reduce((s,r)=>s+(Number(r.rate)||0),0)/this.summaryRows.length)}%`:'0%'; }

    _hDisp(v) { return v>0?`${v}h`:'—'; }
    get tsTotalLoggedHrs()  { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.loggedTotal)||0),0)); }
    get tsTotalLogBill()    { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.loggedBillable)||0),0)); }
    get tsTotalLogNonBill() { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.loggedNonBillable)||0),0)); }
    get tsTotalLogShadow()  { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.loggedShadow)||0),0)); }
    get tsTotalApproved()   { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.approvedTotal)||0),0)); }
    get tsTotalAppBill()    { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.approvedBillable)||0),0)); }
    get tsTotalAppNonBill() { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.approvedNonBillable)||0),0)); }
    get tsTotalAppShadow()  { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.approvedShadow)||0),0)); }
    get tsTotalRejectedHrs(){ return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.rejectedTotal)||0),0)); }
    get tsTotalRejBill()    { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.rejectedBillable)||0),0)); }
    get tsTotalRejNonBill() { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.rejectedNonBillable)||0),0)); }
    get tsTotalRejShadow()  { return this._hDisp(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.rejectedShadow)||0),0)); }
    get tsAvgProd()     { return this.tsSummaryRows.length?`${Math.round(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.productivityRate)||0),0)/this.tsSummaryRows.length)}%`:'0%'; }
    get tsAvgProdBill() { return this.tsSummaryRows.length?`${Math.round(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.prodBillable)||0),0)/this.tsSummaryRows.length)}%`:'0%'; }
    get tsAvgProdNonBill() { return this.tsSummaryRows.length?`${Math.round(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.prodNonBillable)||0),0)/this.tsSummaryRows.length)}%`:'0%'; }
    get tsAvgProdShadow()  { return this.tsSummaryRows.length?`${Math.round(this.tsSummaryRows.reduce((s,r)=>s+(Number(r.prodShadow)||0),0)/this.tsSummaryRows.length)}%`:'0%'; }

    // Filter computed
    get isTsPanel() { return this.drillTab==='timesheet'; }
    get isLvPanel() { return this.drillTab==='leave'; }
    get hasActiveFilters() {
        if (this.isLvPanel) return !!this.lvFilterType;
        if (this.isTsPanel) return !!(this.tsFilterProject||this.tsFilterBilling);
        return !!this.attFilterStatus;
    }
    get activeFilterCount() {
        let n=0;
        if (this.isLvPanel) { if(this.lvFilterType)n++; }
        else if (this.isTsPanel) { if(this.tsFilterProject)n++; if(this.tsFilterBilling)n++; }
        else { if(this.attFilterStatus)n++; }
        return n||null;
    }
    get activeRecordCount() {
        if (this.isLvPanel) return this.drillLeaveRecords.length;
        if (this.isTsPanel) return this.drillTsRecords.length;
        return this.drillAttRecords.length;
    }
    get filterPopupTitle()  { return this.isLvPanel?'Leave Filters':this.isTsPanel?'Timesheet Filters':'Attendance Filters'; }
    get filterPopupClass()  { return this.isLvPanel?'filter-popup filter-popup--lv':this.isTsPanel?'filter-popup filter-popup--ts':'filter-popup'; }
    get filterIconBtnClass() {
        const b=this.isLvPanel?'filter-icon-btn filter-icon-btn--lv':this.isTsPanel?'filter-icon-btn filter-icon-btn--ts':'filter-icon-btn';
        if(!this.hasActiveFilters) return b;
        return b+(this.isLvPanel?' filter-icon-btn--active-lv':this.isTsPanel?' filter-icon-btn--active-ts':' filter-icon-btn--active');
    }
    get filterActiveTagClass() { return this.isLvPanel?'drill-filter-active-tag drill-filter-active-tag--lv':this.isTsPanel?'drill-filter-active-tag drill-filter-active-tag--ts':'drill-filter-active-tag'; }
    get fpFooterClass()      { return this.isLvPanel?'fp-footer fp-footer--lv':this.isTsPanel?'fp-footer fp-footer--ts':'fp-footer'; }
    get fpResultCountClass() { return this.isLvPanel?'fp-result-count fp-result-count--lv':this.isTsPanel?'fp-result-count fp-result-count--ts':'fp-result-count'; }
    get fpClearBtnClass()    { return this.isLvPanel?'fp-clear-btn fp-clear-btn--lv':this.isTsPanel?'fp-clear-btn fp-clear-btn--ts':'fp-clear-btn'; }
    get fpApplyBtnClass()    { return this.isLvPanel?'fp-apply-btn fp-apply-btn--lv':this.isTsPanel?'fp-apply-btn fp-apply-btn--ts':'fp-apply-btn'; }

    _chip(label,value,active,variant='') {
        const base=variant?`fp-chip fp-chip--${variant}`:'fp-chip';
        const ac=variant?`fp-chip--${variant}-active`:'fp-chip--active';
        return {label,value,chipClass:active===value?`${base} ${ac}`:base};
    }
    get attStatusOptions()  { return ['Present','Late','Absent','WFH','On Duty'].map(v=>this._chip(v,v,this.attFilterStatus)); }
    get tsBillingOptions()  { return ['Billable','Non-Billable','Shadow'].map(v=>this._chip(v,v,this.tsFilterBilling,'ts')); }
    get drillProjectOptions()   { return [...new Set(this._rawDrillTs.map(r=>r.projectName).filter(n=>n&&n!=='—'))].sort(); }
    get drillLeaveTypeOptions() { return [...new Set(this._rawDrillLeave.map(r=>r.leaveType).filter(n=>n&&n!=='—'))].sort(); }

    get drillPeriodLabel() {
        const now=new Date();
        if (this.drillView==='today') return `Today: ${this._fmtDate(now)}`;
        if (this.drillView==='weekly') return `This Week: ${this._fmtDate(this._getDrillPeriodStart())} – ${this._fmtDate(now)}`;
        if (this.drillView?.startsWith('month_')) {
            const mi=parseInt(this.drillView.substring(6),10);
            return `${MONTH_NAMES[mi]} ${now.getFullYear()}`;
        }
        return `${now.toLocaleDateString('en-IN',{month:'long',year:'numeric'})}`;
    }

    // Summary switcher
    get showAttSummary() { return this.activeSummaryTab==='attendance'; }
    get showTsSummary()  { return this.activeSummaryTab==='timesheet'; }
    get switcherSliderClass()   { return this.activeSummaryTab==='timesheet'?'switcher-slider switcher-slider--right':'switcher-slider'; }
    get switcherLabelAttClass() { return this.activeSummaryTab==='attendance'?'sw-label sw-label--active sw-label--att':'sw-label sw-label--att'; }
    get switcherLabelTsClass()  { return this.activeSummaryTab==='timesheet'?'sw-label sw-label--active sw-label--ts':'sw-label sw-label--ts'; }
    get switcherHintText()      { return this.activeSummaryTab==='attendance'?'Showing: Team Attendance Summary — click to switch to Timesheet':'Showing: Team Timesheet Productivity — click to switch to Attendance'; }

    get isSummaryView()  { return this.mainView === 'summary' || this.mainView === ''; }
    get isEmployeeView() { return this.mainView==='employees'; }
    get isPendingView()  { return this.mainView === 'pending' && !this._isApprovalPage; }
    get isApprovalPageView() { return this._isApprovalPage; }
    get summaryViewClass()  { return this.mainView==='summary'   ?'view-btn view-active':'view-btn'; }
    get employeeViewClass() { return this.mainView==='employees' ?'view-btn view-active':'view-btn'; }
    get pendingViewClass()  { return this.mainView==='pending'   ?'view-btn view-active':'view-btn'; }

    // Drill computed
    get isDrillAtt()          { return this.drillTab==='attendance'; }
    get isDrillTs()           { return this.drillTab==='timesheet'; }
    get isDrillLv()           { return this.drillTab==='leave'; }
    get hasDrillAttRecords()  { return this.drillAttRecords.length>0; }
    get hasDrillTsRecords()   { return this.drillTsRecords.length>0; }
    get hasDrillLeaveRecords(){ return this.drillLeaveRecords.length>0; }
    get drillAttCount()       { return this.drillAttRecords.length; }
    get drillTsCount()        { return this.drillTsRecords.length; }
    get drillLeaveCount()     { return this.drillLeaveRecords.length; }
    get drillAttClass()  { return `drill-tab-btn${this.drillTab==='attendance'?' drill-tab-active':''}`; }
    get drillTsClass()   { return `drill-tab-btn${this.drillTab==='timesheet' ?' drill-tab-active':''}`; }
    get drillLvClass()   { return `drill-tab-btn${this.drillTab==='leave'     ?' drill-tab-active':''}`; }
    get drillPanelClass(){ return `drill-panel drill-panel--below${this.drillTab==='timesheet'?' drill-panel--ts':''}`; }
    get drillAvaClass()  { return `drill-ava${this.drillTab==='timesheet'?' drill-ava-ts':''}`; }

    // ✅ CHANGE 3: Drill-down ATTENDANCE totals for tfoot
    get drillAttTotalPresent() {
        return this.drillAttRecords.filter(r => (r.Status__c||'').toLowerCase().includes('present')).length;
    }
    get drillAttTotalLate() {
        return this.drillAttRecords.filter(r => (r.Status__c||'').toLowerCase().includes('late')).length;
    }
    get drillAttTotalAbsent() {
        return this.drillAttRecords.filter(r => (r.Status__c||'').toLowerCase().includes('absent')).length;
    }
    get drillAttTotalWfh() {
        return this.drillAttRecords.filter(r => (r.Status__c||'').toLowerCase().includes('wfh')).length;
    }
    get drillAttTotalOnDuty() {
        return this.drillAttRecords.filter(r => (r.Status__c||'').toLowerCase().includes('duty')).length;
    }
    get drillAttHasTotals() { return this.drillAttRecords.length > 0; }

    // ✅ CHANGE 3: Drill-down TIMESHEET totals for tfoot
    get drillTsTotalBillableHrs() {
        const t = this.drillTsRecords
            .filter(r => (r.Billing_Status__c||'').toLowerCase() === 'billable')
            .reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    get drillTsTotalNonBillableHrs() {
        const t = this.drillTsRecords
            .filter(r => (r.Billing_Status__c||'').toLowerCase().includes('non'))
            .reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    get drillTsTotalShadowHrs() {
        const t = this.drillTsRecords
            .filter(r => (r.Billing_Status__c||'').toLowerCase() === 'shadow')
            .reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    get drillTsTotalAllHrs() {
        const t = this.drillTsRecords.reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    get drillTsTotalRegularHrs() {
        const t = this.drillTsRecords.reduce((s,r) => s + (parseFloat(r.Regular_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    get drillTsTotalOvertimeHrs() {
        const t = this.drillTsRecords.reduce((s,r) => s + (parseFloat(r.Overtime_Hours__c) || 0), 0);
        return t > 0 ? `${t.toFixed(1)}h` : '—';
    }
    // Productivity rate for individual drill-down: approved billable / total logged * 100
    get drillTsProdRate() {
        const totalLogged = this.drillTsRecords.reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        if (totalLogged === 0) return '0%';
        const approved = this.drillTsRecords
            .filter(r => (r.Approval_Status__c||'').toLowerCase().includes('approved'))
            .reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        return `${Math.round((approved / totalLogged) * 100)}%`;
    }
    get drillTsProdClass() {
        const totalLogged = this.drillTsRecords.reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        if (totalLogged === 0) return 'sum-rate bad';
        const approved = this.drillTsRecords
            .filter(r => (r.Approval_Status__c||'').toLowerCase().includes('approved'))
            .reduce((s,r) => s + (parseFloat(r.Total_Hours__c) || 0), 0);
        const pct = Math.round((approved / totalLogged) * 100);
        return pct >= 80 ? 'sum-rate good' : pct >= 60 ? 'sum-rate warn' : 'sum-rate bad';
    }
    get drillTsHasTotals() { return this.drillTsRecords.length > 0; }

    // Employee tabs
    get isAttendanceTab() { return this.activeTab==='attendance'; }
    get isTimesheetTab()  { return this.activeTab==='timesheet'; }
    get isLeaveTab()      { return this.activeTab==='leave'; }
    get isProjectsTab()   { return this.activeTab==='projects'; }
    get tabAttClass()  { return `tab-btn${this.activeTab==='attendance'?' tab-active':''}`; }
    get tabTsClass()   { return `tab-btn${this.activeTab==='timesheet' ?' tab-active':''}`; }
    get tabLvClass()   { return `tab-btn${this.activeTab==='leave'     ?' tab-active':''}`; }
    get tabProjClass() { return `tab-btn${this.activeTab==='projects'  ?' tab-active':''}`; }

    // Pending tab classes
    get pendingLvTabClass()  { return `ptab-btn${this.pendingView==='leave'     ?' ptab-active':''}`; }
    get pendingTsTabClass()  { return `ptab-btn${this.pendingView==='timesheet' ?' ptab-active':''}`; }
    get pendingWfhTabClass() { return `ptab-btn${this.pendingView==='wfh'       ?' ptab-active':''}`; }
    get hasPendingLeave()    { return this.pendingLeaveAll.length > 0; }
    get hasPendingTs()       { return this.pendingTsAll.length > 0; }
    get hasPendingWfh()      { return this.pendingWfhAll.length > 0; }
    get pendingLeaveCount2() { return this.pendingLeaveAll.length; }
    get pendingTsCount2()    { return this.pendingTsAll.length; }
    get pendingWfhCount2()   { return this.pendingWfhAll.length; }
    get isPendingLvTab()  { return this.pendingView==='leave'; }
    get isPendingTsTab()  { return this.pendingView==='timesheet'; }
    get isPendingWfhTab() { return this.pendingView==='wfh'; }

    get approvalPageTitle() {
        const map = { leave:'Leave Request Approval', timesheet:'Timesheet Entry Approval', wfh:'WFH Request Approval' };
        return map[this.approvalPageType] || 'Approval';
    }
    get approvalPageTypeLabel() {
        const map = { leave:'Leave Request', timesheet:'Timesheet Entry', wfh:'WFH Request' };
        return map[this.approvalPageType] || 'Request';
    }
    get isApprovalLeave()     { return this.approvalPageType==='leave'; }
    get isApprovalTimesheet() { return this.approvalPageType==='timesheet'; }
    get isApprovalWfh()       { return this.approvalPageType==='wfh'; }

    get tsSubTabEntriesClass() { return `ts-subtab-btn${this.tsSubTab==='entries'?' ts-subtab-active':''}`; }
    get tsSubTabWeeklyClass()  { return `ts-subtab-btn${this.tsSubTab==='weekly' ?' ts-subtab-active':''}`; }
    get isTsSubTabEntries() { return this.tsSubTab==='entries'; }
    get isTsSubTabWeekly()  { return this.tsSubTab==='weekly'; }

    get weeklyGroups() {
        if (!this.pendingTsAll || !this.pendingTsAll.length) return [];
        const getWeekStart = (dateStr) => {
            if (!dateStr) return null;
            const d = new Date(dateStr);
            if (isNaN(d.getTime())) return null;
            const day = d.getDay();
            const diff = day === 0 ? -6 : 1 - day;
            const mon = new Date(d);
            mon.setDate(d.getDate() + diff);
            mon.setHours(0, 0, 0, 0);
            return mon;
        };
        const getWeekEnd = (weekStart) => {
            const fri = new Date(weekStart);
            fri.setDate(weekStart.getDate() + 4);
            return fri;
        };
        const fmtShort = (d) => {
            if (!d) return '—';
            return new Date(d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' });
        };
        const parseHrs = (val) => parseFloat(String(val || '0').replace('h', '')) || 0;
        const hDisp = (h) => h > 0 ? `${h.toFixed(1)}h` : '—';
        const weekMap = {};
        for (const ts of this.pendingTsAll) {
            const rawDate = ts.rawDate || ts.date;
            const ws = getWeekStart(rawDate);
            if (!ws) continue;
            const weekKey = ws.toISOString().substring(0, 10);
            if (!weekMap[weekKey]) weekMap[weekKey] = { weekStart: ws, entries: [] };
            weekMap[weekKey].entries.push(ts);
        }
        const sortedKeys = Object.keys(weekMap).sort((a, b) => b.localeCompare(a));
        const totalWeeks = sortedKeys.length;
        return sortedKeys.map((weekKey, idx) => {
            const { weekStart, entries } = weekMap[weekKey];
            const weekEnd = getWeekEnd(weekStart);
            const isExpanded = this.expandedWeekKeys[weekKey] !== false;
            const empMap = {};
            for (const e of entries) {
                const empIdentifier = e.empId || e.empName || 'unknown';
                const empKey = `${weekKey}_${empIdentifier}`;
                if (!empMap[empKey]) {
                    empMap[empKey] = { empKey, empName: e.empName, empId: e.empId, empInitials: e.empInitials, entries: [], totalHrs: 0, billableHrs: 0, nonBillHrs: 0, shadowHrs: 0, pendingCount: 0, isProcessing: this.weeklyBulkProcessing[empKey] || false };
                }
                empMap[empKey].entries.push(e);
                const hrs = parseHrs(e.totalHrs);
                empMap[empKey].totalHrs += hrs;
                const billing = (e.billingStatus || '').toLowerCase().trim();
                if (billing === 'billable') empMap[empKey].billableHrs += hrs;
                else if (billing.includes('non') || billing === 'non-billable') empMap[empKey].nonBillHrs += hrs;
                else if (billing === 'shadow') empMap[empKey].shadowHrs += hrs;
                if (e.isPending) empMap[empKey].pendingCount++;
            }
            const employeeRows = Object.values(empMap).map(er => ({
                ...er,
                entryCount: er.entries.length,
                hasPendingEntries: er.pendingCount > 0,
                totalHrsDisplay: hDisp(er.totalHrs),
                billableHrsDisplay: hDisp(er.billableHrs),
                nonBillHrsDisplay: hDisp(er.nonBillHrs),
                shadowHrsDisplay: hDisp(er.shadowHrs),
                entries: er.entries.map(te => ({
                    ...te,
                    isDone: te.doneStatus != null,
                    doneLabel: te.doneStatus,
                    doneClass: te.doneStatus === 'Approved' ? 'done-badge done-badge--approved' : 'done-badge done-badge--rejected',
                    entryRowClass: te.doneStatus ? `weekly-entry-row weekly-entry-row--${te.doneStatus.toLowerCase()}` : 'weekly-entry-row',
                })),
            }));
            const totalHrs = entries.reduce((s, e) => s + parseHrs(e.totalHrs), 0);
            const pendingCount = entries.filter(e => e.isPending).length;
            return {
                weekKey,
                weekLabel: `Week ${totalWeeks - idx}`,
                dateRange: `${fmtShort(weekStart)} – ${fmtShort(weekEnd)}`,
                entryCount: entries.length,
                empCount: Object.keys(empMap).length,
                totalHrsDisplay: hDisp(totalHrs),
                pendingCount,
                hasPending: pendingCount > 0,
                isExpanded,
                collapseIcon: isExpanded ? '▾' : '▸',
                employeeRows,
            };
        });
    }
    get weeklyGroupCount() { return this.weeklyGroups.length; }

    // ═════════════════════════════════════════════════
    //  WIRE — TEAM MEMBERS
    // ═════════════════════════════════════════════════
    @wire(getMyTeamMembers)
    wiredTeam({ data, error }) {
        if (data) {
            this.noTeamMembers = false;
            if (!data.length) { this.noTeamMembers = true; return; }
            this.teamMembers = data.map((e, i) => ({
                ...e, initials: this._initials(e.Name), accentColor: COLORS[i % COLORS.length],
                isSelected: false, cardClass: 'emp-card',
            }));
            this._loadSummary();
            this._loadPendingCounts();
            this._loadPicklists();
        } else if (error) {
            this._toast('Error loading team', error.body?.message, 'error');
        }
    }

    // ═════════════════════════════════════════════════
    //  PICKLIST LOADING
    // ═════════════════════════════════════════════════
    async _loadPicklists() {
        if (this._picklistsLoaded) return;
        try {
            const [roles, statuses] = await Promise.all([
                getPicklistValues({ objectApiName:'Project_Assignment__c', fieldApiName:'Role__c' }),
                getPicklistValues({ objectApiName:'Project_Assignment__c', fieldApiName:'Employment_Status__c' }),
            ]);
            this.roleOptions             = roles.map(v=>({label:v,value:v}));
            this.employmentStatusOptions = statuses.map(v=>({label:v,value:v}));
            this._picklistsLoaded = true;
        } catch(e) {
            this.roleOptions = [];
            this.employmentStatusOptions = [];
        }
    }

    // ═════════════════════════════════════════════════
    //  ✅ CHANGE 1: DROPDOWN HANDLERS
    // ═════════════════════════════════════════════════
    handleAttMonthDropdownToggle(event) {
        event.stopPropagation();
        this.showAttMonthDropdown = !this.showAttMonthDropdown;
        this.showTsMonthDropdown  = false;
    }
    handleTsMonthDropdownToggle(event) {
        event.stopPropagation();
        this.showTsMonthDropdown  = !this.showTsMonthDropdown;
        this.showAttMonthDropdown = false;
    }
    handleAttMonthDropdownSelect(event) {
        event.stopPropagation();
        const view = event.currentTarget.dataset.view;
        this.summaryView = view;
        this.showAttMonthDropdown = false;
        this.showMoreMonths = false;
        this._loadSummaryAtt();
        // ✅ CHANGE 2: If drill is open, update its view to match
        if (this.drillEmp) {
            this.drillView = view;
            this._loadDrillData(this.drillEmp.contactId);
        }
    }
    handleTsMonthDropdownSelect(event) {
        event.stopPropagation();
        const view = event.currentTarget.dataset.view;
        this.tsView = view;
        this.showTsMonthDropdown = false;
        this._loadTsSummary();
    }
    // Close dropdowns when clicking outside
    handlePageClick() {
        this.showAttMonthDropdown = false;
        this.showTsMonthDropdown  = false;
    }

    // ═════════════════════════════════════════════════
    //  FILTER HANDLERS
    // ═════════════════════════════════════════════════
    handleFilterIconClick(event) { event.stopPropagation(); this.showFilterPopup=!this.showFilterPopup; }
    handleFilterPopupClose() { this.showFilterPopup=false; }
    handleChipClick(event) {
        const f=event.currentTarget.dataset.filter, v=event.currentTarget.dataset.value;
        this[f]=this[f]===v?'':v; this._applyDrillFilter();
    }
    handleSelectChange(event) { this[event.currentTarget.dataset.filter]=event.target.value; this._applyDrillFilter(); }
    handleClearAllFilters() {
        if (this.isLvPanel) this.lvFilterType='';
        else if (this.isTsPanel) { this.tsFilterProject=''; this.tsFilterBilling=''; }
        else this.attFilterStatus='';
        this._applyDrillFilter();
    }

    // ═════════════════════════════════════════════════
    //  TOGGLE / VIEW HANDLERS
    // ═════════════════════════════════════════════════
    handleSummaryToggle() {
        this.activeSummaryTab=this.activeSummaryTab==='attendance'?'timesheet':'attendance';
        if (this.drillEmp) this.drillTab=this.activeSummaryTab==='timesheet'?'timesheet':'attendance';
    }
    handleMainViewChange(event) {
        const v = event.currentTarget.dataset.view;
        this.mainView = v;
        this._isApprovalPage = false;
        this.showAttMonthDropdown = false;
        this.showTsMonthDropdown  = false;
        if (v==='summary'&&this.teamMembers.length) this._loadSummary();
        if (v==='pending'&&this.teamMembers.length) this._loadPendingAll();
    }
    handleSummaryViewChange(event) {
        const tbl=event.currentTarget.dataset.tbl, view=event.currentTarget.dataset.view;
        if (tbl==='att') {
            this.summaryView=view;
            this.showAttMonthDropdown=false;
            this._loadSummaryAtt();
            // ✅ CHANGE 2: sync drill view
            if (this.drillEmp) {
                this.drillView = view;
                this._loadDrillData(this.drillEmp.contactId);
            }
        } else {
            this.tsView=view;
            this.showTsMonthDropdown=false;
            this._loadTsSummary();
        }
    }
    handlePendingTabChange(event) { this.pendingView=event.currentTarget.dataset.tab; }

    handleApprovalPageBack() {
        this._isApprovalPage = false;
        this.mainView = 'pending';
    }

    // ═════════════════════════════════════════════════
    //  SUMMARY ROW CLICK
    // ═════════════════════════════════════════════════
    handleSummaryRowClick(event) {
        const cId=event.currentTarget.dataset.id, type=event.currentTarget.dataset.type;
        if (!cId) return;
        const member=this.teamMembers.find(e=>e.Id===cId);
        if (!member) return;
        if (this.drillEmp?.contactId===cId&&this.drillTab===(type==='ts'?'timesheet':'attendance')) {
            this.drillEmp=null; this._clearRowHighlights(); return;
        }
        this.drillEmp={contactId:cId,name:member.Name,employeeId:member.Employee_Id__c||'',initials:member.initials};
        this.drillTab=type==='ts'?'timesheet':'attendance';
        // ✅ CHANGE 2: Drill inherits the current summary month — NOT default to current month
        this.drillView = type==='ts' ? this.tsView : this.summaryView;
        // Normalise tsView 'monthly' → actual month key for drill
        if (this.drillView === 'monthly') {
            this.drillView = `month_${new Date().getMonth()}`;
        }
        this._resetAllFilters();
        this._highlightRows(cId);
        this._loadDrillData(cId);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(()=>{ this._scrollToDrillPanel(); },120);
    }
    _scrollToDrillPanel() { const p=this.template.querySelector('.drill-panel'); if(p) p.scrollIntoView({behavior:'smooth',block:'start'}); }
    _highlightRows(cId) {
        this.summaryRows   =this.summaryRows.map(r=>({...r,attRowClass:r.contactId===cId?'sum-row sum-row--active':'sum-row'}));
        this.tsSummaryRows=this.tsSummaryRows.map(r=>({...r,tsRowClass:r.contactId===cId?'sum-row sum-row--active ts-row--active':'sum-row'}));
    }
    _clearRowHighlights() {
        this.summaryRows   =this.summaryRows.map(r=>({...r,attRowClass:'sum-row'}));
        this.tsSummaryRows=this.tsSummaryRows.map(r=>({...r,tsRowClass:'sum-row'}));
    }

    // ═════════════════════════════════════════════════
    //  DRILL PANEL CONTROLS
    // ═════════════════════════════════════════════════
    handleDrillClose() { this.drillEmp=null; this.showFilterPopup=false; this._clearRowHighlights(); this._resetAllFilters(); }
    handleDrillTabChange(event) {
        this.drillTab=event.currentTarget.dataset.tab;
        this.showFilterPopup=false;
        this._resetAllFilters();
        this._applyDrillFilter();
    }
    // ✅ CHANGE 2: handleDrillViewChange still exists but drill panel no longer shows month buttons
    // Kept for any programmatic use
    handleDrillViewChange(event) {
        this.drillView=event.currentTarget.dataset.view;
        this.showFilterPopup=false;
        if (this.drillEmp) this._loadDrillData(this.drillEmp.contactId); else this._applyDrillFilter();
    }

    // Weekly sub-tab
    handleTsSubTabChange(event) { this.tsSubTab = event.currentTarget.dataset.subtab; }
    handleWeekGroupToggle(event) {
        const weekKey = event.currentTarget.dataset.weekkey;
        const current = this.expandedWeekKeys[weekKey];
        const next = current === false ? true : false;
        this.expandedWeekKeys = { ...this.expandedWeekKeys, [weekKey]: next };
    }
    handleApprovalCommentsChange(event)    { this.approvalComments    = event.target.value; }
    handleApprovalMailBodyChange(event)    { this.approvalMailBody    = event.target.value; }
    handleApprovalMailSubjectChange(event) { this.approvalMailSubject = event.target.value; }

    async handleWeeklyBulkApprove(event) {
        const empKey = event.currentTarget.dataset.empkey;
        const toApprove = this._getEmpWeekEntries(empKey).filter(e => e.isPending);
        if (!toApprove.length) return;
        this.weeklyBulkProcessing = { ...this.weeklyBulkProcessing, [empKey]: true };
        try {
            for (const ts of toApprove) {
                await updateTimesheetStatus({ timesheetEntryId: ts.id, newStatus: 'Approved', comments: '' });
            }
            this._toast('Done', `${toApprove.length} timesheet entries approved.`, 'success');
            this.pendingTsAll = this.pendingTsAll.map(e => {
                const isTarget = toApprove.some(t => t.id === e.id);
                return isTarget ? { ...e, isPending: false, isProcessing: false, doneStatus: 'Approved' } : e;
            });
            this._loadPendingCounts();
        } catch (err) {
            this._toast('Error', err.body?.message || err.message, 'error');
        } finally {
            this.weeklyBulkProcessing = { ...this.weeklyBulkProcessing, [empKey]: false };
        }
    }

    async handlePendingRejectConfirm() {
        if (!this.pendingRejectReason?.trim()) { this._toast('Required', 'Please enter a rejection reason.', 'warning'); return; }
        this.showRejectModalPending = false;
        const reason = this.pendingRejectReason.trim();
        this.pendingRejectReason = '';
        if (this.pendingRejectTargetId === '__bulk_weekly__') {
            const ids = this._weeklyBulkRejectIds || [];
            const empKey = this._weeklyBulkRejectEmpKey;
            this._weeklyBulkRejectIds = null;
            this._weeklyBulkRejectEmpKey = null;
            this.pendingRejectTargetId = null;
            this.weeklyBulkProcessing = { ...this.weeklyBulkProcessing, [empKey]: true };
            try {
                for (const id of ids) { await updateTimesheetStatus({ timesheetEntryId: id, newStatus: 'Rejected', comments: reason }); }
                this._toast('Done', `${ids.length} timesheet entries rejected.`, 'success');
                this.pendingTsAll = this.pendingTsAll.map(e => { const isTarget = ids.includes(e.id); return isTarget ? { ...e, isPending: false, isProcessing: false, doneStatus: 'Rejected' } : e; });
                this._loadPendingCounts();
            } catch (err) { this._toast('Error', err.body?.message || err.message, 'error'); }
            finally { this.weeklyBulkProcessing = { ...this.weeklyBulkProcessing, [empKey]: false }; }
            return;
        }
        const id = this.pendingRejectTargetId;
        this.pendingRejectTargetId = null;
        if (this.pendingRejectIsWfh) { this.pendingRejectIsWfh = false; await this._doPendingWfh(id, 'Rejected', reason); }
        else if (this.pendingRejectIsTs) { await this._doPendingTs(id, 'Rejected', reason); }
        else { await this._doPendingLeave(id, 'Rejected', reason); }
    }

    _getEmpWeekEntries(empKey) {
        const parts = empKey.split('_');
        const weekDateStr = parts[0];
        const empId = parts.slice(1).join('_');
        const ws = new Date(weekDateStr);
        const we = new Date(ws); we.setDate(ws.getDate() + 6);
        return this.pendingTsAll.filter(e => {
            const matchEmp = (e.empId || e.empName) === empId;
            if (!matchEmp) return false;
            const d = new Date(e.rawDate);
            return d >= ws && d <= we;
        });
    }

    // ═════════════════════════════════════════════════
    //  DRILL DATA
    // ═════════════════════════════════════════════════
    async _loadDrillData(contactId) {
        this.drillLoading=true;
        try {
            const [att,tsE,leaves]=await Promise.all([
                getAttendanceRecords({contactId}),
                getTimesheetEntries({contactId}),
                getTeamMemberLeaves({contactId,viewType:this.drillView}),
            ]);
            this._rawDrillAtt=att.map(r=>{
                const dv=r.Date__c||r.CreatedDate;
                return {...r,displayDate:this._fmtDate(dv),displayDay:this._fmtDay(dv),
                    displayCheckIn:r.Check_In_Time__c?this._fmtDateTime(r.Check_In_Time__c):'—',
                    displayCheckOut:r.Check_Out_Time__c?this._fmtDateTime(r.Check_Out_Time__c):'—',
                    displayLocation:r.Work_Location__c||r.Check_In_Location_Name__c||'—',
                    wfhStatus:r.WFH_Approval_Status__c||'—',odStatus:r.OD_Approval_Status__c||'—',
                    statusBadge:`status-badge status-${(r.Status__c||'').toLowerCase().replace(/\s+/g,'_')}`,_dateVal:dv};
            });
            this._rawDrillTs=tsE.map(e=>({...e,
                displayDate:this._fmtDate(e.Date__c),
                displayStart:e.Start_Time__c?this._fmtTime(e.Start_Time__c):'—',
                displayEnd:e.End_Time__c?this._fmtTime(e.End_Time__c):'—',
                totalHrs:e.Total_Hours__c!=null?`${e.Total_Hours__c}h`:'—',
                projectName:e.Project__r?.Name||e.Project__c||'—',
                billingBadge:`status-badge billing-${(e.Billing_Status__c||'default').toLowerCase().replace(/[^a-z]/g,'_')}`,
                statusBadge:`status-badge status-${(e.Status__c||'').toLowerCase()}`,
                approvalBadge:`status-badge status-${(e.Approval_Status__c||'').toLowerCase().replace(/\s+/g,'_')}`,
                _dateVal:e.Date__c}));
            this._rawDrillLeave=leaves.map(lv=>({...lv,
                displayStartDate:this._fmtDate(lv.startDate),displayEndDate:this._fmtDate(lv.endDate),
                displayApplied:this._fmtDate(lv.appliedDate),
                displayDays:lv.isHalfDay?'0.5 day':`${lv.totalDays} day(s)`,
                halfDayLabel:lv.isHalfDay?` (${lv.halfDayType})`:'',
                statusBadge:`status-badge status-${(lv.status||'').toLowerCase()}`,
                leaveType:lv.leaveType||'—'}));
            this._applyDrillFilter();
        } catch(e) { this._toast('Error','Failed to load detail records: '+(e.body?.message||e.message),'error'); }
        finally { this.drillLoading=false; }
    }

    _applyDrillFilter() {
        const {startDate,endDate}=this._getDrillDateRange();
        this.drillAttRecords=this._rawDrillAtt.filter(r=>{
            if(!r._dateVal) return false;
            const d=new Date(r._dateVal);
            if(d<startDate||d>endDate) return false;
            if(this.attFilterStatus&&!(r.Status__c||'').toLowerCase().includes(this.attFilterStatus.toLowerCase())) return false;
            return true;
        }).sort((a,b)=>new Date(b._dateVal)-new Date(a._dateVal));
        this.drillTsRecords=this._rawDrillTs.filter(r=>{
            if(!r._dateVal) return false;
            const d=new Date(r._dateVal);
            if(d<startDate||d>endDate) return false;
            if(this.tsFilterProject&&r.projectName!==this.tsFilterProject) return false;
            if(this.tsFilterBilling&&!(r.Billing_Status__c||'').toLowerCase().includes(this.tsFilterBilling.toLowerCase())) return false;
            return true;
        }).sort((a,b)=>new Date(b._dateVal)-new Date(a._dateVal));
        this.drillLeaveRecords=this._rawDrillLeave.filter(r=>!(this.lvFilterType&&r.leaveType!==this.lvFilterType));
    }

    _getDrillDateRange() {
        const now=new Date(), today=new Date(now.getFullYear(),now.getMonth(),now.getDate());
        if (this.drillView==='today') return {startDate:today,endDate:new Date(today.getTime()+86399999)};
        if (this.drillView==='weekly') {
            const day=today.getDay(),diff=day===0?-6:1-day,mon=new Date(today);
            mon.setDate(today.getDate()+diff);
            return {startDate:mon,endDate:new Date(today.getTime()+86399999)};
        }
        if (this.drillView?.startsWith('month_')) {
            const mi=parseInt(this.drillView.substring(6),10),yr=now.getFullYear(),start=new Date(yr,mi,1);
            const end=mi===now.getMonth()?new Date(today.getTime()+86399999):new Date(yr,mi+1,0,23,59,59,999);
            return {startDate:start,endDate:end};
        }
        return {startDate:new Date(now.getFullYear(),now.getMonth(),1),endDate:new Date(now.getTime()+86399999)};
    }
    _getDrillPeriodStart() {
        const now=new Date(),day=now.getDay(),diff=day===0?-6:1-day,mon=new Date(now);
        mon.setDate(now.getDate()+diff); mon.setHours(0,0,0,0); return mon;
    }
    _resetAllFilters() { this.attFilterStatus=''; this.tsFilterProject=''; this.tsFilterBilling=''; this.lvFilterType=''; }

    _setPendingLvProcessing(id, processing) {
        this.pendingLeaveAll = this.pendingLeaveAll.map(r => r.id !== id ? r : { ...r, isPending: !processing, isProcessing: processing });
    }
    _setPendingTsProcessing(id, processing) {
        this.pendingTsAll = this.pendingTsAll.map(r => r.id !== id ? r : { ...r, isPending: !processing, isProcessing: processing });
    }
    _setPendingWfhProcessing(id, processing) {
        this.pendingWfhAll = this.pendingWfhAll.map(r => r.id !== id ? r : { ...r, isPending: !processing, isProcessing: processing });
    }

    // ═════════════════════════════════════════════════
    //  SUMMARY LOADING
    // ═════════════════════════════════════════════════
    _loadSummary() { this._loadSummaryAtt(); this._loadTsSummary(); }

    async _loadSummaryAtt() {
        if (!this.teamMembers.length) return;
        this.summaryLoading=true;
        try {
            const rows=await getTeamSummary({contactIds:this.teamMembers.map(e=>e.Id),viewType:this.summaryView});
            const aid=this.drillEmp?.contactId;
            this.summaryRows=rows.map(r=>({...r,initials:this._initials(r.name),rateDisplay:`${r.rate}%`,
                rateClass:r.rate>=85?'sum-rate good':r.rate>=70?'sum-rate warn':'sum-rate bad',
                lopDisplay:r.lop>0?r.lop:'—',leaveDisplay:r.leaveDays>0?r.leaveDays:'—',hrsDisplay:r.totalHrs>0?`${r.totalHrs}h`:'—',
                attRowClass:r.contactId===aid?'sum-row sum-row--active':'sum-row'}));
        } catch(e) { this._toast('Warning','Attendance summary unavailable: '+(e.body?.message||e.message),'warning'); }
        finally { this.summaryLoading=false; }
    }

    async _loadPendingCounts() {
        if (!this.teamMembers.length) return;
        this.pendingCountsLoading=true;
        try {
            const result=await getPendingApprovalCounts({contactIds:this.teamMembers.map(e=>e.Id)});
            this.pendingLeaveCount = result.leaveCount      || 0;
            this.pendingTsCount    = result.timesheetCount  || 0;
            this.pendingWfhCount   = result.wfhCount        || 0;
        } catch(e) { /* silent */ }
        finally { this.pendingCountsLoading=false; }
    }
    handleRefreshCounts() { this._loadPendingCounts(); }

    async _loadTsSummary() {
        if (!this.teamMembers.length) return;
        this.tsSummaryLoading=true;
        try {
            const rows=await getTeamTimesheetSummary({contactIds:this.teamMembers.map(e=>e.Id),viewType:this.tsView});
            const aid=this.drillEmp?.contactId;
            this.tsSummaryRows=rows.map(r=>({...r,initials:this._initials(r.name),
                loggedBillableDisplay:r.loggedBillable>0?`${r.loggedBillable}h`:'—',loggedNonBillableDisplay:r.loggedNonBillable>0?`${r.loggedNonBillable}h`:'—',
                loggedShadowDisplay:r.loggedShadow>0?`${r.loggedShadow}h`:'—',loggedTotalDisplay:r.loggedTotal>0?`${r.loggedTotal}h`:'—',
                approvedBillableDisplay:r.approvedBillable>0?`${r.approvedBillable}h`:'—',approvedNonBillableDisplay:r.approvedNonBillable>0?`${r.approvedNonBillable}h`:'—',
                approvedShadowDisplay:r.approvedShadow>0?`${r.approvedShadow}h`:'—',approvedTotalDisplay:r.approvedTotal>0?`${r.approvedTotal}h`:'—',
                rejectedBillableDisplay:r.rejectedBillable>0?`${r.rejectedBillable}h`:'—',rejectedNonBillableDisplay:r.rejectedNonBillable>0?`${r.rejectedNonBillable}h`:'—',
                rejectedShadowDisplay:r.rejectedShadow>0?`${r.rejectedShadow}h`:'—',rejectedTotalDisplay:r.rejectedTotal>0?`${r.rejectedTotal}h`:'—',
                prodBillableDisplay:`${r.prodBillable||0}%`,prodNonBillableDisplay:`${r.prodNonBillable||0}%`,
                prodShadowDisplay:`${r.prodShadow||0}%`,prodTotalDisplay:`${r.productivityRate||0}%`,
                prodTotalClass:(r.productivityRate||0)>=80?'sum-rate good':(r.productivityRate||0)>=60?'sum-rate warn':'sum-rate bad',
                tsRowClass:r.contactId===aid?'sum-row sum-row--active ts-row--active':'sum-row'}));
        } catch(e) {
            this._toast('Info','Timesheet summary unavailable.','warning');
            this.tsSummaryRows=[];
        } finally { this.tsSummaryLoading=false; }
    }

    // ═════════════════════════════════════════════════
    //  EMPLOYEE VIEW
    // ═════════════════════════════════════════════════
    handleEmpSelect(event) { this._select(event.currentTarget.dataset.id); }
    _select(id) {
        this.selectedEmpId=id; this.selectedEmp=this.teamMembers.find(e=>e.Id===id);
        this.activeTab='attendance';
        this.teamMembers=this.teamMembers.map(e=>({...e,isSelected:e.Id===id,cardClass:e.Id===id?'emp-card emp-card--active':'emp-card'}));
        this._loadData(id);
    }
    handleTabClick(event) {
        this.activeTab=event.currentTarget.dataset.tab;
        if (this.activeTab==='projects'&&this.selectedEmpId) this._loadProjectData(this.selectedEmpId);
    }
    async _loadData(contactId) {
        this.isLoading=true;
        try {
            const [att,ts,entries,lv,sum]=await Promise.all([
                getAttendanceRecords({contactId}),getTimesheetRecords({contactId}),
                getTimesheetEntries({contactId}),getLeaveRequests({contactId}),
                getMonthlyAttendanceSummary({contactId}),
            ]);
            this.attendanceRecords=att.map(r=>{
                const dv=r.Date__c||r.CreatedDate;
                return {...r,displayDate:this._fmtDate(dv),displayDay:this._fmtDay(dv),
                    displayCheckIn:r.Check_In_Time__c?this._fmtDateTime(r.Check_In_Time__c):'—',
                    displayCheckOut:r.Check_Out_Time__c?this._fmtDateTime(r.Check_Out_Time__c):'—',
                    displayHours:r.Hours_Worked__c!=null?`${r.Hours_Worked__c}h`:'—',
                    displayLocation:r.Work_Location__c||r.Check_In_Location_Name__c||'—',
                    wfhStatus:r.WFH_Approval_Status__c||'—',odStatus:r.OD_Approval_Status__c||'—',
                    statusBadge:`status-badge status-${(r.Status__c||'').toLowerCase().replace(/\s+/g,'_')}`};
            });
            const sheetMap={};
            ts.forEach(r=>{sheetMap[r.Id]=r.Name;});
            this.timesheetRecords=entries.map(e=>({...e,
                displayDate:this._fmtDate(e.Date__c),
                displayStart:e.Start_Time__c?this._fmtTime(e.Start_Time__c):'—',
                displayEnd:e.End_Time__c?this._fmtTime(e.End_Time__c):'—',
                regularHrs:e.Regular_Hours__c!=null?`${e.Regular_Hours__c}h`:'—',
                overtimeHrs:e.Overtime_Hours__c!=null?`${e.Overtime_Hours__c}h`:'—',
                totalHrs:e.Total_Hours__c!=null?`${e.Total_Hours__c}h`:'—',
                projectName:e.Project__r?.Name||e.Project__c||'—',
                tsName:sheetMap[e.Timesheet__c]||e.Timesheet__r?.Name||'—',
                billingBadge:`status-badge billing-${(e.Billing_Status__c||'default').toLowerCase().replace(/[^a-z]/g,'_')}`,
                statusBadge:`status-badge status-${(e.Status__c||'').toLowerCase()}`,
                approvalBadge:`status-badge status-${(e.Approval_Status__c||'').toLowerCase().replace(/\s+/g,'_')}`}));
            this.leaveRequests=this._mapLeaveRecords(lv);
            this.attendanceSummary={...sum,rateDisplay:`${sum.rate}%`};
        } catch(e) { this._toast('Error loading records',e.body?.message,'error'); }
        finally { this.isLoading=false; }
    }

    // ═════════════════════════════════════════════════
    //  LEAVE ACTIONS (employee tab)
    // ═════════════════════════════════════════════════
    async handleApprove(event) {
        const id=event.currentTarget.dataset.id;
        this._setLeaveProcessing(id,true);
        await this._doLeave(id,'Approved','');
    }
    handleRejectClick(event) {
        this.pendingRejectId=event.currentTarget.dataset.id;
        this.rejectReason=''; this.showRejectModal=true;
        this._setLeaveProcessing(this.pendingRejectId,true);
    }
    handleReasonChange(event) { this.rejectReason=event.target.value; }
    handleModalClose() {
        if (this.pendingRejectId) this._setLeaveProcessing(this.pendingRejectId,false);
        this.showRejectModal=false; this.pendingRejectId=null; this.rejectReason='';
    }
    handleModalStopProp(event) { event.stopPropagation(); }
    async handleRejectConfirm() {
        if (!this.rejectReason?.trim()) { this._toast('Required','Please enter a rejection reason.','warning'); return; }
        this.showRejectModal=false;
        await this._doLeave(this.pendingRejectId,'Rejected',this.rejectReason.trim());
        this.pendingRejectId=null; this.rejectReason='';
    }
    async _doLeave(id,status,reason) {
        try {
            await updateLeaveStatus({leaveRequestId:id,newStatus:status,comments:reason||''});
            this._toast('Done',`Leave request ${status.toLowerCase()} successfully.`,'success');
            const newStatus=status.toLowerCase();
            this.leaveRequests=this.leaveRequests.map(r=>{
                if (r.Id!==id) return r;
                return {...r,Status__c:status,isPending:false,isProcessing:false,isApproved:newStatus==='approved',isRejected:newStatus==='rejected',statusBadge:`status-badge status-${newStatus}`,cardClass:`leave-card leave-card--${newStatus}`};
            });
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(async()=>{
                try { const fresh=await getLeaveRequestsUncached({contactId:this.selectedEmpId}); this.leaveRequests=this._mapLeaveRecords(fresh); } catch(e2) { /* silent */ }
            },1000);
        } catch(e) {
            this._setLeaveProcessing(id,false);
            this._toast('Error',e.body?.message||e.message,'error');
        }
    }
    _setLeaveProcessing(id,processing) {
        this.leaveRequests=this.leaveRequests.map(r=>r.Id!==id?r:{...r,isPending:!processing,isProcessing:processing});
    }

    // ═════════════════════════════════════════════════
    //  PENDING VIEW NAVIGATION
    // ═════════════════════════════════════════════════
    handlePendingLeaveClick() { this.mainView='pending'; this.pendingView='leave';     this._isApprovalPage=false; this._loadPendingAll(); }
    handlePendingTsClick()    { this.mainView='pending'; this.pendingView='timesheet'; this._isApprovalPage=false; this._loadPendingAll(); }
    handlePendingWfhClick()   { this.mainView='pending'; this.pendingView='wfh';       this._isApprovalPage=false; this._loadPendingAll(); }

    async _loadPendingAll() {
        if (!this.teamMembers.length) return;
        this.pendingViewLoading=true;
        try {
            const contactIds=this.teamMembers.map(e=>e.Id);
            let leaves=[],sheets=[],wfhs=[];
            try { leaves=await getPendingLeaveAll({contactIds}); }     catch(e1){ console.error('leaves',e1); }
            try { sheets=await getPendingTimesheetAll({contactIds}); } catch(e2){ console.error('sheets',e2); }
            try { wfhs=await getPendingWfhAll({contactIds}); }         catch(e3){ console.error('wfhs',e3); }
            this.pendingLeaveAll=(leaves||[]).map(r=>({...r,displayFrom:this._fmtDate(r.startDate),displayTo:this._fmtDate(r.endDate),displayDays:r.isHalfDay?'0.5d':`${r.totalDays}d`,displayType:r.leaveType||'—',displayReason:r.reason||'—',isPending:true,isProcessing:false,empName:r.employeeName||'—',empId:r.employeeId||'—',empInitials:r.empInitials||this._initials(r.employeeName||'')}));
            this.pendingTsAll=(sheets||[]).map(e=>({...e,rawDate:e.date,displayDate:this._fmtDate(e.date),displayStart:e.startTime?this._fmtTime(e.startTime):'—',displayEnd:e.endTime?this._fmtTime(e.endTime):'—',displayTime:(e.startTime&&e.endTime)?`${this._fmtTime(e.startTime)} – ${this._fmtTime(e.endTime)}`:'—',regularHrs:e.regularHours!=null?`${e.regularHours}h`:'—',overtimeHrs:e.overtimeHours!=null?`${e.overtimeHours}h`:'—',totalHrs:e.totalHours!=null?`${e.totalHours}h`:'—',projectName:e.projectName||'—',taskName:e.task||'—',billingStatus:e.billingStatus||'—',entryStatus:e.status||'—',approvalStatus:e.approvalStatus||'Submitted',billingBadge:`status-badge billing-${(e.billingStatus||'default').toLowerCase().replace(/[^a-z]/g,'_')}`,statusBadge:`status-badge status-${(e.status||'').toLowerCase()}`,approvalBadge:`status-badge status-submitted`,empName:e.employeeName||'—',empId:e.employeeId||'—',empInitials:e.empInitials||this._initials(e.employeeName||''),sheetId:e.timesheetId||'',isPending:true,isProcessing:false}));
            this.pendingWfhAll=(wfhs||[]).map(r=>({...r,displayFrom:this._fmtDate(r.startDate),displayTo:this._fmtDate(r.endDate),displayReason:r.reason||'—',empName:r.employeeName||'—',empId:r.employeeId||'—',empInitials:r.empInitials||this._initials(r.employeeName||''),isPending:true,isProcessing:false}));
            this.pendingWfhCount=this.pendingWfhAll.length;
        } catch(e) {
            this._toast('Error','Failed to load pending approvals: '+(e.body?.message||e.message),'error');
        } finally { this.pendingViewLoading=false; }
    }

    // ═════════════════════════════════════════════════
    //  OPEN FULL APPROVAL PAGE
    // ═════════════════════════════════════════════════
    handleOpenApprovalPage(event) {
        const ds = event.currentTarget.dataset;
        const type = ds.type;
        this.approvalPageType             = type;
        this.approvalComments             = '';
        this.approvalPageRejectReason     = '';
        this.showApprovalPageRejectReason = false;
        this.approvalPageProcessing       = false;
        if (type === 'leave') {
            const rec = this.pendingLeaveAll.find(r => r.id === ds.id);
            this.approvalData = { id:ds.id, empName:ds.name, empId:ds.empid, empInitials:rec?.empInitials||this._initials(ds.name), leaveType:ds.leavetype||'—', from:ds.from, to:ds.to, days:ds.days, reason:ds.reason||'—' };
            this.approvalMailSubject = `Re: Your Leave Request (${ds.leavetype}) – ${ds.from} to ${ds.to}`;
            this.approvalMailBody    = `Dear ${ds.name},\n\nThis is regarding your ${ds.leavetype} leave request from ${ds.from} to ${ds.to}.\n\nRegards,\n${this.managerName}`;
        } else if (type === 'timesheet') {
            const rec = this.pendingTsAll.find(r => r.id === ds.id);
            this.approvalData = { id:ds.id, empName:ds.name, empId:ds.empid, empInitials:rec?.empInitials||this._initials(ds.name), date:ds.date, project:ds.project||'—', task:ds.task||'—', time:ds.time||'—', totalHrs:ds.total||'—', billingStatus:ds.billing||'—' };
            this.approvalMailSubject = `Re: Your Timesheet Entry – ${ds.date}`;
            this.approvalMailBody    = `Dear ${ds.name},\n\nThis is regarding your timesheet entry dated ${ds.date} for project ${ds.project}.\n\nRegards,\n${this.managerName}`;
        } else if (type === 'wfh') {
            const rec = this.pendingWfhAll.find(r => r.id === ds.id);
            this.approvalData = { id:ds.id, empName:ds.name, empId:ds.empid, empInitials:rec?.empInitials||this._initials(ds.name), from:ds.from, to:ds.to, reason:ds.reason||'—' };
            this.approvalMailSubject = `Re: Your WFH Request – ${ds.from} to ${ds.to}`;
            this.approvalMailBody    = `Dear ${ds.name},\n\nThis is regarding your WFH request from ${ds.from} to ${ds.to}.\n\nRegards,\n${this.managerName}`;
        }
        this._isApprovalPage = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const el = this.template.querySelector('.approval-page-root');
            if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }, 100);
    }

    async handleApprovalPageApprove() {
        this.approvalPageProcessing = true;
        const id       = this.approvalData.id;
        const comments = this.approvalComments?.trim() || '';
        try { await this._doApprovalDecision(id, 'Approved', comments); }
        catch(e) { this.approvalPageProcessing = false; this._toast('Error', e.body?.message || e.message, 'error'); return; }
        this._toast('Done', `${this.approvalPageTypeLabel} approved successfully.`, 'success');
        this.approvalPageProcessing = false;
        this.mainView = 'pending';
        this._isApprovalPage = false;
        if (this.approvalMailBody?.trim() || comments) { this._sendMail(id, 'Approved').catch(e => console.warn('Mail skipped:', e)); }
        this._loadPendingCounts();
        this._loadPendingAll();
    }
    handleApprovalPageRejectOpen()   { this.showApprovalPageRejectReason = true; this.approvalPageRejectReason = ''; }
    handleApprovalPageRejectCancel() { this.showApprovalPageRejectReason = false; }
    handleApprovalPageRejectReasonChange(event) { this.approvalPageRejectReason = event.target.value; }
    async handleApprovalPageRejectConfirm() {
        if (!this.approvalPageRejectReason?.trim()) { this._toast('Required', 'Please enter a rejection reason.', 'warning'); return; }
        this.approvalPageProcessing = true;
        this.showApprovalPageRejectReason = false;
        const id     = this.approvalData.id;
        const reason = this.approvalPageRejectReason.trim();
        try { await this._doApprovalDecision(id, 'Rejected', reason); }
        catch(e) { this.approvalPageProcessing = false; this._toast('Error', e.body?.message || e.message, 'error'); return; }
        this._toast('Done', `${this.approvalPageTypeLabel} rejected.`, 'success');
        this.approvalPageProcessing = false;
        this.mainView = 'pending';
        this._isApprovalPage = false;
        if (this.approvalMailBody?.trim() || reason) { this._sendMail(id, 'Rejected').catch(e => console.warn('Mail skipped:', e)); }
        this._loadPendingCounts();
        this._loadPendingAll();
    }

    connectedCallback() { this._componentMounted = true; }
    renderedCallback() {
        if (this._renderedOnce) return;
        this._renderedOnce = true;
        if (this.teamMembers?.length > 0 && !this.summaryRows?.length && !this.summaryLoading) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                if (this.teamMembers?.length > 0) { this.noTeamMembers = false; this._loadSummary(); this._loadPendingCounts(); }
            }, 200);
        }
    }

    async _doApprovalDecision(id, status, comments) {
        const type = this.approvalPageType;
        if (type==='leave')     await updateLeaveStatus({leaveRequestId:id, newStatus:status, comments});
        else if (type==='timesheet') await updateTimesheetStatus({timesheetEntryId:id, newStatus:status, comments});
        else if (type==='wfh')  await updateWfhStatus({attendanceId:id, newStatus:status, comments});
    }
    async _sendMail(recordId, decision) {
        try {
            const decisionLine = decision === 'Approved' ? `✅ Your request has been APPROVED.` : `❌ Your request has been REJECTED.`;
            const fullBody = `${decisionLine}\n\n${this.approvalMailBody?.trim() || ''}`.trim();
            await sendApprovalEmail({ recordId, recordType:this.approvalPageType, decision, subject:this.approvalMailSubject?.trim(), body:fullBody, comments:this.approvalComments?.trim() || '' });
        } catch(e) { console.warn('Email send skipped:', e.message || e); }
    }
    async _sendAutoNotification(recordId, recordType, decision, reason) {
        try {
            const decisionLine = decision === 'Approved' ? `✅ Your ${recordType} request has been APPROVED.` : `❌ Your ${recordType} request has been REJECTED.`;
            const body = reason ? `${decisionLine}\n\nReason: ${reason}` : `${decisionLine}\n\nThis action was taken by your manager.`;
            await sendApprovalEmail({ recordId, recordType, decision, subject:`Your ${recordType} request has been ${decision} – Action Required`, body, comments:reason||'' });
        } catch (e) { console.warn('Auto notification email failed:', e.message || e); }
    }

    // ═════════════════════════════════════════════════
    //  PENDING LIST — QUICK REJECT MODAL
    // ═════════════════════════════════════════════════
    handlePendingRejectClick(event) {
        this.pendingRejectTargetId=event.currentTarget.dataset.id; this.pendingRejectIsTs=false; this.pendingRejectIsWfh=false;
        this.pendingRejectReason=''; this.showRejectModalPending=true;
        this._setPendingLvProcessing(this.pendingRejectTargetId,true);
    }
    handlePendingTsRejectClick(event) {
        this.pendingRejectTargetId=event.currentTarget.dataset.id; this.pendingRejectIsTs=true; this.pendingRejectIsWfh=false;
        this.pendingRejectReason=''; this.showRejectModalPending=true;
        this._setPendingTsProcessing(this.pendingRejectTargetId,true);
    }
    handlePendingWfhRejectClick(event) {
        this.pendingRejectTargetId=event.currentTarget.dataset.id; this.pendingRejectIsTs=false; this.pendingRejectIsWfh=true;
        this.pendingRejectReason=''; this.showRejectModalPending=true;
        this._setPendingWfhProcessing(this.pendingRejectTargetId,true);
    }
    handlePendingReasonChange(event) { this.pendingRejectReason=event.target.value; }
    handlePendingModalClose() {
        if (this.pendingRejectTargetId) {
            if (this.pendingRejectIsWfh)     this._setPendingWfhProcessing(this.pendingRejectTargetId,false);
            else if (this.pendingRejectIsTs) this._setPendingTsProcessing(this.pendingRejectTargetId,false);
            else                             this._setPendingLvProcessing(this.pendingRejectTargetId,false);
        }
        this.showRejectModalPending=false; this.pendingRejectTargetId=null;
        this.pendingRejectReason=''; this.pendingRejectIsTs=false; this.pendingRejectIsWfh=false;
    }

    async _doPendingLeave(id, status, reason) {
        try {
            await updateLeaveStatus({ leaveRequestId:id, newStatus:status, comments:reason||'' });
            this._toast('Done',`Leave ${status.toLowerCase()} successfully.`,'success');
            this.pendingLeaveAll=this.pendingLeaveAll.filter(r=>r.id!==id);
            this.pendingLeaveCount=this.pendingLeaveAll.length;
            await this._sendAutoNotification(id,'leave',status,reason);
            this._loadPendingCounts();
        } catch(e) { this._setPendingLvProcessing(id,false); this._toast('Error',e.body?.message||e.message,'error'); }
    }
    async _doPendingWfh(id, status, reason) {
        try {
            await updateWfhStatus({ attendanceId:id, newStatus:status, comments:reason||'' });
            this._toast('Done',`WFH request ${status.toLowerCase()} successfully.`,'success');
            this.pendingWfhAll=this.pendingWfhAll.filter(r=>r.id!==id);
            this.pendingWfhCount=this.pendingWfhAll.length;
            await this._sendAutoNotification(id,'wfh',status,reason);
            this._loadPendingCounts();
        } catch(e) { this._setPendingWfhProcessing(id,false); this._toast('Error',e.body?.message||e.message,'error'); }
    }
    async _doPendingTs(entryId, status, reason) {
        try {
            await updateTimesheetStatus({ timesheetEntryId:entryId, newStatus:status, comments:reason||'' });
            this._toast('Done',`Timesheet entry ${status.toLowerCase()} successfully.`,'success');
            this.pendingTsAll=this.pendingTsAll.filter(r=>r.id!==entryId);
            this.pendingTsCount=this.pendingTsAll.length;
            await this._sendAutoNotification(entryId,'timesheet',status,reason);
            this._loadPendingCounts();
        } catch(e) { this._setPendingTsProcessing(entryId,false); this._toast('Error',e.body?.message||e.message,'error'); }
    }

    // ═════════════════════════════════════════════════
    //  PROJECTS
    // ═════════════════════════════════════════════════
    async _loadProjectData(contactId) {
        try {
            const [assignments,projects]=await Promise.all([getProjectAssignments({contactId}),getActiveProjects()]);
            this.projectAssignments=assignments.map(pa=>({...pa,projectName:pa.Project__r?.Name||'—',projectNo:pa.Project__r?.Project_No__c||'—',projectType:pa.Project__r?.Project_Type__c||'—',projectStatus:pa.Project__r?.Status__c||'—',projectStart:this._fmtDate(pa.Project__r?.Start_Date__c),projectEnd:this._fmtDate(pa.Project__r?.End_Date__c)}));
            this.activeProjects=projects;
            await this._loadPicklists();
        } catch(e) { this._toast('Error','Failed to load project data: '+(e.body?.message||e.message),'error'); }
    }
    handleAssignProjectClick() {
        this.editingAssignmentId=null; this.projModalTitle='Assign Project to '+this.selectedEmp.Name;
        this.projModalSaveLabel='Assign'; this.projFormProjectId=this.projFormRole=this.projFormStatus='';
        if (!this.activeProjects.length) getActiveProjects().then(r=>{this.activeProjects=r;}).catch(()=>{});
        this._loadPicklists(); this.showProjModal=true;
    }
    handleEditAssignment(event) {
        this.editingAssignmentId=event.currentTarget.dataset.id; this.projModalTitle='Edit Assignment'; this.projModalSaveLabel='Save Changes';
        this.projFormProjectId=event.currentTarget.dataset.proj; this.projFormRole=event.currentTarget.dataset.role; this.projFormStatus=event.currentTarget.dataset.status;
        if (!this.activeProjects.length) getActiveProjects().then(r=>{this.activeProjects=r;}).catch(()=>{});
        this._loadPicklists(); this.showProjModal=true;
    }
    handleProjFormChange(event) { this[event.currentTarget.dataset.field]=event.target.value; }
    handleProjModalClose()      { this.showProjModal=false; }
    async handleProjModalSave() {
        if (!this.projFormProjectId) { this._toast('Required','Please select a project.','warning'); return; }
        if (!this.projFormRole)      { this._toast('Required','Please select a role.','warning'); return; }
        if (!this.projFormStatus)    { this._toast('Required','Please select employment status.','warning'); return; }
        try {
            if (this.editingAssignmentId) {
                await removeProjectAssignment({assignmentId:this.editingAssignmentId});
                await assignProjectToEmployees({contactIds:[this.selectedEmpId],projectId:this.projFormProjectId,role:this.projFormRole,employmentStatus:this.projFormStatus});
                this._toast('Updated','Project assignment updated successfully.','success');
            } else {
                const result=await assignProjectToEmployees({contactIds:[this.selectedEmpId],projectId:this.projFormProjectId,role:this.projFormRole,employmentStatus:this.projFormStatus});
                if (result.successCount>0) this._toast('Assigned','Project assigned successfully.','success');
                else if (result.duplicateCount>0) this._toast('Duplicate','Already assigned to this project.','warning');
                else this._toast('Error','Assignment failed.','error');
            }
            this.showProjModal=false;
            await this._loadProjectData(this.selectedEmpId);
        } catch(e) { this._toast('Error',e.body?.message||e.body?.pageErrors?.[0]?.message||'Unknown error','error'); }
    }
    async handleRemoveAssignment(event) {
        const id=event.currentTarget.dataset.id,name=event.currentTarget.dataset.name;
        try { await removeProjectAssignment({assignmentId:id}); this._toast('Removed',`Removed from project "${name}".`,'success'); await this._loadProjectData(this.selectedEmpId); }
        catch(e) { this._toast('Error',e.body?.message,'error'); }
    }

    handleApprovalFieldChange(event) { const field=event.currentTarget.dataset.field; this[field]=event.target.value; }
    handleWeeklyBulkReject(event) {
        const empKey=event.currentTarget.dataset.empkey;
        const toReject=this._getEmpWeekEntries(empKey).filter(e=>e.isPending);
        if (!toReject.length) return;
        this._weeklyBulkRejectIds=toReject.map(e=>e.id); this._weeklyBulkRejectEmpKey=empKey;
        this.pendingRejectTargetId='__bulk_weekly__'; this.pendingRejectIsTs=false; this.pendingRejectIsWfh=false;
        this.pendingRejectReason=''; this.showRejectModalPending=true;
    }

    /* ── Pagination state (add to your @track / state section) ── */
drillCurrentPage = 1;
drillPageSize = 10;

/* ── Computed getter: sliced records for current page ── */
get pagedDrillAttRecords() {
    return this._paginate(this.drillAttRecords);
}
get pagedDrillTsRecords() {
    return this._paginate(this.drillTsRecords);
}
get pagedDrillLeaveRecords() {
    return this._paginate(this.drillLeaveRecords);
}

/* ── Helper: slice any array to current page ── */
_paginate(arr) {
    if (!arr || !arr.length) return [];
    const start = (this.drillCurrentPage - 1) * this.drillPageSize;
    return arr.slice(start, start + this.drillPageSize);
}

/* ── Total pages for active tab ── */
get drillTotalPages() {
    const total = this.isDrillAtt ? (this.drillAttRecords || []).length
                : this.isDrillTs  ? (this.drillTsRecords  || []).length
                : (this.drillLeaveRecords || []).length;
    return Math.ceil(total / this.drillPageSize) || 1;
}

/* ── Page number buttons array ── */
get drillPageNumbers() {
    const pages = [];
    const total = this.drillTotalPages;
    const cur   = this.drillCurrentPage;
    const delta = 2;
    for (let i = 1; i <= total; i++) {
        if (i === 1 || i === total ||
            (i >= cur - delta && i <= cur + delta)) {
            pages.push({ num: i, isActive: i === cur,
                cls: 'drill-page-btn' + (i === cur ? ' drill-page-btn--active' : '') });
        } else if (pages[pages.length-1]?.num !== '...') {
            pages.push({ num: '...', isActive: false,
                cls: 'drill-page-btn', disabled: true });
        }
    }
    return pages;
}
get drillHasMultiplePages() { return this.drillTotalPages > 1; }
get drillPageStart() { return (this.drillCurrentPage - 1) * this.drillPageSize + 1; }
get drillPageEnd() {
    const total = this.isDrillAtt ? (this.drillAttRecords || []).length
                : this.isDrillTs  ? (this.drillTsRecords  || []).length
                : (this.drillLeaveRecords || []).length;
    return Math.min(this.drillCurrentPage * this.drillPageSize, total);
}
get drillTotalRecords() {
    return this.isDrillAtt ? (this.drillAttRecords || []).length
         : this.isDrillTs  ? (this.drillTsRecords  || []).length
         : (this.drillLeaveRecords || []).length;
}
get drillIsFirstPage() { return this.drillCurrentPage === 1; }
get drillIsLastPage()  { return this.drillCurrentPage >= this.drillTotalPages; }

/* ── Handlers ── */
handleDrillPageChange(event) {
    const pg = event.currentTarget.dataset.page;
    if (pg === '...') return;
    this.drillCurrentPage = Number(pg);
}
handleDrillPrev() {
    if (this.drillCurrentPage > 1) this.drillCurrentPage--;
}
handleDrillNext() {
    if (this.drillCurrentPage < this.drillTotalPages) this.drillCurrentPage++;
}
handleDrillPageSizeChange(event) {
    this.drillPageSize = Number(event.target.value);
    this.drillCurrentPage = 1;
}

/* ── Reset page when switching tabs or employees ── */
/* Add this.drillCurrentPage = 1; inside: */
/*   handleDrillTabChange()               */
/*   handleSummaryRowClick()              */

    // ═════════════════════════════════════════════════
    //  LEAVE HELPERS
    // ═════════════════════════════════════════════════
    _mapLeaveRecords(lv) {
        return lv.map(r=>{
            const status=(r.Status__c||'').toLowerCase();
            return {...r,displayFrom:this._fmtDate(r.Start_Date__c),displayTo:this._fmtDate(r.End_Date__c),displayApplied:r.Applied_Date__c?this._fmtDate(r.Applied_Date__c):'—',displayDays:r.Total_Days__c!=null?`${r.Total_Days__c}d`:'—',displayLeaveType:r.Leave_Type_Name__c||r.Leave_Type__r?.Name||'—',displayReason:r.Reason__c||'—',displayComments:r.Manager_Comments__c||'—',displayRejReason:r.Rejection_Reason__c||'—',isPending:status==='pending',isProcessing:false,isApproved:status==='approved',isRejected:status==='rejected',statusBadge:`status-badge status-${status}`,cardClass:`leave-card leave-card--${status||'pending'}`};
        });
    }

    // ═════════════════════════════════════════════════
    //  UTILITIES
    // ═════════════════════════════════════════════════
    _initials(name) { return (name||'').replace(/^(Ms\.|Mr\.|Dr\.)\s*/i,'').split(' ').slice(0,2).map(n=>n[0]||'').join('').toUpperCase(); }
    _fmtDate(d)     { if(!d) return '—'; return new Date(d).toLocaleDateString('en-IN',{day:'2-digit',month:'short',year:'numeric'}); }
    _fmtDay(d)      { if(!d) return '—'; return new Date(d).toLocaleDateString('en-IN',{weekday:'short'}); }
    _fmtTime(t)     { if(!t) return '—'; const p=String(t).split(':'); let h=parseInt(p[0]||0,10); const m=p[1]||'00'; const ap=h>=12?'PM':'AM'; h=h%12||12; return `${h}:${m} ${ap}`; }
    _fmtDateTime(dt){ if(!dt) return '—'; try { const d=new Date(dt),ist=new Date(d.getTime()+5.5*60*60*1000); let h=ist.getUTCHours(); const m=String(ist.getUTCMinutes()).padStart(2,'0'); const ap=h>=12?'PM':'AM'; h=h%12||12; return `${h}:${m} ${ap}`; } catch(e){return '—';} }
    _toast(title,msg,variant) { this.dispatchEvent(new ShowToastEvent({title,message:msg||'',variant})); }
}