import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import generateMonthlyReport from '@salesforce/apex/MonthlyAttendanceReportController.generateMonthlyReport';
import getDepartments from '@salesforce/apex/MonthlyAttendanceReportController.getDepartments';
import getManagers from '@salesforce/apex/MonthlyAttendanceReportController.getManagers';

// Title shown in the blue banner at the top of the downloaded Excel file
const EXCEL_REPORT_TITLE = 'Monthly Attendance & Leave Report';

export default class MonthlyAttendanceReport extends LightningElement {

    // Filter values
    @track selectedMonth = String(new Date().getMonth() + 1);
    @track selectedYear = String(new Date().getFullYear());
    @track selectedDepartment = '';
    @track selectedManager = '';

    // Report data
    @track reportData = null;
    @track dateHeaders = [];
    @track allEmployees = [];
    @track displayedEmployees = [];

    // Summary data
    @track totalEmployees = 0;
    @track totalWorkingDays = 0;
    @track totalHolidays = 0;
    @track totalWeekends = 0;

    // Loading states
    @track isLoading = false;
    @track isLoadingMore = false;
    @track isExporting = false;

    // Pagination
    recordsPerPage = 50;
    currentPage = 1;

    // Options for dropdowns
    @track monthOptions = [
        { label: 'January', value: '1' },
        { label: 'February', value: '2' },
        { label: 'March', value: '3' },
        { label: 'April', value: '4' },
        { label: 'May', value: '5' },
        { label: 'June', value: '6' },
        { label: 'July', value: '7' },
        { label: 'August', value: '8' },
        { label: 'September', value: '9' },
        { label: 'October', value: '10' },
        { label: 'November', value: '11' },
        { label: 'December', value: '12' }
    ];

    @track yearOptions = [];
    @track departmentOptions = [{ label: 'All Departments', value: '' }];
    @track managerOptions = [{ label: 'All Managers', value: '' }];

    // Month / year the current report was generated for (used by the Excel export)
    reportMonth = null;
    reportYear = null;
    reportDepartment = '';
    reportManager = '';

    // Computed properties
    get hasReportData() {
        return this.displayedEmployees && this.displayedEmployees.length > 0;
    }

    get hasMoreRecords() {
        return this.displayedEmployees.length < this.allEmployees.length;
    }

    // Initialize component
    connectedCallback() {
        this.initializeYearOptions();
        this.loadDepartments();
        this.loadManagers();
    }

    /**
     * Initialize year options (current year ± 5 years)
     */
    initializeYearOptions() {
        const currentYear = new Date().getFullYear();
        const years = [];

        for (let i = currentYear - 5; i <= currentYear + 5; i++) {
            years.push({ label: String(i), value: String(i) });
        }

        this.yearOptions = years;
    }

    /**
     * Load departments
     */
    loadDepartments() {
        getDepartments()
            .then(result => {
                const depts = [{ label: 'All Departments', value: '' }];
                result.forEach(dept => {
                    depts.push({ label: dept, value: dept });
                });
                this.departmentOptions = depts;
            })
            .catch(error => {
                console.error('Error loading departments:', error);
            });
    }

    /**
     * Load managers
     */
    loadManagers() {
        getManagers()
            .then(result => {
                const mgrs = [{ label: 'All Managers', value: '' }];
                result.forEach(mgr => {
                    mgrs.push({ label: mgr.Name, value: mgr.Id });
                });
                this.managerOptions = mgrs;
            })
            .catch(error => {
                console.error('Error loading managers:', error);
            });
    }

    /**
     * Handle filter changes
     */
    handleMonthChange(event) {
        this.selectedMonth = event.detail.value;
    }

    handleYearChange(event) {
        this.selectedYear = event.detail.value;
    }

    handleDepartmentChange(event) {
        this.selectedDepartment = event.detail.value;
    }

    handleManagerChange(event) {
        this.selectedManager = event.detail.value;
    }

    /**
     * Generate report
     */
    handleGenerateReport() {
        if (!this.selectedMonth || !this.selectedYear) {
            this.showToast('Error', 'Please select both month and year', 'error');
            return;
        }

        this.isLoading = true;
        this.reportData = null;
        this.allEmployees = [];
        this.displayedEmployees = [];
        this.currentPage = 1;

        // Remember the filters this report is generated with (used for the Excel title)
        const requestedMonth = this.selectedMonth;
        const requestedYear = this.selectedYear;
        const requestedDepartment = this.selectedDepartment;
        const requestedManager = this.selectedManager;

        generateMonthlyReport({
            month: parseInt(this.selectedMonth, 10),
            year: parseInt(this.selectedYear, 10),
            departmentFilter: this.selectedDepartment,
            managerFilter: this.selectedManager
        })
        .then(result => {
            if (result.success) {
                this.reportMonth = requestedMonth;
                this.reportYear = requestedYear;
                this.reportDepartment = requestedDepartment;
                this.reportManager = requestedManager;
                this.processReportData(result);
                this.showToast('Success', result.message, 'success');
            } else {
                this.showToast('Error', result.error || 'Failed to generate report', 'error');
            }
        })
        .catch(error => {
            console.error('Error generating report:', error);
            this.showToast('Error', this.getErrorMessage(error), 'error');
        })
        .finally(() => {
            this.isLoading = false;
        });
    }

    /**
     * Process report data and format for display
     * v3.3: Work mode (WFH / WFO) tag for P and P* days
     */
    processReportData(result) {
        // Store summary data
        this.totalEmployees = result.totalEmployees || 0;
        this.totalWorkingDays = result.totalWorkingDays || 0;
        this.totalHolidays = result.totalHolidays || 0;
        this.totalWeekends = result.totalWeekends || 0;

        // Process date headers
        this.dateHeaders = (result.dateHeaders || []).map(header => {
            return {
                ...header,
                headerClass: this.getHeaderClass(header)
            };
        });

        // Process employee data
        this.allEmployees = (result.employees || []).map(emp => {
            return {
                Id: emp.Id,
                employeeId: emp.employeeId || 'N/A',
                employeeName: emp.employeeName || 'N/A',
                dateOfJoining: emp.dateOfJoining || 'N/A',
                workLocationDetails: emp.workLocationDetails || 'N/A',
                managerName: emp.managerName || 'N/A',
                totalDays: emp.totalDays || 0,
                workingDays: emp.workingDays || 0,
                presentDays: emp.presentDays || 0,
                absentDays: emp.absentDays || 0,
                totalLeaves: emp.totalLeaves || 0,
                holidayCount: emp.holidayCount || 0,
                weekendCount: emp.weekendCount || 0,
                daysPayable: emp.daysPayable || 0,
                lopDays: emp.lopDays || 0,
                wfhDays: emp.wfhDays || 0,
                wfoDays: emp.wfoDays || 0,
                otherLocationDays: emp.otherLocationDays || 0,
                dailyAttendance: (emp.dailyAttendance || []).map(day => {
                    // Work mode tag is only for Present (P) and Present-but-Late (P*)
                    const isPresent = day.statusCode === 'P' || day.statusCode === 'P*';
                    const hasWorkMode = isPresent && !!day.workModeCode;

                    return {
                        ...day,
                        hasWorkMode: hasWorkMode,
                        workModeClass: hasWorkMode ? this.getWorkModeClass(day.workModeCode) : '',
                        cellClass: this.getCellClass(day),
                        statusBadgeClass: this.getStatusBadgeClass(day.statusCode)
                    };
                })
            };
        });

        // Load first page
        this.loadMoreEmployees();

        console.log('Report processed (v3.3 - Work Mode):', {
            totalEmployees: this.totalEmployees,
            dateHeaders: this.dateHeaders.length,
            allEmployees: this.allEmployees.length
        });
    }

    /**
     * Get header CSS class based on day type
     */
    getHeaderClass(header) {
        let classes = 'date-col';

        if (header.isHoliday) {
            classes += ' holiday-header';
        } else if (header.isWeekend) {
            classes += ' weekend-header';
        }

        return classes;
    }

    /**
     * Get cell CSS class based on attendance status
     */
    getCellClass(day) {
        let classes = 'attendance-cell';

        if (day.isWeekend) {
            classes += ' weekend-cell';
        } else if (day.isHoliday) {
            classes += ' holiday-cell';
        } else {
            const status = day.statusCode;
            if (status === 'P' || status === 'P*') {
                classes += ' present-cell';
            } else if (status === 'A') {
                classes += ' absent-cell';
            } else if (status && status !== 'W' && status !== 'H') {
                classes += ' leave-cell';
            }
        }

        return classes;
    }

    /**
     * Get status badge CSS class
     */
    getStatusBadgeClass(statusCode) {
        let classes = 'status-badge';

        if (!statusCode) {
            return classes;
        }

        if (statusCode === 'P') {
            classes += ' present-badge';
        } else if (statusCode === 'P*') {
            classes += ' late-badge';
        } else if (statusCode === 'A') {
            classes += ' absent-badge';
        } else if (statusCode === 'H') {
            classes += ' holiday-badge';
        } else if (statusCode === 'W') {
            classes += ' weekend-badge';
        } else if (statusCode.includes('-H')) {
            classes += ' half-badge';
        } else {
            classes += ' leave-badge';
        }

        return classes;
    }

    /**
     * Get CSS class for the work mode tag (WFH / WFO / ...)
     */
    getWorkModeClass(workModeCode) {
        let classes = 'work-mode-tag';

        switch (workModeCode) {
            case 'WFH':
                classes += ' wfh-tag';
                break;
            case 'WFO':
                classes += ' wfo-tag';
                break;
            case 'CLT':
                classes += ' clt-tag';
                break;
            case 'FLD':
                classes += ' fld-tag';
                break;
            case 'BT':
                classes += ' bt-tag';
                break;
            default:
                classes += ' oth-tag';
        }

        return classes;
    }

    /**
     * Load more employees (pagination)
     */
    loadMoreEmployees() {
        const start = (this.currentPage - 1) * this.recordsPerPage;
        const end = start + this.recordsPerPage;

        const newEmployees = this.allEmployees.slice(start, end);
        this.displayedEmployees = [...this.displayedEmployees, ...newEmployees];
        this.currentPage++;
    }

    /**
     * Handle scroll event for infinite loading
     */
    handleScroll(event) {
        const target = event.target;
        const scrollThreshold = 100;

        if (target.scrollHeight - target.scrollTop - target.clientHeight < scrollThreshold) {
            if (this.hasMoreRecords && !this.isLoadingMore) {
                this.isLoadingMore = true;

                // Simulate loading delay
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    this.loadMoreEmployees();
                    this.isLoadingMore = false;
                }, 500);
            }
        }
    }

    // ============================================================
    // EXCEL EXPORT (styled .xlsx built in the browser)
    // Blue title banner + blue headers + colour-coded status cells
    // Uses ALL generated employees (not just the 50 shown on screen)
    // ============================================================

    /**
     * Export report to Excel (.xlsx)
     */
    handleExportToExcel() {
        if (!this.allEmployees || this.allEmployees.length === 0) {
            this.showToast('Warning', 'No report data to export. Generate the report first.', 'warning');
            return;
        }

        this.isExporting = true;

        try {
            const zipBytes = this.generateReportXLSX();
            this.downloadXlsx(zipBytes, this.buildExcelFileName());
            this.showToast('Success', 'Excel file (.xlsx) exported successfully', 'success');
        } catch (error) {
            console.error('Error exporting to Excel:', error);
            this.showToast('Error', 'Failed to export: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isExporting = false;
        }
    }

    /**
     * Download the xlsx bytes as a file
     */
    downloadXlsx(zipBytes, fileName) {
        let blob;
        let url;
        try {
            blob = new Blob([zipBytes], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
            url = URL.createObjectURL(blob);
        } catch (e1) {
            // LWS restricts certain MIME types. text/plain is whitelisted for downloads
            blob = new Blob([zipBytes], { type: 'text/plain' });
            url = URL.createObjectURL(blob);
        }

        const link = document.createElement('a');
        link.href = url;
        link.download = fileName;
        link.style.display = 'none';

        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);

        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            URL.revokeObjectURL(url);
        }, 1000);
    }

    /**
     * File name e.g. Attendance_Report_October_2026_20261014_181200.xlsx
     */
    buildExcelFileName() {
        return `Attendance_Report_${this.getReportMonthName()}_${this.reportYear || this.selectedYear}_${this.getCurrentDateTimeString()}.xlsx`;
    }

    getReportMonthName() {
        const monthValue = this.reportMonth || this.selectedMonth;
        const match = this.monthOptions.find(m => m.value === String(monthValue));
        return match ? match.label : 'Report';
    }

    /**
     * Build the info line under the blue title
     */
    buildExcelInfoLine() {
        const parts = [];
        parts.push(`Period: ${this.getReportMonthName()} ${this.reportYear || this.selectedYear}`);

        if (this.reportDepartment) {
            parts.push(`Department: ${this.reportDepartment}`);
        }
        if (this.reportManager) {
            const mgr = this.managerOptions.find(m => m.value === this.reportManager);
            if (mgr) {
                parts.push(`Manager: ${mgr.label}`);
            }
        }

        parts.push(`Employees: ${this.allEmployees.length}`);
        parts.push(`Working Days: ${this.totalWorkingDays}`);
        parts.push(`Holidays: ${this.totalHolidays}`);
        parts.push(`Weekends: ${this.totalWeekends}`);
        parts.push(`Generated: ${this.getReadableNow()}`);

        return parts.join('   |   ');
    }

    /**
     * Map a day status code to an Excel cell style index
     */
    getExcelStatusStyle(statusCode) {
        if (!statusCode) {
            return 4;
        }
        if (statusCode === 'P') {
            return 5;  // Present - green
        }
        if (statusCode === 'P*') {
            return 6;  // Late - amber
        }
        if (statusCode === 'A') {
            return 7;  // Absent - red
        }
        if (statusCode === 'H') {
            return 8;  // Holiday - purple
        }
        if (statusCode === 'W') {
            return 9;  // Weekend - gray
        }
        if (statusCode === 'LOP' || statusCode === 'LWP') {
            return 7;  // Loss of pay - red
        }
        if (statusCode.includes('-H')) {
            return 6;  // Half-day leave - amber
        }
        return 10;     // Other leave (CL, SL, ML, PL...) - blue
    }

    /**
     * Generates a genuine .xlsx file from the generated report data
     * Layout:
     *   Row 1 -> Blue title banner (merged)
     *   Row 2 -> Light-blue info line (merged)
     *   Row 3 -> Blue column headers (weekend = gray, holiday = purple)
     *   Row 4+ -> One row per employee
     */
    generateReportXLSX() {
        const employees = this.allEmployees;
        const dateHeaders = this.dateHeaders;
        const dayCount = dateHeaders.length;

        const fixedHeaders = ['Emp ID', 'Employee Name', 'DOJ', 'Work Location', 'Reporting Manager'];
        const summaryHeaders = [
            'Total Days', 'Working Days', 'Present', 'WFH Days', 'WFO Days',
            'Absent', 'Leaves', 'Holidays', 'Days Payable', 'LOP Days'
        ];

        const fixedCount = fixedHeaders.length;
        const colCount = fixedCount + dayCount + summaryHeaders.length;
        const lastColLetter = this.getColumnLetter(colCount);

        const TITLE_ROWS = 2;
        const HEADER_ROW_NUM = TITLE_ROWS + 1; // 3

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
    <sheet name="Attendance Report" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>`;

        // cellXfs style index map:
        //  0 text left      | 1 header blue     | 2 title banner  | 3 info line
        //  4 centered       | 5 present green   | 6 late/half amber | 7 absent red
        //  8 holiday purple | 9 weekend gray    | 10 leave blue
        //  11 header weekend | 12 header holiday | 13 summary number | 14 days payable teal
        const styles = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="12">
    <font><sz val="10"/><name val="Calibri"/><color rgb="FF181818"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font>
    <font><b/><sz val="16"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF014486"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF2E844A"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFB86700"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFEA001E"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF7F27CB"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF706E6B"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF0176D3"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF00796B"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF181818"/></font>
  </fonts>
  <fills count="13">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF0070D2"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F5E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F4F9"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF4E5"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFDE8E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F3F3"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3E8FD"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF757575"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF7B1FA2"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE0F2F1"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF8F9FA"/></patternFill></fill>
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
  <cellXfs count="15">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="left" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1">
      <alignment horizontal="left" vertical="center" indent="1"/>
    </xf>
    <xf numFmtId="0" fontId="3" fillId="4" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1">
      <alignment horizontal="left" vertical="center" indent="1"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="4" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="5" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="6" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="7" fillId="8" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="8" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="9" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="1" fillId="9" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="1" fillId="10" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="11" fillId="12" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="10" fillId="11" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
  </cellXfs>
</styleSheet>`;

        // ---------- Row 1: blue title banner ----------
        let sheetDataXml = '';
        sheetDataXml += '<row r="1" ht="34" customHeight="1">';
        sheetDataXml += `<c r="A1" t="inlineStr" s="2"><is><t>${this.escapeXml(EXCEL_REPORT_TITLE)}</t></is></c>`;
        for (let c = 2; c <= colCount; c++) {
            sheetDataXml += `<c r="${this.getColumnLetter(c)}1" s="2"/>`;
        }
        sheetDataXml += '</row>';

        // ---------- Row 2: info line ----------
        sheetDataXml += '<row r="2" ht="22" customHeight="1">';
        sheetDataXml += `<c r="A2" t="inlineStr" s="3"><is><t>${this.escapeXml(this.buildExcelInfoLine())}</t></is></c>`;
        for (let c = 2; c <= colCount; c++) {
            sheetDataXml += `<c r="${this.getColumnLetter(c)}2" s="3"/>`;
        }
        sheetDataXml += '</row>';

        // ---------- Row 3: column headers ----------
        sheetDataXml += `<row r="${HEADER_ROW_NUM}" ht="36" customHeight="1">`;
        let colIdx = 1;

        fixedHeaders.forEach(text => {
            sheetDataXml += `<c r="${this.getColumnLetter(colIdx)}${HEADER_ROW_NUM}" t="inlineStr" s="1"><is><t>${this.escapeXml(text)}</t></is></c>`;
            colIdx++;
        });

        dateHeaders.forEach(h => {
            let headerStyle = 1;
            if (h.isHoliday) {
                headerStyle = 12;
            } else if (h.isWeekend) {
                headerStyle = 11;
            }
            const text = `${String(h.day || '').toUpperCase()}\n${h.number}`;
            sheetDataXml += `<c r="${this.getColumnLetter(colIdx)}${HEADER_ROW_NUM}" t="inlineStr" s="${headerStyle}"><is><t xml:space="preserve">${this.escapeXml(text)}</t></is></c>`;
            colIdx++;
        });

        summaryHeaders.forEach(text => {
            sheetDataXml += `<c r="${this.getColumnLetter(colIdx)}${HEADER_ROW_NUM}" t="inlineStr" s="1"><is><t>${this.escapeXml(text)}</t></is></c>`;
            colIdx++;
        });
        sheetDataXml += '</row>';

        // ---------- Row 4+: employees ----------
        employees.forEach((emp, index) => {
            const rowNum = HEADER_ROW_NUM + 1 + index;
            let c = 1;
            sheetDataXml += `<row r="${rowNum}" ht="22" customHeight="1">`;

            // Fixed columns
            const fixedValues = [
                emp.employeeId,
                emp.employeeName,
                emp.dateOfJoining,
                emp.workLocationDetails,
                emp.managerName
            ];
            fixedValues.forEach((val, i) => {
                const style = (i === 0 || i === 2) ? 4 : 0;
                sheetDataXml += `<c r="${this.getColumnLetter(c)}${rowNum}" t="inlineStr" s="${style}"><is><t>${this.escapeXml(val)}</t></is></c>`;
                c++;
            });

            // Daily status columns - P / P* include the work mode, e.g. "P (WFH)"
            (emp.dailyAttendance || []).forEach(day => {
                let text = day.statusCode || '';
                if ((text === 'P' || text === 'P*') && day.workModeCode) {
                    text += ` (${day.workModeCode})`;
                }
                const style = this.getExcelStatusStyle(day.statusCode);
                sheetDataXml += `<c r="${this.getColumnLetter(c)}${rowNum}" t="inlineStr" s="${style}"><is><t>${this.escapeXml(text)}</t></is></c>`;
                c++;
            });

            // Summary columns (numeric)
            const summaryValues = [
                { v: emp.totalDays, s: 13 },
                { v: emp.workingDays, s: 13 },
                { v: emp.presentDays, s: 5 },
                { v: emp.wfhDays, s: 10 },
                { v: emp.wfoDays, s: 6 },
                { v: emp.absentDays, s: 7 },
                { v: emp.totalLeaves, s: 10 },
                { v: emp.holidayCount, s: 8 },
                { v: emp.daysPayable, s: 14 },
                { v: emp.lopDays, s: 13 }
            ];
            summaryValues.forEach(item => {
                sheetDataXml += `<c r="${this.getColumnLetter(c)}${rowNum}" s="${item.s}"><v>${Number(item.v) || 0}</v></c>`;
                c++;
            });

            sheetDataXml += '</row>';
        });

        // ---------- Column widths ----------
        let colsXml = '<cols>';
        colsXml += '<col min="1" max="1" width="14" customWidth="1"/>';
        colsXml += '<col min="2" max="2" width="26" customWidth="1"/>';
        colsXml += '<col min="3" max="3" width="13" customWidth="1"/>';
        colsXml += '<col min="4" max="4" width="30" customWidth="1"/>';
        colsXml += '<col min="5" max="5" width="20" customWidth="1"/>';
        colsXml += `<col min="${fixedCount + 1}" max="${fixedCount + dayCount}" width="9.5" customWidth="1"/>`;
        colsXml += `<col min="${fixedCount + dayCount + 1}" max="${colCount}" width="12" customWidth="1"/>`;
        colsXml += '</cols>';

        // Freeze only the top rows (title, info line, header row).
        // No column freeze, so no vertical divider line cuts through the title banner.
        const sheet1 = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetViews>
    <sheetView tabSelected="1" workbookViewId="0">
      <pane ySplit="${HEADER_ROW_NUM}" topLeftCell="A${HEADER_ROW_NUM + 1}" activePane="bottomLeft" state="frozen"/>
    </sheetView>
  </sheetViews>
  ${colsXml}
  <sheetData>
    ${sheetDataXml}
  </sheetData>
  <mergeCells count="2">
    <mergeCell ref="A1:${lastColLetter}1"/>
    <mergeCell ref="A2:${lastColLetter}2"/>
  </mergeCells>
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

    /**
     * Escape XML special characters
     */
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

    /**
     * Get Excel column letter (1 -> A, 27 -> AA, etc.)
     */
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

    /**
     * Creates an uncompressed (store method) ZIP archive
     */
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

        // Local File Headers + Data
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

        // Central Directory
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

        // End of Central Directory
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

    /**
     * Fast CRC32 calculation
     */
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

    // ============================================================
    // UTILITIES
    // ============================================================

    /**
     * Readable current date/time, e.g. 14-Oct-2026 18:12
     */
    getReadableNow() {
        const now = new Date();
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const day = String(now.getDate()).padStart(2, '0');
        const hours = String(now.getHours()).padStart(2, '0');
        const minutes = String(now.getMinutes()).padStart(2, '0');
        return `${day}-${months[now.getMonth()]}-${now.getFullYear()} ${hours}:${minutes}`;
    }

    /**
     * Current date time string for file names
     */
    getCurrentDateTimeString() {
        const now = new Date();
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        const day = String(now.getDate()).padStart(2, '0');
        const hours = String(now.getHours()).padStart(2, '0');
        const minutes = String(now.getMinutes()).padStart(2, '0');
        const seconds = String(now.getSeconds()).padStart(2, '0');
        return `${year}${month}${day}_${hours}${minutes}${seconds}`;
    }

    /**
     * Show toast notification
     */
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }

    /**
     * Get error message from error object
     */
    getErrorMessage(error) {
        if (error.body) {
            if (error.body.message) {
                return error.body.message;
            } else if (error.body.pageErrors && error.body.pageErrors.length > 0) {
                return error.body.pageErrors[0].message;
            }
        } else if (error.message) {
            return error.message;
        }
        return 'An unknown error occurred';
    }
}